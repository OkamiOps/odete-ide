import Foundation
import OdeteFiles
import OdeteI18n

/// `npm install` de verdade: resolve, baixa, extrai, grava lock e .bin.
public struct Installer: Sendable {
    public struct Spec: Sendable, Hashable {
        public var name: String
        public var range: String
        public init(_ s: String) {
            if s.hasPrefix("@"),
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
    public func install(add: [Spec] = [], dev: Bool = false, force: Bool = false) async throws -> Report {
        var pkg = PackageJSON(url: project.appending(path: "package.json"))
        var report = Report()
        var pinned: [String: String] = [:]
        var jaBuscados: [String: Packument] = [:]
        for spec in add {
            let p = try await registry.packument(spec.name)
            guard let v = p.pick(spec.range) else { throw NpmError.noVersion(spec.name, spec.range) }
            let range = spec.range == "latest" || spec.range.isEmpty ? "^\(v.version)" : spec.range
            pkg.set(spec.name, range: range, dev: dev)
            pinned[spec.name] = v.version.description
            report.added.append("\(spec.name)@\(v.version)")
            jaBuscados[spec.name] = p
        }
        if !add.isEmpty {
            try pkg.save()
        }
        let lock = force ? nil : Lockfile.load(lockURL)
        let tree = try await resolve(pkg: pkg, lock: lock, pinned: pinned, jaBuscados: jaBuscados, report: &report)
        try PastaDeModulos.preparar(project, nuvem: nuvem)
        try await materialize(tree, report: &report)
        var newLock = Lockfile(name: pkg.name)
        for (key, node) in tree {
            newLock.packages[key] = node.entry
        }
        var root: [String: Any] = ["name": pkg.name]
        if !pkg.dependencies.isEmpty {
            root["dependencies"] = pkg.dependencies
        }
        if !pkg.devDependencies.isEmpty {
            root["devDependencies"] = pkg.devDependencies
        }
        try newLock.save(to: lockURL, root: root)
        try writeBins(tree, &report)
        try pruneExtraneous(tree)
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
            let rel = k.dropFirst("node_modules/".count)
            guard !rel.contains("/node_modules/"), !e.soDePlataforma else { return nil }
            return (String(rel), e.version, e.dev, e.native)
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
        var erro: String?
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
        for (key, node) in tree where !node.entry.soDePlataforma {
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
            log("baixando \(total) pacote(s)…")
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
                continue
            }
            if f.nativo {
                report.anotarNativo(f.name, f.version)
            }
            report.installed.append((f.name, f.version))
        }
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
            data = try await registry.tarball(url, integrity: node.entry.integrity)
        } catch {
            feito.erro = error.localizedDescription
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
                return nativo || FileManager.default.fileExists(atPath: dir.appending(path: "binding.gyp").path)
            }
        } catch {
            feito.erro = error.localizedDescription
        }
        return feito
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
        for (key, node) in tree where !node.entry.soDePlataforma {
            let parentNM = key.hasSuffix("/" + node.name) ? String(key.dropLast(node.name.count + 1)) : "node_modules"
            let binDirURL = project.appending(path: parentNM).appending(path: ".bin")
            for (bname, bpath) in node.entry.bin {
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
        let keep = Set(tree.filter { !$0.value.entry.soDePlataforma }.keys)
        func walk(_ chave: String, _ pasta: URL) {
            // Pelo caminho, não pela URL: `contentsOfDirectory(at:)` não atravessa link.
            guard let items = try? fm.contentsOfDirectory(atPath: pasta.path) else { return }
            for name in items {
                if name == ".bin" || name == ".package-lock.json" {
                    continue
                }
                let item = pasta.appending(path: name)
                if name.hasPrefix("@") {
                    for scoped in (try? fm.contentsOfDirectory(atPath: item.path)) ?? [] {
                        let k = "\(chave)/\(name)/\(scoped)"
                        if !keep.contains(k) {
                            try? fm.removeItem(at: item.appending(path: scoped))
                        } else {
                            walk("\(k)/node_modules", item.appending(path: scoped).appending(path: "node_modules"))
                        }
                    }
                    continue
                }
                let k = "\(chave)/\(name)"
                if !keep.contains(k) {
                    try? fm.removeItem(at: item)
                } else {
                    walk("\(k)/node_modules", item.appending(path: "node_modules"))
                }
            }
        }
        walk("node_modules", PastaDeModulos.pastaReal(project))
    }
}

extension Installer {
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
