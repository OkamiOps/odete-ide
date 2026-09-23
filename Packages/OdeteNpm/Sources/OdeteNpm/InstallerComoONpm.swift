import Foundation
import OdeteFiles
import OdeteI18n

/// O que o install grava (package.json, lock e o lock escondido) do jeito do npm, o
/// `npm ci`, e de onde vêm os pacotes que não são do registro.
extension Installer {
    /// O que o npm grava no package.json para `npm install x@<pedido>`: `^` e a versão
    /// escolhida quando o pedido é tag, versão ou faixa que contém esse `^`; a faixa como
    /// veio quando ela é mais estreita. `npm i dotenv@16` grava `^16.6.1`, não `16`.
    static func faixaParaSalvar(pedido: String, versao: Version, exato: Bool) -> String {
        if exato {
            return versao.description
        }
        let p = pedido.trimmingCharacters(in: .whitespaces)
        let circunflexo = "^\(versao.description)"
        // Tag (`latest`, `next`) ou versão exata: o `^` da escolhida.
        if p.isEmpty || p == "*" || Version(p) != nil || p.range(
            of: #"^[A-Za-z][\w.-]*$"#,
            options: .regularExpression
        ) != nil {
            return circunflexo
        }
        return SemverRange(p).contemCircunflexo(versao) ? circunflexo : p
    }

    /// O nome de um pacote que não vem do registro, lido do package.json dele.
    func nomeDoPacote(_ spec: String) async throws -> String {
        let manifesto: Data? = switch Pedido.de(spec) {
        case let .pasta(caminho):
            try? Data(contentsOf: project.appending(path: caminhoDoProjeto(caminho, a: ""))
                .appending(path: "package.json"))
        case let .tarball(url):
            try await Tar.manifesto(dadosDoTarball(url, integrity: nil))
        case let .arquivo(caminho):
            try await Tar.manifesto(dadosDoTarball("file:" + caminhoDoProjeto(caminho, a: ""), integrity: nil))
        case let .github(dono, repo, ref):
            try await Tar.manifesto(dadosDoTarball(
                "https://codeload.github.com/\(dono)/\(repo)/tar.gz/\(ref ?? "HEAD")",
                integrity: nil
            ))
        default:
            nil
        }
        guard let manifesto, let j = try? JSONOrdenado.ler(manifesto), let nome = j["name"]?.comoTexto else {
            throw NpmError.notFound(spec)
        }
        return nome
    }

    /// `npm ci`: instala exatamente o que o lock diz, do zero, e falha se o lock não
    /// corresponde ao package.json — em vez de resolver de novo e reescrever o lock.
    public func ci() async throws -> Report {
        let pkg = PackageJSON(url: project.appending(path: "package.json"))
        guard let lock = Lockfile.load(lockURL) else {
            throw NpmError.io(tr("npm ci precisa de um package-lock.json; rode npm install para criar um"))
        }
        var diferentes: [String] = []
        for campo in ["dependencies", "devDependencies", "optionalDependencies"] {
            let noPacote = pkg.json[campo]?.comoMapaDeTexto ?? [:]
            let noLock = lock.raiz[campo]?.comoMapaDeTexto ?? [:]
            for nome in Set(noPacote.keys).union(noLock.keys).sorted() where noPacote[nome] != noLock[nome] {
                diferentes.append(noPacote[nome].map { "\(nome)@\($0)" } ?? tr("%1$@ (só no lock)", nome))
            }
        }
        guard diferentes.isEmpty else {
            throw NpmError.io(tr(
                "package.json e package-lock.json não batem (%1$@); rode npm install para atualizar o lock",
                diferentes.joined(separator: ", ")
            ))
        }
        // Do zero, como o npm: os pacotes saem, e o que é cache de ferramenta (o
        // `.odete-deps`, o `.vite`) fica — um pacote reinstalado invalida o que dependia dele.
        let pasta = PastaDeModulos.pastaReal(project)
        for item in (try? FileManager.default.contentsOfDirectory(atPath: pasta.path)) ?? []
            where !item.hasPrefix(".") || item == ".bin" || item == ".package-lock.json"
        {
            try? FileManager.default.removeItem(at: pasta.appending(path: item))
        }
        var report = Report()
        let tree = try await resolve(pkg: pkg, lock: lock, pinned: [:], report: &report)
        try PastaDeModulos.preparar(project, nuvem: nuvem)
        try await materialize(tree, report: &report)
        try gravarLockOculto(tree, estilo: JSONOrdenado.Estilo.de(try? Data(contentsOf: lockURL)).paraOLock)
        try writeBins(tree, &report)
        return report
    }

    /// Os campos que o npm grava no lock e o packument abreviado não traz, para o lock
    /// sair igual ao do npm: `license`, `funding` (como o pacote escreveu), `engines` e
    /// `libc`. Do que foi instalado, vêm do package.json no disco; do binário de plataforma,
    /// que não é baixado, do documento completo da versão — um pedido pequeno por pacote,
    /// e só quando ele entrou agora (o que veio do lock já tem tudo).
    func completarMetadados(_ tree: [String: Node]) async -> [String: Node] {
        var out = tree
        var deFora: [(String, String, String)] = [] // chave, nome, versão
        for (key, node) in tree where node.novo && !node.entry.link {
            if Resolvedor.ficaDeFora(node) {
                deFora.append((key, node.entry.name ?? node.name, node.entry.version))
                continue
            }
            let pj = project.appending(path: key).appending(path: "package.json")
            guard let d = try? Data(contentsOf: pj), let j = try? JSONOrdenado.ler(d) else { continue }
            out[key]?.entry = Self.comMetadados(node.entry, de: j, disco: project.appending(path: key))
        }
        let registry = registry
        let manifestos = await withTaskGroup(of: (String, Data?).self) { group -> [String: Data] in
            var proximo = 0
            func lancar(_ group: inout TaskGroup<(String, Data?)>) {
                let (key, nome, versao) = deFora[proximo]
                proximo += 1
                group.addTask { await (key, try? registry.manifestoCompleto(nome, versao)) }
            }
            while proximo < min(8, deFora.count) {
                lancar(&group)
            }
            var r: [String: Data] = [:]
            for await (key, d) in group {
                r[key] = d
                if proximo < deFora.count {
                    lancar(&group)
                }
            }
            return r
        }
        for (key, d) in manifestos {
            guard let e = out[key]?.entry, let j = try? JSONOrdenado.ler(d) else { continue }
            out[key]?.entry = Self.comMetadados(e, de: j, disco: nil)
        }
        return out
    }

    static func comMetadados(_ e: Lockfile.Entry, de j: JSONOrdenado, disco: URL?) -> Lockfile.Entry {
        var e = e
        var extras = e.extras
        for campo in ["license", "funding", "engines", "libc"] {
            if let v = j[campo] {
                extras[campo] = campo == "funding" ? v.fundingComoONpm : v
            }
        }
        e.extras = extras
        if disco != nil {
            // O `bin` e os peers de verdade são os do pacote instalado.
            let pkg = PackageJSON(json: j, url: URL(filePath: "/"))
            if j["bin"] != nil {
                e.bin = Packument.normalizarBin(pkg.bin)
            }
            // `binding.gyp` sem script de instalação: o npm diz que tem (o node-gyp roda).
            if let disco, FileManager.default.fileExists(atPath: disco.appending(path: "binding.gyp").path) {
                e.temScripts = true
            }
        }
        return e
    }

    /// O package-lock.json e o `node_modules/.package-lock.json`, no formato do npm.
    func gravarLocks(_ tree: [String: Node], pkg: PackageJSON, lock: Lockfile?) throws {
        var novo = Lockfile(name: pkg.name)
        for (key, node) in tree {
            novo.packages[key] = node.entry
        }
        // Lock que já existe dita o formato; senão, o do package.json.
        let dadosDoLock = try? Data(contentsOf: lockURL)
        let estilo = (dadosDoLock != nil ? JSONOrdenado.Estilo.de(dadosDoLock) : pkg.estilo).paraOLock
        try novo.save(to: lockURL, raiz: Self.raizDoLock(pkg), versao: pkg.version, estilo: estilo)
        try gravarLockOculto(tree, estilo: estilo)
    }

    /// O lock escondido que o npm grava dentro de node_modules: o mesmo lock, só com o
    /// que está lá dentro. É ele que muda a cada install (o package-lock.json pode não
    /// mudar), e o dev server o vigia para saber que os pacotes mudaram.
    func gravarLockOculto(_ tree: [String: Node], estilo: JSONOrdenado.Estilo) throws {
        var oculto = Lockfile(name: PackageJSON(url: project.appending(path: "package.json")).name)
        for (key, node) in tree where key.hasPrefix("node_modules/") && !Resolvedor.ficaDeFora(node) {
            oculto.packages[key] = node.entry
        }
        let destino = PastaDeModulos.pastaReal(project).appending(path: ".package-lock.json")
        try Data(oculto.json(raiz: .objeto([]), oculto: true).gravado(estilo).utf8).write(to: destino, options: .atomic)
    }

    /// A entrada `""` do lock: o que o npm copia do package.json.
    static func raizDoLock(_ pkg: PackageJSON) -> JSONOrdenado {
        var r: [(String, JSONOrdenado)] = [("name", .texto(pkg.name))]
        for campo in [
            "version", "license", "workspaces", "dependencies", "devDependencies", "optionalDependencies",
            "peerDependencies", "peerDependenciesMeta", "bin", "engines",
        ] {
            if let v = pkg.json[campo] {
                if case let .objeto(p) = v, p.isEmpty {
                    continue
                }
                r.append((campo, v))
            }
        }
        return .objeto(r)
    }

    /// Caminho, relativo ao projeto, de uma pasta pedida por `file:` a partir de quem
    /// pediu (`""` é o projeto). Fica como o npm escreve no lock: `zz`, `packages/web`,
    /// `../lib` — sem `./`.
    func caminhoDoProjeto(_ caminho: String, a quem: String) -> String {
        let base = (quem.isEmpty ? project : project.appending(path: quem)).standardizedFileURL
        let alvo = (caminho.hasPrefix("/") ? URL(filePath: caminho) : base.appending(path: caminho))
            .standardizedFileURL.pathComponents
        let raiz = project.standardizedFileURL.pathComponents
        var comum = 0
        while comum < min(alvo.count, raiz.count), alvo[comum] == raiz[comum] {
            comum += 1
        }
        let subir = Array(repeating: "..", count: raiz.count - comum)
        let rel = (subir + alvo[comum...]).joined(separator: "/")
        return rel.isEmpty ? "." : rel
    }

    /// Os bytes do tarball: do registro (ou de qualquer URL), do GitHub pelo codeload, ou
    /// de um `.tgz` do projeto (`file:`).
    func dadosDoTarball(_ fonte: String, integrity: String?) async throws -> Data {
        if fonte.hasPrefix("file:") {
            let u = project.appending(path: String(fonte.dropFirst(5)))
            guard let d = try? Data(contentsOf: u) else {
                throw NpmError.tarball(tr("não achei %1$@", u.lastPathComponent))
            }
            return d
        }
        return try await registry.tarball(Pedido.codeload(deResolvido: fonte) ?? fonte, integrity: integrity)
    }
}
