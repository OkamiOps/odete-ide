import Foundation
import OdeteI18n

/// A resolução: do package.json (e do lock, quando há) à árvore de `node_modules`.
extension Installer {
    struct Node { var name: String; var entry: Lockfile.Entry; var parentKey: String }

    struct Want { var name: String; var range: String; var from: String; var dev: Bool; var optional: Bool }

    /// O que a resolução guarda de um packument depois de escolher uma versão dele.
    ///
    /// Packument é pesado: o do `next` traz milhares de versões, cada uma com as próprias
    /// dependências. De tudo isso a árvore usa uma ou duas. Guardar só a lista de versões
    /// (para escolher de novo se outra faixa pedir o mesmo pacote) e os dados das
    /// escolhidas faz a memória da resolução acompanhar o tamanho da árvore, não o do
    /// histórico de cada pacote. Se outra faixa cair numa versão que ninguém escolheu
    /// ainda, o packument é buscado de novo — conflito de versão é raro.
    struct PackumentGuardado {
        var distTags: [String: String]
        var versoes: [Version]
        var escolhidas: [Version: PackumentVersion]
    }

    /// Se um pacote de plataforma entra, fica só no lock ou fica de fora.
    enum Plataforma: Equatable {
        case serve
        /// Opcional com `os`/`cpu`: binário nativo de alguma plataforma (o esbuild, o
        /// rollup, o swc do next, o lightningcss e o sharp publicam um por sistema). Nenhum
        /// roda no iPad — nem o de darwin/arm64, que é do macOS —, e cada um tem de dezenas
        /// de megas. Fica no lock, como o npm faz, para o próximo install nem perguntar ao
        /// registro, e não é baixado. O que a Odete troca por dentro (esbuild, rollup) não
        /// dependia deles.
        case soNoLock
        /// Dependência obrigatória de outro sistema: fica de fora, como sempre ficou.
        case deOutroSistema
    }

    static func plataforma(opcional: Bool, os: [String], cpu: [String]) -> Plataforma {
        if opcional, !os.isEmpty || !cpu.isEmpty {
            return .soNoLock
        }
        if !os.isEmpty, !os.contains("darwin"), !os.contains("!win32"), !os.contains("any") {
            return .deOutroSistema
        }
        if !cpu.isEmpty, !cpu.contains("arm64") {
            return .deOutroSistema
        }
        return .serve
    }

    /// Nomes que denunciam binário nativo mesmo sem script de instalação.
    static func pareceBinarioNativo(_ nome: String) -> Bool {
        nome.hasSuffix("-darwin-arm64") || nome.hasSuffix("-darwin-64") || nome.contains("/darwin-")
            || nome.hasPrefix("@esbuild/") || nome.hasPrefix("@swc/core-") || nome.hasPrefix("@rollup/rollup-")
            || nome.hasPrefix("@next/swc-")
    }

    /// A faixa efetiva do pedido, ou `nil` para o que o npm daqui não resolve
    /// (`file:`, git, URL, workspaces).
    static func faixa(_ w: Want) -> String? {
        if w.range.hasPrefix("file:") || w.range.hasPrefix("git") || w.range.hasPrefix("http") || w.range
            .hasPrefix("link:") || w.range.hasPrefix("workspace:")
        {
            return nil
        }
        if w.range.hasPrefix("npm:") {
            return String(w.range.split(separator: "@").last ?? "latest")
        }
        return w.range
    }

    /// A entrada do lock que atende o pedido, se houver.
    ///
    /// `confiavel` é falso num caso só: pedido opcional atendido por uma entrada que um
    /// lock antigo da Odete marcou como nativa sem dizer se era opcional nem de que
    /// plataforma. É o binário de plataforma que a versão anterior baixava; vale
    /// perguntar ao registro para saber, e se o registro não responder, fica o que o lock
    /// dizia.
    static func doLock(
        _ w: Want,
        faixa: String,
        lock: Lockfile?,
        pinned: [String: String]
    ) -> (entry: Lockfile.Entry, confiavel: Bool)? {
        guard pinned[w.name] == nil, let lock, let (_, le) = lock.resolve(w.name, from: w.from),
              let lv = Version(le.version), SemverRange(faixa).isAny || SemverRange(faixa).satisfies(lv)
        else { return nil }
        return (le, !(w.optional && !le.optional && le.native))
    }

    func resolve(
        pkg: PackageJSON,
        lock: Lockfile?,
        pinned: [String: String],
        jaBuscados: [String: Packument] = [:],
        report: inout Report
    ) async throws -> [String: Node] {
        var tree: [String: Node] = [:]
        var guardados: [String: PackumentGuardado] = [:]
        let busca = BuscaDePackuments(registry: registry, simultaneas: buscasSimultaneas)
        defer { busca.cancelarTudo() }
        for (nome, p) in jaBuscados {
            busca.semear(nome, p)
        }
        var queue: [Want] = []
        // ordem determinística: mesmo package.json → mesmo lock
        for (n, r) in pkg.dependencies.sorted(by: { $0.key < $1.key }) {
            queue.append(Want(name: n, range: pinned[n] ?? r, from: "", dev: false, optional: false))
        }
        for (n, r) in pkg.devDependencies.sorted(by: { $0.key < $1.key }) {
            queue.append(Want(name: n, range: pinned[n] ?? r, from: "", dev: true, optional: false))
        }
        // A fila é percorrida em ordem — é isso que faz o lock sair igual toda vez —, mas
        // os packuments que ela vai precisar são pedidos antes, alguns de cada vez. A
        // decisão continua sequencial; só a espera pela rede é que se sobrepõe.
        var olhado = 0
        var pediram = Set<Int>()
        var pedidosPorNome: [String: Int] = [:]
        var i = 0
        while i < queue.count {
            olhado = max(olhado, i)
            while olhado < queue.count, busca.pendentes < Self.janelaDeBusca {
                let w = queue[olhado]
                if guardados[w.name] == nil, let f = Self.faixa(w),
                   Self.doLock(w, faixa: f, lock: lock, pinned: pinned)?.confiavel != true
                {
                    pediram.insert(olhado)
                    pedidosPorNome[w.name, default: 0] += 1
                    busca.pedir(w.name)
                }
                olhado += 1
            }
            let indice = i
            let w = queue[i]; i += 1
            // Pedido antecipado que ninguém mais vai usar (o pacote já estava na árvore,
            // veio do lock) é cancelado, senão ocupa a janela à toa.
            defer {
                if pediram.contains(indice) {
                    pedidosPorNome[w.name, default: 1] -= 1
                    if pedidosPorNome[w.name] == 0 {
                        busca.descartar(w.name)
                    }
                }
            }
            guard let range = Self.faixa(w) else {
                report.skipped.append("\(w.name)@\(w.range)"); continue
            }
            // já satisfeito em algum nível acima?
            if let (_, existing) = find(w.name, from: w.from, in: tree), let ev = Version(existing.entry.version),
               SemverRange(range).satisfies(ev) || SemverRange(range).isAny || pinned[w.name] == existing.entry
               .version
            {
                continue
            }
            var chosen: Lockfile.Entry?
            let lockado = Self.doLock(w, faixa: range, lock: lock, pinned: pinned)
            if let lockado, lockado.confiavel {
                chosen = lockado.entry
            } else {
                let pv: PackumentVersion?
                do {
                    pv = try await versao(w.name, pinned[w.name] ?? range, &guardados, busca)
                } catch {
                    if let lockado {
                        chosen = lockado.entry
                    } else if w.optional {
                        report.skipped.append(w.name); continue
                    } else {
                        report.failed[w.name] = error.localizedDescription; continue
                    }
                    pv = nil
                }
                if let pv {
                    let native = pv.hasInstallScript || Self.pareceBinarioNativo(w.name)
                    chosen = Lockfile.Entry(
                        version: pv.version.description,
                        resolved: pv.tarball,
                        integrity: pv.integrity,
                        dependencies: pv.dependencies,
                        optionalDependencies: pv.optionalDependencies,
                        bin: pv.bin,
                        dev: w.dev,
                        native: native,
                        os: pv.os,
                        cpu: pv.cpu
                    )
                } else if chosen == nil {
                    if let lockado {
                        chosen = lockado.entry
                    } else if w.optional {
                        report.skipped.append(w.name); continue
                    } else {
                        report.failed[w.name] = NpmError.noVersion(w.name, range).localizedDescription; continue
                    }
                }
            }
            guard var c = chosen else { continue }
            c.dev = w.dev
            c.optional = w.optional
            let lugar = Self.plataforma(opcional: w.optional, os: c.os, cpu: c.cpu)
            if lugar == .deOutroSistema || lugar == .soNoLock {
                report.plataforma.append(tr(
                    "%1$@ (só %2$@)",
                    "\(w.name)",
                    "\((c.os + c.cpu).joined(separator: ","))"
                ))
            }
            if lugar == .deOutroSistema {
                continue
            }
            if lugar == .soNoLock {
                c.native = false
            }
            // onde colocar: topo se livre, senão aninhado sob quem pediu
            var key = "node_modules/\(w.name)"
            if let top = tree[key],
               top.entry.version != c.version
            {
                key = w.from.isEmpty ? key : "\(w.from)/node_modules/\(w.name)"
            }
            if let existing = tree[key], existing.entry.version == c.version {
                continue
            }
            tree[key] = Node(name: w.name, entry: c, parentKey: w.from)
            // Binário de plataforma não é instalado; o que ele puxaria também não.
            guard lugar == .serve else { continue }
            if c.native {
                report.anotarNativo(w.name, c.version)
            }
            for (dn, dr) in c.dependencies.sorted(by: { $0.key < $1.key }) {
                queue.append(Want(name: dn, range: dr, from: key, dev: w.dev, optional: false))
            }
            for (dn, dr) in c.optionalDependencies.sorted(by: { $0.key < $1.key }) {
                queue.append(Want(name: dn, range: dr, from: key, dev: w.dev, optional: true))
            }
        }
        return tree
    }

    /// Quantos packuments podem estar pedidos antes da hora — no ar ou já chegados e
    /// ainda não usados. É o teto de packuments inteiros na memória durante a resolução.
    static let janelaDeBusca = 16

    /// A versão que a faixa pede, com os dados dela; `nil` se nenhuma serve.
    func versao(
        _ nome: String,
        _ faixa: String,
        _ guardados: inout [String: PackumentGuardado],
        _ busca: BuscaDePackuments
    ) async throws -> PackumentVersion? {
        if var g = guardados[nome] {
            guard let v = Packument.escolher(faixa, distTags: g.distTags, versoes: g.versoes) else { return nil }
            if let pv = g.escolhidas[v] {
                return pv
            }
            let p = try await busca.tomar(nome)
            guard let pv = p.versions[v] else { return nil }
            g.escolhidas[v] = pv
            guardados[nome] = g
            return pv
        }
        let p = try await busca.tomar(nome)
        let pv = p.pick(faixa)
        guardados[nome] = PackumentGuardado(
            distTags: p.distTags,
            versoes: Array(p.versions.keys),
            escolhidas: pv.map { [$0.version: $0] } ?? [:]
        )
        return pv
    }

    func find(_ name: String, from: String, in tree: [String: Node]) -> (String, Node)? {
        var base = from
        while true {
            let key = base.isEmpty ? "node_modules/\(name)" : "\(base)/node_modules/\(name)"
            if let n = tree[key] {
                return (key, n)
            }
            if base.isEmpty {
                return nil
            }
            guard let r = base.range(of: "/node_modules/", options: .backwards) else { base = ""; continue }
            base = String(base[..<r.lowerBound])
        }
    }
}

/// Packuments pedidos antes da hora, com limite de quantos ficam no ar ao mesmo tempo.
///
/// Antes a resolução pedia um, esperava, pedia o próximo: numa árvore de trezentos
/// pacotes, trezentas idas e voltas ao registro em fila. Aqui a fila de pedidos anda na
/// frente, e quem resolve só espera o que ainda não chegou.
///
/// Vive dentro de uma resolução só, sem sair da tarefa dela.
final class BuscaDePackuments {
    private var tarefas: [String: Task<Packument, Error>] = [:]
    private let registry: any RegistryClient
    private let vagas: Vagas

    init(registry: any RegistryClient, simultaneas: Int) {
        self.registry = registry
        vagas = Vagas(simultaneas)
    }

    /// Pedidos ainda não entregues, no ar ou já chegados.
    var pendentes: Int {
        tarefas.count
    }

    func pedir(_ nome: String) {
        guard tarefas[nome] == nil else { return }
        let registry = registry
        let vagas = vagas
        tarefas[nome] = Task {
            await vagas.esperar()
            do {
                try Task.checkCancellation()
                let p = try await registry.packument(nome)
                await vagas.liberar()
                return p
            } catch {
                await vagas.liberar()
                throw error
            }
        }
    }

    /// Já buscado por outro caminho (o `npm install x` busca antes de resolver).
    func semear(_ nome: String, _ p: Packument) {
        tarefas[nome] = Task { p }
    }

    /// Entrega o packument e esquece dele. Sem pedido feito, pede agora.
    func tomar(_ nome: String) async throws -> Packument {
        pedir(nome)
        guard let t = tarefas.removeValue(forKey: nome) else { throw CancellationError() }
        return try await t.value
    }

    func descartar(_ nome: String) {
        tarefas.removeValue(forKey: nome)?.cancel()
    }

    func cancelarTudo() {
        for t in tarefas.values {
            t.cancel()
        }
        tarefas.removeAll()
    }
}

/// Semáforo para `async`: no máximo `n` dentro ao mesmo tempo, os outros esperam em fila.
actor Vagas {
    private var livres: Int
    private var esperando: [CheckedContinuation<Void, Never>] = []

    init(_ n: Int) {
        livres = n
    }

    func esperar() async {
        if livres > 0 {
            livres -= 1
            return
        }
        await withCheckedContinuation { esperando.append($0) }
    }

    func liberar() {
        if esperando.isEmpty {
            livres += 1
        } else {
            esperando.removeFirst().resume()
        }
    }
}
