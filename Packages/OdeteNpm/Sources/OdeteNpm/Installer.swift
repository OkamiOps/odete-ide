import Foundation
import OdeteFiles
import OdeteI18n

/// `npm install` de verdade: resolve, baixa, extrai, grava lock e .bin.
public struct Installer: Sendable {
    public struct Spec: Sendable, Hashable {
        public var name: String
        public var range: String
        public init(_ s: String) {
            // URL, GitHub, pasta: o texto inteiro é o pedido (o `@` de `git@github.com`
            // não separa nome de versão), e o nome sai do package.json do pacote.
            if Pedido.de(s).faixaDoRegistro == nil {
                name = s; range = "latest"
            } else if s.hasPrefix("@"),
                      let at = s.dropFirst()
                      .firstIndex(of: "@")
            {
                name = String(s[..<at]); range = String(s[s.index(after: at)...])
            } else if let at = s.firstIndex(of: "@"),
                      at != s.startIndex
            {
                name = String(s[..<at]); range = String(s[s.index(after: at)...])
            } else {
                name = s; range = "latest"
            }
        }
    }

    public struct Report: Sendable {
        public var installed: [(name: String, version: String)] = []
        public var native: [String] = []
        /// Nativos que a Odete já cobre por dentro (o próprio esbuild, o rollup do vite,
        /// o fsevents). Avisar sobre cada um deles a cada instalação é ruído: não falta
        /// nada e não há o que a pessoa fazer.
        public var nativosCobertos: [String] = []
        public var skipped: [String] = []
        /// Pacotes de outro sistema ou outra arquitetura, e os binários de plataforma que
        /// ficam só no lock. São rotina — rollup e esbuild publicam um binário por
        /// plataforma — e não merecem o mesmo alarde de um `file:` que não dá para resolver.
        public var plataforma: [String] = []
        public var failed: [String: String] = [:]
        public var added: [String] = []
        /// Pacotes com `preinstall`/`install`/`postinstall` que não foram rodados (e não
        /// têm código nativo) — como o npm 12 faz sem aprovação. O `core-js` só imprime
        /// um recado; chamar isso de "nativo que não roda no iPad" assustava à toa.
        public var scripts: [String] = []
        /// Alguma falha foi de rede (sem internet, registro fora do ar): quem chamou pode
        /// dizer isso em vez de listar um erro por pacote.
        public var semRede = false
        /// Coisas que não impedem a instalação mas mudam o resultado, como um atalho de
        /// `.bin` que não deu para criar — é ele que faz `vite` responder pelo nome.
        public var avisos: [String] = []
    }

    public var project: URL
    public var registry: any RegistryClient
    public var log: @Sendable (String) -> Void
    /// Pacotes em voo ao mesmo tempo, cada um baixando e já extraindo. É também o teto
    /// de tarballs comprimidos na memória: acabou de extrair, o tarball vai embora.
    public var concurrency = 6
    /// Packuments no ar ao mesmo tempo durante a resolução.
    var buscasSimultaneas = 8
    /// O projeto mora no iCloud Drive? Aí os pacotes vão para `node_modules.nosync` e
    /// `node_modules` vira link — ver `PastaDeModulos`. Vem detectado do caminho; dá
    /// para forçar, que é o que os testes fazem.
    public var nuvem: Bool
    var medidor: MedidorDeMemoria?

    public init(project: URL, registry: any RegistryClient, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.project = project; self.registry = registry; self.log = log
        nuvem = PastaDeModulos.naNuvem(project)
    }

    var lockURL: URL {
        project.appending(path: "package-lock.json")
    }

    // MARK: API

    /// `npm install [specs]` (`add` vazio = instalar tudo do package.json).
    ///
    /// `exato` é o `--save-exact`: grava a versão sem o `^`.
    public func install(
        add: [Spec] = [],
        dev: Bool = false,
        force: Bool = false,
        exato: Bool = false
    ) async throws -> Report {
        var pkg = PackageJSON(url: project.appending(path: "package.json"))
        var report = Report()
        var pinned: [String: String] = [:]
        var jaBuscados: [String: Packument] = [:]
        for spec in add {
            // `npm i github:dono/repo`, `npm i ./pasta`, `npm i https://…/x.tgz`: o nome
            // vem do package.json do pacote, e o que se grava é o pedido como veio.
            if spec.range == "latest", Pedido.de(spec.name).faixaDoRegistro == nil {
                var pedido = spec.name
                let nome = try await nomeDoPacote(pedido)
                // Pasta e `.tgz` locais vão para o package.json como o npm grava: `file:`
                // e o caminho a partir do projeto (`npm i ./libs/ui` → `file:libs/ui`).
                switch Pedido.de(pedido) {
                case let .pasta(c), let .arquivo(c): pedido = "file:" + caminhoDoProjeto(c, a: "")
                default: break
                }
                pkg.set(nome, range: pedido, dev: dev)
                report.added.append("\(nome)@\(pedido)")
                continue
            }
            guard case let .registro(nomeReal, faixa) = Pedido.de(spec.range) else {
                pkg.set(spec.name, range: spec.range, dev: dev)
                report.added.append("\(spec.name)@\(spec.range)")
                continue
            }
            // `npm i meu-ms@npm:ms@2`: a pasta é `meu-ms`, o pacote é `ms`.
            let real = nomeReal.isEmpty ? spec.name : nomeReal
            let p = try await registry.packument(real)
            guard let v = p.pick(faixa) else { throw NpmError.noVersion(real, faixa) }
            let salvo = Self.faixaParaSalvar(pedido: faixa, versao: v.version, exato: exato)
            pkg.set(spec.name, range: real == spec.name ? salvo : "npm:\(real)@\(salvo)", dev: dev)
            pinned[spec.name] = real == spec.name ? v.version.description : "npm:\(real)@\(v.version)"
            report.added.append("\(spec.name)@\(v.version)")
            jaBuscados[real] = p
        }
        if !add.isEmpty {
            try pkg.save()
        }
        let lock = force ? nil : Lockfile.load(lockURL)
        let tree = try await resolve(pkg: pkg, lock: lock, pinned: pinned, jaBuscados: jaBuscados, report: &report)
        try PastaDeModulos.preparar(project, nuvem: nuvem)
        try await materialize(tree, report: &report)
        let completa = await completarMetadados(tree)
        try gravarLocks(completa, pkg: pkg, lock: lock)
        try writeBins(completa, &report)
        try pruneExtraneous(completa)
        return report
    }

    public func uninstall(_ names: [String]) async throws -> Report {
        var pkg = PackageJSON(url: project.appending(path: "package.json"))
        for n in names {
            pkg.remove(n)
        }
        try pkg.save()
        return try await install()
    }

    /// Pacotes de primeiro nível instalados.
    public func list() -> [(name: String, version: String, dev: Bool, native: Bool)] {
        guard let lock = Lockfile.load(lockURL) else { return [] }
        return lock.packages.compactMap { k, e in
            guard k.hasPrefix("node_modules/") else { return nil }
            let rel = k.dropFirst("node_modules/".count)
            guard !rel.contains("/node_modules/"), !e.soDePlataforma else { return nil }
            // No lock mas não no disco: o que só um binário de plataforma puxava.
            guard e.link || FileManager.default.fileExists(atPath: project.appending(path: k)
                .appending(path: "package.json").path) else { return nil }
            // Atalho para pasta do projeto: a versão está na entrada da pasta.
            let versao = e.link ? (e.resolved.flatMap { lock.packages[$0]?.version } ?? e.version) : e.version
            return (String(rel), versao, e.dev, e.native)
        }.sorted { $0.name < $1.name }
    }

    /// Acrescenta ao `.gitignore` o que falta para o git não ver os pacotes e devolve o
    /// que acrescentou. No iCloud são duas linhas — ver `PastaDeModulos`.
    public func garantirGitignore() -> [String] {
        PastaDeModulos.garantirGitignore(project, nuvem: nuvem)
    }
}

// MARK: - download + extração

extension Installer {
    /// O resultado de um pacote, devolvido pela tarefa que o baixou e extraiu.
    struct Extraido: Sendable {
        var key: String
        var name: String
        var version: String
        var nativo = false
        /// Tem script de instalação que não foi rodado (e não é nativo).
        var scripts = false
        var erro: String?
        var semRede = false
    }

    /// Profundidade de aninhamento: `node_modules/a` e `node_modules/@s/a` são 1,
    /// `node_modules/a/node_modules/b` é 2.
    static func nivel(_ key: String) -> Int {
        key.split(separator: "/").count(where: { $0 == "node_modules" })
    }

    /// Baixa e extrai o que falta, com `concurrency` pacotes em voo.
    ///
    /// Antes, todos os tarballs eram baixados primeiro (em lotes de quatro que esperavam
    /// o mais lento) e só então extraídos: numa instalação grande, dezenas de megas
    /// comprimidos na memória de uma vez, e a extração ainda triplicava o pacote do
    /// momento. É o tipo de pico que faz o iPad matar o app. Agora cada pacote é extraído
    /// assim que chega e o tarball é solto logo em seguida; quem termina abre vaga para o
    /// próximo, sem esperar o lote.
    ///
    /// Pais antes dos aninhados: extrair `node_modules/c` mexe na pasta de `c` (e, se der
    /// errado, apaga a pasta inteira), o que não pode acontecer ao mesmo tempo que um
    /// `node_modules/c/node_modules/b` é extraído ali dentro. Por isso vai nível por
    /// nível — quase tudo fica no primeiro, então quase nada se perde de paralelismo.
    func materialize(_ tree: [String: Node], report: inout Report) async throws {
        var todo: [(String, Node)] = []
        for (key, node) in tree where !Resolvedor.ficaDeFora(node) {
            // A pasta de um workspace ou de um `file:` é do projeto: não se baixa nada.
            guard key.hasPrefix("node_modules/") || key.contains("/node_modules/") else { continue }
            if node.entry.link {
                try criarAtalho(key, node)
                continue
            }
            let marker = project.appending(path: key).appending(path: "package.json")
            if let d = try? Data(contentsOf: marker),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               (j["version"] as? String) == node.entry.version
            {
                continue
            }
            todo.append((key, node))
        }
        let total = todo.count
        if total > 0 {
            log(tr("baixando %1$@ pacote(s)…", "\(total)"))
        }
        var feitos: [Extraido] = []
        let niveis = Dictionary(grouping: todo) { Self.nivel($0.0) }
        for nivel in niveis.keys.sorted() {
            let lote = (niveis[nivel] ?? []).sorted { $0.0 < $1.0 }
            let jaFeitos = feitos.count
            let doNivel = await withTaskGroup(of: Extraido.self) { group -> [Extraido] in
                var proximo = 0
                func lancar(_ group: inout TaskGroup<Extraido>) {
                    let (key, node) = lote[proximo]
                    proximo += 1
                    group.addTask { await baixarEExtrair(key, node) }
                }
                while proximo < min(concurrency, lote.count) {
                    lancar(&group)
                }
                var out: [Extraido] = []
                for await r in group {
                    out.append(r)
                    let done = jaFeitos + out.count
                    if done % 10 == 0 || done == total {
                        log("\(done)/\(total)")
                    }
                    if proximo < lote.count {
                        lancar(&group)
                    }
                }
                return out
            }
            feitos += doNivel
        }
        // Mesma ordem de relatório de antes: pais primeiro, depois pelo caminho.
        feitos.sort { a, b in
            let na = Self.nivel(a.key), nb = Self.nivel(b.key)
            return na != nb ? na < nb : a.key < b.key
        }
        for f in feitos {
            if let erro = f.erro {
                report.failed[f.name] = erro
                report.semRede = report.semRede || f.semRede
                continue
            }
            // O esbuild instala o binário no `postinstall`: é nativo, e a Odete cobre por dentro.
            if f.nativo || (f.scripts && Self.cobertoPorDentro(f.name)) {
                report.anotarNativo(f.name, f.version)
            } else if f.scripts {
                report.scripts.append("\(f.name)@\(f.version)")
            }
            report.installed.append((f.name, f.version))
        }
        report.scripts = Array(Set(report.scripts)).sorted()
        report.native = Array(Set(report.native)).sorted()
        report.nativosCobertos = Array(Set(report.nativosCobertos)).sorted()
    }

    /// Um pacote, do download ao disco. O tarball vive só dentro desta função.
    func baixarEExtrair(_ key: String, _ node: Node) async -> Extraido {
        var feito = Extraido(key: key, name: node.name, version: node.entry.version)
        guard let url = node.entry.resolved else {
            feito.erro = NpmError.tarball(tr("sem URL para %1$@", "\(node.name)")).localizedDescription
            return feito
        }
        let data: Data
        do {
            data = try await dadosDoTarball(url, integrity: node.entry.integrity)
        } catch {
            feito.erro = error.localizedDescription
            feito.semRede = Self.ehErroDeRede(error)
            return feito
        }
        let segurado = data.count + Tar.tamanhoDoPedaco
        medidor?.segurar(segurado)
        defer { medidor?.soltar(segurado) }
        let dir = project.appending(path: key)
        let nativo = node.entry.native
        do {
            feito.nativo = try await Self.noDisco {
                Self.limparVersaoVelha(dir)
                do {
                    try Tar.extractPackage(data, to: dir)
                } catch {
                    // Pela metade não serve: o package.json costuma vir primeiro, e com
                    // ele no lugar o próximo install acharia que o pacote está completo.
                    try? FileManager.default.removeItem(at: dir)
                    throw error
                }
                return nativo || Self.temCodigoNativo(dir)
            }
            feito.scripts = !feito.nativo && node.entry.temScripts
        } catch {
            feito.erro = error.localizedDescription
        }
        return feito
    }

    /// Addon nativo no disco: `binding.gyp` (o node-gyp compilaria no install) ou um
    /// `.node` já compilado, na raiz do pacote ou onde os pré-compilados costumam ficar.
    /// Não desce no pacote inteiro: o `next` tem milhares de arquivos.
    static func temCodigoNativo(_ dir: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appending(path: "binding.gyp").path) {
            return true
        }
        for sub in ["", "build/Release", "prebuilds", "bin"] {
            let pasta = sub.isEmpty ? dir : dir.appending(path: sub)
            let itens = (try? fm.contentsOfDirectory(atPath: pasta.path)) ?? []
            if itens.contains(where: { $0.hasSuffix(".node") }) {
                return true
            }
            // `prebuilds/darwin-arm64/x.node`
            if sub == "prebuilds" {
                for plataforma in itens {
                    let dentro = (try? fm.contentsOfDirectory(atPath: pasta.appending(path: plataforma).path)) ?? []
                    if dentro.contains(where: { $0.hasSuffix(".node") }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// `node_modules/<nome>` apontando para a pasta do workspace ou do `file:`, com o
    /// caminho relativo que o npm usa (`../packages/web`).
    func criarAtalho(_ key: String, _ node: Node) throws {
        guard let alvo = node.entry.resolved else { return }
        let fm = FileManager.default
        let link = project.appending(path: key)
        let pasta = key.split(separator: "/").dropLast().map(String.init)
        let destino = (Array(repeating: "..", count: pasta.count) + [alvo]).joined(separator: "/")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == destino {
            return
        }
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: destino)
    }

    /// Apaga a versão anterior do pacote, menos o `node_modules` de dentro dela.
    ///
    /// Os aninhados que não mudaram de versão não estão na lista para extrair de novo;
    /// apagar a pasta inteira, como antes, levava eles junto e o pacote ficava sem as
    /// dependências. O que sobrar ali sem estar na árvore sai no `pruneExtraneous`.
    static func limparVersaoVelha(_ dir: URL) {
        let fm = FileManager.default
        guard let itens = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for item in itens where item != "node_modules" {
            try? fm.removeItem(at: dir.appending(path: item))
        }
    }

    /// Extração é disco e CPU sem pausa. Na fila própria ela não prende as threads do
    /// pool das tarefas, que o resto do app também usa.
    static let filaDeDisco = DispatchQueue(label: "odete.npm.extracao", qos: .utility, attributes: .concurrent)

    static func noDisco<T: Sendable>(_ trabalho: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuacao in
            filaDeDisco.async {
                continuacao.resume(with: Result { try trabalho() })
            }
        }
    }
}

/// As duas etapas finais do install, que não dependem de mais nada da Installer.
extension Installer {
    func writeBins(_ tree: [String: Node], _ report: inout Report) throws {
        let fm = FileManager.default
        for (key, node) in tree where !Resolvedor.ficaDeFora(node) && key.hasPrefix("node_modules/") {
            let parentNM = key.hasSuffix("/" + node.name) ? String(key.dropLast(node.name.count + 1)) : "node_modules"
            let binDirURL = project.appending(path: parentNM).appending(path: ".bin")
            // Atalho de workspace ou `file:`: os binários são os da pasta.
            let bins = node.entry.link ? (node.entry.resolved.flatMap { tree[$0]?.entry.bin } ?? [:]) : node.entry.bin
            for (bname, bpath) in bins {
                try fm.createDirectory(at: binDirURL, withIntermediateDirectories: true)
                let link = binDirURL.appending(path: bname)
                try? fm.removeItem(at: link)
                let target = "../\(node.name)/\(bpath)"
                do {
                    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
                } catch {
                    // Sem o atalho, o comando existe no disco mas não responde pelo nome,
                    // e o terminal diz só "comando não encontrado". Melhor dizer agora.
                    report.avisos.append(tr(
                        "não deu para criar o atalho de %1$@: %2$@",
                        "\(bname)",
                        "\(error.localizedDescription)"
                    ))
                }
            }
        }
    }

    /// Remove de node_modules o que não está na árvore.
    ///
    /// Compara pela chave do lock (`node_modules/a/node_modules/b`), não pelo caminho no
    /// disco: no iCloud, `node_modules` é um link, e a listagem é feita na pasta real,
    /// que tem outro nome.
    func pruneExtraneous(_ tree: [String: Node]) throws {
        let fm = FileManager.default
        let keep = Set(tree.filter { !Resolvedor.ficaDeFora($0.value) }.keys)
        // Atalho para pasta do projeto: não se desce nele — o node_modules lá dentro é do
        // workspace, e as chaves dele no lock não começam por aqui.
        let atalhos = Set(tree.filter(\.value.entry.link).keys)
        // Dependências que vêm dentro do tarball (`bundleDependencies`): não estão na
        // árvore, e apagá-las deixaria o pacote sem elas.
        var embutidas: [String: Set<String>] = [:]
        for (k, n) in tree where !n.entry.embutidas.isEmpty {
            embutidas[k + "/node_modules"] = n.entry.embutidas
        }
        func walk(_ chave: String, _ pasta: URL) {
            // Pelo caminho, não pela URL: `contentsOfDirectory(at:)` não atravessa link.
            guard let items = try? fm.contentsOfDirectory(atPath: pasta.path) else { return }
            for name in items {
                // Nome de pacote npm nunca começa com ponto: o que começa é de ferramenta
                // (`.bin`, `.package-lock.json`, o `.odete-deps` do dev server, o `.vite`,
                // o `.cache`) e fica, como no npm. Apagar o `.odete-deps` a cada install
                // jogava fora o pacote de dependências e o próximo `npm run dev` o refazia
                // do zero — seis segundos de CPU num iPad sem JIT.
                if name.hasPrefix(".") {
                    continue
                }
                let item = pasta.appending(path: name)
                if name.hasPrefix("@") {
                    for scoped in (try? fm.contentsOfDirectory(atPath: item.path)) ?? [] {
                        let k = "\(chave)/\(name)/\(scoped)"
                        if embutidas[chave]?.contains("\(name)/\(scoped)") == true {
                            continue
                        }
                        if !keep.contains(k) {
                            try? fm.removeItem(at: item.appending(path: scoped))
                        } else if !atalhos.contains(k) {
                            walk("\(k)/node_modules", item.appending(path: scoped).appending(path: "node_modules"))
                        }
                    }
                    continue
                }
                let k = "\(chave)/\(name)"
                if embutidas[chave]?.contains(name) == true {
                    continue
                }
                if !keep.contains(k) {
                    try? fm.removeItem(at: item)
                } else if !atalhos.contains(k) {
                    walk("\(k)/node_modules", item.appending(path: "node_modules"))
                }
            }
        }
        walk("node_modules", PastaDeModulos.pastaReal(project))
    }
}

extension Installer {
    /// Erro de rede, e não do pacote: sem internet, sem DNS, registro que não responde.
    public static func ehErroDeRede(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        return [
            .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff,
        ].contains(u.code)
    }

    /// Ferramentas de build cujo equivalente já roda dentro da Odete. Um `sharp` ou um
    /// `better-sqlite3` continuam sendo aviso de verdade: aí falta mesmo.
    static func cobertoPorDentro(_ nome: String) -> Bool {
        if nome == "esbuild" || nome == "rollup" || nome == "fsevents" {
            return true
        }
        return nome.hasPrefix("@esbuild/") || nome.hasPrefix("@rollup/rollup-") || nome.hasPrefix("@swc/")
    }
}

extension Installer.Report {
    /// Nativo com equivalente embutido vai para a lista silenciosa; o resto vira aviso.
    mutating func anotarNativo(_ nome: String, _ versao: String) {
        if Installer.cobertoPorDentro(nome) {
            nativosCobertos.append("\(nome)@\(versao)")
        } else {
            native.append("\(nome)@\(versao)")
        }
    }
}
