import CryptoKit
import Foundation
import OdeteI18n

/// A resolução: do package.json (e do lock, quando há) à árvore de `node_modules`.
extension Installer {
    struct Node {
        var name: String
        var entry: Lockfile.Entry
        var parentKey: String
        /// Só alcançado através de um binário de plataforma: fica no lock, não no disco.
        var soNoLock = false
        /// Veio do registro nesta resolução (não do lock): os campos que o npm grava e o
        /// packument abreviado não traz (`license`, `libc`) ainda faltam.
        var novo = false
    }

    struct Want {
        /// O nome da pasta em `node_modules` (num alias, o alias).
        var name: String
        /// O que foi pedido, como está no package.json de quem pediu.
        var range: String
        /// Chave de quem pediu (`""` é o projeto, `packages/web` é um workspace).
        var from: String
        var dev: Bool
        var optional: Bool
        /// Pedido como `peerDependencies`: fica ao lado de quem pediu, não dentro dele.
        var peer = false
        /// Quem pediu, para as mensagens.
        var quem = ""
        /// As regras de `overrides` que valem neste ramo, da mais externa à mais interna.
        var regras: [Sobrescrita] = []
    }

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
        var depreciadas: Set<Version> = []
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

    /// Dependências que só existem para carregar ou compilar um addon nativo (`.node`).
    /// Quem depende delas tem código nativo; quem só tem `postinstall` (o `core-js`, que
    /// imprime um recado) não.
    static let carregadoresNativos: Set<String> = [
        "bindings", "node-gyp-build", "node-gyp", "prebuild-install", "node-pre-gyp", "@mapbox/node-pre-gyp",
        "nan", "node-addon-api", "cmake-js",
    ]

    static func dependeDeNativo(_ deps: [String: String]) -> Bool {
        deps.keys.contains { carregadoresNativos.contains($0) }
    }

    func resolve(
        pkg: PackageJSON,
        lock: Lockfile?,
        pinned: [String: String],
        jaBuscados: [String: Packument] = [:],
        report: inout Report
    ) async throws -> [String: Node] {
        let r = Resolvedor(installer: self, pkg: pkg, lock: lock, pinned: pinned, report: report)
        defer { r.busca.cancelarTudo() }
        for (nome, p) in jaBuscados {
            r.busca.semear(nome, p)
        }
        try await r.rodar()
        report = r.report
        return r.tree
    }

    /// Quantos packuments podem estar pedidos antes da hora — no ar ou já chegados e
    /// ainda não usados. É o teto de packuments inteiros na memória durante a resolução.
    static let janelaDeBusca = 16

    func find(_ name: String, from: String, in tree: [String: Node]) -> (String, Node)? {
        Resolvedor.achar(name, from: from, in: tree)
    }
}

/// O estado de uma resolução. Vive dentro de uma chamada de `resolve`.
final class Resolvedor {
    typealias Node = Installer.Node
    typealias Want = Installer.Want

    let installer: Installer
    let pkg: PackageJSON
    let lock: Lockfile?
    let pinned: [String: String]
    var report: Installer.Report
    var tree: [String: Node] = [:]
    var guardados: [String: Installer.PackumentGuardado] = [:]
    let busca: BuscaDePackuments
    /// Nós colocados e ainda não processados, na ordem do npm: os mais rasos primeiro
    /// (`node_modules/x` antes de `node_modules/x/node_modules/y`) e, na mesma
    /// profundidade, pelo caminho. É uma fila de prioridade, não de chegada: um pacote
    /// recém-colocado em `node_modules/@babel/core` passa na frente de um
    /// `node_modules/next` que já esperava — e quem é processado primeiro fica com o lugar
    /// no topo. Com a fila por chegada, o `semver` do topo era o 7 de um pacote qualquer, e
    /// o npm põe lá o 6 do `@babel/core`.
    var pendentes: [String] = []
    /// As arestas de cada nó pendente (dependências, opcionais e peers), já em ordem de nome.
    var arestas: [String: [Aresta]] = [:]
    /// Nós só alcançados passando por um binário de plataforma: ficam no lock, como no
    /// npm, e não são baixados.
    var soNoLock: Set<String> = []
    /// Quem depende de cada nome (chaves de nós; `""` é o projeto). É o que diz se pôr um
    /// pacote num nível mais alto esconderia de alguém a versão que ele já usa.
    var dependentes: [String: Set<String>] = [:]
    /// Workspaces por nome: a pasta (relativa ao projeto) e o package.json dela.
    var workspaces: [String: (pasta: String, pkg: PackageJSON)] = [:]
    let regrasDaRaiz: Sobrescrita

    /// Um pedido ainda por processar, com o nome que valeria buscar antes da hora.
    struct Aresta {
        var want: Want
        /// Packument que a busca antecipada pode pedir (`nil`: não é do registro, ou o lock
        /// já responde).
        var antecipar: String?
        var pedido = false
    }

    init(installer: Installer, pkg: PackageJSON, lock: Lockfile?, pinned: [String: String], report: Installer.Report) {
        self.installer = installer
        self.pkg = pkg
        self.lock = lock
        self.pinned = pinned
        self.report = report
        busca = BuscaDePackuments(registry: installer.registry, simultaneas: installer.buscasSimultaneas)
        regrasDaRaiz = Sobrescrita.raiz(pkg)
    }

    // MARK: - Laço

    func rodar() async throws {
        let raizes: [(String, String, Bool, Bool, Bool)] = // nome, faixa, dev, opcional, peer
            pkg.dependencies.map { ($0.key, $0.value, false, false, false) }
            + pkg.optionalDependencies.map { ($0.key, $0.value, false, true, false) }
            + pkg.devDependencies.map { ($0.key, $0.value, true, false, false) }
            + pkg.peerDependencies.filter { !pkg.peersOpcionais.contains($0.key) }
            .map { ($0.key, $0.value, false, false, true) }
        var vistos = Set<String>()
        var daRaiz: [Want] = []
        // Precedência do npm quando o nome se repete: dependencies, optional, dev, peer.
        for (n, r, dev, opcional, peer) in raizes where !vistos.contains(n) {
            vistos.insert(n)
            daRaiz.append(Want(
                name: n, range: pinned[n] ?? r, from: "", dev: dev, optional: opcional, peer: peer,
                quem: pkg.name, regras: [regrasDaRaiz]
            ))
            dependentes[n, default: []].insert("")
        }
        daRaiz += try carregarWorkspaces()
        // Todas juntas, pelo nome, como o npm: separar `dependencies` de `devDependencies`
        // mudava quem chegava primeiro ao topo.
        empurrar("", daRaiz)
        var precisam: [String: Int] = [:]
        while !pendentes.isEmpty {
            let key = pendentes.removeFirst()
            var i = 0
            while i < (arestas[key]?.count ?? 0) {
                // Os packuments que a fila vai precisar são pedidos antes, alguns de cada
                // vez. A decisão continua sequencial — é isso que faz o lock sair igual
                // toda vez —; só a espera pela rede é que se sobrepõe.
                antecipar(key, desde: i, &precisam)
                let a = arestas[key]![i]
                i += 1
                await processar(a.want)
                // Pedido antecipado que ninguém mais vai usar (o pacote já estava na árvore,
                // veio do lock) é cancelado, senão ocupa a janela à toa.
                if a.pedido, let real = a.antecipar {
                    precisam[real, default: 1] -= 1
                    if precisam[real] == 0 {
                        busca.descartar(real)
                    }
                }
            }
            arestas[key] = nil
        }
        calcularMarcas()
        for (_, n) in tree where !n.entry.link && n.entry.native && !Self.ficaDeFora(n) {
            report.anotarNativo(n.name, n.entry.version)
        }
    }

    /// Nó que fica só no lock: binário de plataforma, ou alcançado só através de um.
    static func ficaDeFora(_ n: Node) -> Bool {
        n.entry.soDePlataforma || n.soNoLock
    }

    static func profundidade(_ key: String) -> Int {
        key.isEmpty ? 0 : max(1, Installer.nivel(key))
    }

    static func antes(_ a: String, _ b: String) -> Bool {
        let pa = profundidade(a), pb = profundidade(b)
        return pa != pb ? pa < pb : JSONOrdenado.menorComoONpm(a, b)
    }

    /// Põe o nó na fila de prioridade, com as arestas dele em ordem de nome.
    func empurrar(_ key: String, _ wants: [Want]) {
        let ordenadas = wants.sorted { JSONOrdenado.menorComoONpm($0.name, $1.name) }
        arestas[key] = ordenadas.map { w in
            var real: String?
            if case let .registro(r, faixa) = pedido(w), doLock(w, real: r, faixa: faixa)?.confiavel != true {
                real = r
            }
            return Aresta(want: w, antecipar: real)
        }
        let i = pendentes.firstIndex { Self.antes(key, $0) } ?? pendentes.endIndex
        pendentes.insert(key, at: i)
    }

    /// Pede antes da hora os packuments das próximas arestas: as que faltam do nó atual e
    /// as dos nós pendentes, na ordem em que vão ser processadas. Olha no máximo
    /// `olharAte` arestas à frente — numa árvore toda no lock, nada é pedido e não vale
    /// percorrer a fila inteira a cada passo.
    func antecipar(_ atual: String, desde inicio: Int, _ precisam: inout [String: Int]) {
        let olharAte = 256
        var olhadas = 0
        func olhar(_ key: String, _ de: Int) -> Bool {
            guard var lista = arestas[key] else { return true }
            var mudou = false
            defer {
                if mudou {
                    arestas[key] = lista
                }
            }
            for j in de ..< lista.count {
                guard busca.pendentes < Installer.janelaDeBusca, olhadas < olharAte else { return false }
                olhadas += 1
                guard !lista[j].pedido, let real = lista[j].antecipar, guardados[real] == nil else { continue }
                lista[j].pedido = true
                mudou = true
                precisam[real, default: 0] += 1
                busca.pedir(real)
            }
            return true
        }
        guard olhar(atual, inicio) else { return }
        for key in pendentes {
            guard olhar(key, 0) else { return }
        }
    }

    /// O pedido efetivo: o que o `npm install x@v` fixou, a regra de `overrides` que
    /// valer, ou o que está no package.json.
    func pedido(_ w: Want) -> Pedido {
        var spec = w.range
        if w.from.isEmpty, let p = pinned[w.name] {
            spec = p
        } else if let regra = regraQueVale(w) {
            spec = regra
        }
        let p = Pedido.de(spec)
        if case let .registro(nome, faixa) = p, nome.isEmpty {
            return .registro(nome: w.name, faixa: faixa)
        }
        return p
    }

    func regraQueVale(_ w: Want) -> String? {
        let faixaOriginal = Pedido.de(w.range).faixaDoRegistro ?? ""
        for escopo in w.regras.reversed() {
            if let r = escopo.regra(w.name, faixa: faixaOriginal), var valor = r.valor {
                // `$react` quer dizer "a faixa que o projeto usa para react".
                if valor.hasPrefix("$") {
                    let nome = String(valor.dropFirst())
                    guard let daRaiz = pkg.dependencies[nome] ?? pkg.devDependencies[nome]
                        ?? pkg.optionalDependencies[nome] else { continue }
                    valor = daRaiz
                }
                return valor
            }
        }
        return nil
    }

    // MARK: - Um pedido

    func processar(_ w: Want) async {
        let p = pedido(w)
        switch p {
        case let .registro(real, faixa):
            await doRegistro(w, real: real, faixa: faixa)
        case let .tarball(url):
            await deFora(w, resolvido: url, baixar: url, integridade: true)
        case let .github(dono, repo, ref):
            await deFora(
                w,
                resolvido: Pedido.resolvidoDoGithub(dono: dono, repo: repo, ref: ref),
                baixar: "https://codeload.github.com/\(dono)/\(repo)/tar.gz/\(ref ?? "HEAD")",
                integridade: false
            )
        case let .arquivo(caminho):
            let rel = "file:" + installer.caminhoDoProjeto(caminho, a: w.from)
            await deFora(w, resolvido: rel, baixar: rel, integridade: true)
        case let .pasta(caminho):
            ligar(w, pasta: installer.caminhoDoProjeto(caminho, a: w.from))
        case let .workspace(faixa):
            guard let ws = workspaces[w.name] else {
                falhar(w, tr("%1$@: workspace:%2$@ pedido, mas não há workspace com esse nome", w.name, faixa))
                return
            }
            ligar(w, pasta: ws.pasta)
        case let .git(url):
            falhar(w, tr(
                "%1$@: dependência por git (%2$@) precisa do git, que não roda no iPad; só GitHub é baixado direto",
                w.name,
                url
            ))
        }
    }

    func falhar(_ w: Want, _ motivo: String) {
        if w.optional {
            report.skipped.append("\(w.name)@\(w.range)")
        } else {
            report.failed[w.name] = motivo
        }
    }

    /// A entrada do lock que atende o pedido, se houver.
    ///
    /// `confiavel` é falso num caso só: pedido opcional atendido por uma entrada que um
    /// lock antigo da Odete marcou como nativa sem dizer se era opcional nem de que
    /// plataforma. É o binário de plataforma que a versão anterior baixava; vale
    /// perguntar ao registro para saber, e se o registro não responder, fica o que o lock
    /// dizia.
    func doLock(_ w: Want, real: String, faixa: String) -> (entry: Lockfile.Entry, confiavel: Bool)? {
        guard pinned[w.name] == nil || !w.from.isEmpty, let lock,
              let (_, le) = lock.resolve(w.name, from: w.from), !le.link, (le.name ?? w.name) == real,
              let lv = Version(le.version), SemverRange(faixa).isAny || SemverRange(faixa).satisfies(lv)
        else { return nil }
        return (le, !(w.optional && !le.optional && le.native))
    }

    func doRegistro(_ w: Want, real: String, faixa: String) async {
        // O `npm install x@v` fixou a versão: `pedido` já trocou a faixa por ela.
        let fixada = w.from.isEmpty && pinned[w.name] != nil ? faixa : nil
        // já satisfeito em algum nível acima?
        if let (_, existing) = Self.achar(w.name, from: w.from, in: tree) {
            if atende(existing, real: real, faixa: faixa, fixada: fixada) {
                return
            }
            // Peer que não bate com o que já está lá: o npm pararia com ERESOLVE. Aqui
            // fica o que está (uma segunda cópia do React quebraria os hooks) e sai um aviso.
            if w.peer {
                report.avisos.append(tr(
                    "%1$@ pede %2$@@%3$@ como peer, mas a versão instalada é %4$@",
                    w.quem,
                    w.name,
                    faixa,
                    existing.entry.version
                ))
                return
            }
        }
        // Um workspace com esse nome e uma versão que serve é ligado em vez de baixado.
        if let ws = workspaces[w.name], let v = Version(ws.pkg.version ?? ""),
           SemverRange(faixa).isAny || SemverRange(faixa).satisfies(v)
        {
            ligar(w, pasta: ws.pasta)
            return
        }
        var chosen: Lockfile.Entry?
        let lockado = doLock(w, real: real, faixa: faixa)
        if let lockado, lockado.confiavel {
            chosen = lockado.entry
        } else {
            let pv: PackumentVersion?
            do {
                pv = try await versao(real, fixada ?? faixa)
            } catch {
                if let lockado {
                    chosen = lockado.entry
                } else {
                    report.semRede = report.semRede || Installer.ehErroDeRede(error)
                    falhar(w, error.localizedDescription)
                    return
                }
                pv = nil
            }
            if let pv {
                chosen = Lockfile.Entry(
                    version: pv.version.description,
                    resolved: pv.tarball,
                    integrity: pv.integrity,
                    dependencies: pv.dependencies,
                    optionalDependencies: pv.optionalDependencies,
                    bin: pv.bin,
                    dev: w.dev,
                    native: Installer.pareceBinarioNativo(real) || Installer.dependeDeNativo(pv.dependencies),
                    os: pv.os,
                    cpu: pv.cpu,
                    name: real == w.name ? nil : real,
                    peerDependencies: pv.peerDependencies,
                    peersOpcionais: pv.peersOpcionais,
                    temScripts: pv.hasInstallScript,
                    extras: pv.extras
                )
            } else if chosen == nil {
                if let lockado {
                    chosen = lockado.entry
                } else {
                    falhar(w, NpmError.noVersion(real, faixa).localizedDescription)
                    return
                }
            }
        }
        guard var c = chosen else { return }
        c.dev = w.dev
        c.optional = w.optional
        let lugar = Installer.plataforma(opcional: w.optional, os: c.os, cpu: c.cpu)
        if lugar == .deOutroSistema || lugar == .soNoLock {
            report.plataforma.append(tr(
                "%1$@ (só %2$@)",
                "\(w.name)",
                "\((c.os + c.cpu).joined(separator: ","))"
            ))
        }
        if lugar == .deOutroSistema {
            return
        }
        if lugar == .soNoLock {
            c.native = false
        }
        guard let key = colocar(w, c) else { return }
        tree[key]?.novo = lockado?.confiavel != true
        // O que o binário de plataforma puxaria entra no lock também, como no npm (o
        // `@emnapi/runtime` do `sharp-wasm32`), e fica de fora do disco junto com ele.
        enfileirarFilhos(de: key, c, w)
    }

    /// O nó `n` atende o pedido? Pelo nome de verdade (um alias com outro pacote dentro
    /// não serve) e pela versão.
    func atende(_ n: Node, real: String, faixa: String, fixada: String?) -> Bool {
        guard (n.entry.name ?? n.name) == real || n.entry.link else { return false }
        if n.entry.link, n.name != real {
            return false
        }
        guard let ev = Version(n.entry.version) else { return false }
        if let fixada {
            return fixada == n.entry.version
        }
        return SemverRange(faixa).isAny || SemverRange(faixa).satisfies(ev)
    }
}
