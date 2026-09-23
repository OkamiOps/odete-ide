import CryptoKit
import Foundation
import OdeteCore
@testable import OdeteNpm
import Testing

/// O que o npm de verdade faz e o daqui não fazia. Cada teste falhava antes da mudança.
struct CompatibilidadeTests {
    func texto(_ u: URL) throws -> String {
        try String(contentsOf: u, encoding: .utf8)
    }

    func escrever(_ s: String, _ u: URL) throws {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: u, atomically: true, encoding: .utf8)
    }

    func existe(_ u: URL) -> Bool {
        FileManager.default.fileExists(atPath: u.path)
    }

    // MARK: - semver

    @Test(arguments: [
        (">= 1.2.3", "1.5.0", true), (">= 1.2.3", "1.2.3", true), (">= 1.2.3 < 2", "2.0.0", false),
        ("^ 1.2", "1.9.0", true), ("~ 1.2.3", "1.2.9", true),
        ("1.2 - 2.3", "2.9.0", false), ("1.2 - 2.3", "2.3.9", true), ("1 - 2", "2.9.0", true), (
            "1 - 2",
            "3.0.0",
            false
        ),
        (">1.2", "1.2.5", false), (">1.2", "1.3.0", true), ("<=1.2", "1.2.9", true), ("<=1.2", "1.3.0", false),
        ("<1.2", "1.1.9", true), ("<1.2", "1.2.0", false),
    ])
    func faixas(range: String, version: String, expected: Bool) throws {
        #expect(try SemverRange(range).satisfies(#require(Version(version))) == expected, "\(range) vs \(version)")
    }

    /// Com o `latest` servindo, é ele — não um `5.9.0` publicado com a tag `next`.
    @Test func escolheOLatestQuandoServe() {
        let r = FakeRegistry()
        r.add("x", "5.1.0")
        r.add("x", "5.9.0", latest: false)
        r.add("x", "5.8.0", latest: false, deprecated: "não use")
        #expect(r.packuments["x"]?.pick("^5.0.0")?.version.description == "5.1.0")
        #expect(r.packuments["x"]?.pick("^5.2.0")?.version.description == "5.9.0")
        #expect(r.packuments["x"]?.pick("5.8.x")?.version.description == "5.8.0")
    }

    // MARK: - alias npm:

    /// O `@isaacs/cliui` do glob@10 pede `"string-width-cjs": "npm:string-width@^4.2.0"`.
    /// O packument tem de ser o do `string-width`; a pasta é `string-width-cjs`.
    @Test func aliasBuscaOPacoteDeVerdade() async throws {
        let reg = FakeRegistry()
        reg.add("string-width", "4.2.3", files: ["index.js": "module.exports = 4;"], latest: false)
        reg.add("string-width", "5.1.2", files: ["index.js": "module.exports = 5;"])
        reg.add("cliui", "8.0.2", deps: ["string-width": "^5.1.2", "string-width-cjs": "npm:string-width@^4.2.0"])
        let dir = try project(["cliui": "^8.0.0"])
        let rep = try await Installer(project: dir, registry: reg).install()
        #expect(rep.failed.isEmpty, "\(rep.failed)")
        #expect(try texto(dir.appending(path: "node_modules/string-width-cjs/index.js")) == "module.exports = 4;")
        #expect(try texto(dir.appending(path: "node_modules/string-width/index.js")) == "module.exports = 5;")
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        let alias = try #require(lock.packages["node_modules/string-width-cjs"])
        #expect(alias.name == "string-width" && alias.version == "4.2.3")
        // Segunda vez, pelo lock: nenhuma pergunta ao registro.
        let antes = reg.hits.withLock { $0 }
        let rep2 = try await Installer(project: dir, registry: reg).install()
        #expect(rep2.failed.isEmpty)
        #expect(reg.hits.withLock { $0 } == antes)
    }

    /// `npm i meu@npm:ms@2` grava `npm:ms@^2.1.3`, como o npm.
    @Test func instalarAliasGravaComoONpm() async throws {
        let reg = FakeRegistry()
        reg.add("ms", "2.1.3", files: ["index.js": "1"])
        let dir = try project([:])
        let rep = try await Installer(project: dir, registry: reg).install(add: [Installer.Spec("meu@npm:ms@2")])
        #expect(rep.failed.isEmpty, "\(rep.failed)")
        #expect(PackageJSON(url: dir.appending(path: "package.json")).dependencies == ["meu": "npm:ms@^2.1.3"])
        #expect(existe(dir.appending(path: "node_modules/meu/index.js")))
    }

    // MARK: - peers

    /// `@testing-library/react` pede `@testing-library/dom` como peer: o npm 7+ instala.
    /// Peer opcional (`peerDependenciesMeta`) não entra.
    @Test func peerObrigatorioEntraEOpcionalNao() async throws {
        let reg = FakeRegistry()
        reg.add("dom", "10.4.0", deps: ["aria": "^5.0.0"], files: ["index.js": "dom"])
        reg.add("aria", "5.3.0", files: ["index.js": "aria"])
        reg.add("tipos", "19.0.0")
        reg.add("react", "19.2.0", files: ["index.js": "r"])
        reg.add(
            "tl-react",
            "16.3.0",
            peer: ["dom": "^10.0.0", "tipos": "^19", "react": "^18 || ^19"],
            peersOpcionais: ["tipos"]
        )
        let dir = try project(["tl-react": "^16.0.0", "react": "^19.0.0"])
        let rep = try await Installer(project: dir, registry: reg).install()
        #expect(rep.failed.isEmpty, "\(rep.failed)")
        #expect(existe(dir.appending(path: "node_modules/dom/index.js")))
        #expect(existe(dir.appending(path: "node_modules/aria/index.js")))
        #expect(!existe(dir.appending(path: "node_modules/tipos")))
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        // Só alcançados por peer: a marca do npm. O react é do projeto, não é peer.
        #expect(lock.packages["node_modules/dom"]?.peer == true)
        #expect(lock.packages["node_modules/aria"]?.peer == true)
        #expect(lock.packages["node_modules/react"]?.peer == false)
        #expect(lock.packages["node_modules/tl-react"]?.peersOpcionais == ["tipos"])
    }

    /// Peer que não bate com o que o projeto tem: fica o do projeto (uma segunda cópia
    /// do React quebraria os hooks) e sai um aviso.
    @Test func peerEmConflitoAvisaENaoDuplica() async throws {
        let reg = FakeRegistry()
        reg.add("react", "17.0.2", latest: false)
        reg.add("react", "19.2.0")
        reg.add("velho", "1.0.0", peer: ["react": "^17"])
        let dir = try project(["velho": "^1.0.0", "react": "^19.0.0"])
        let rep = try await Installer(project: dir, registry: reg).install()
        #expect(rep.failed.isEmpty)
        #expect(rep.avisos.contains { $0.contains("react") })
        #expect(!existe(dir.appending(path: "node_modules/velho/node_modules/react")))
    }

    // MARK: - fora do registro

    func tgz(_ nome: String, _ versao: String, raiz: String = "package", deps: [String: String] = [:]) -> Data {
        let pj = try! JSONSerialization.data(withJSONObject: ["name": nome, "version": versao, "dependencies": deps])
        return GzipCodec.compress(Tar.write([
            Tar.Entry(path: "\(raiz)/package.json", data: pj, isDir: false, mode: 0o644, link: nil),
            Tar.Entry(
                path: "\(raiz)/index.js",
                data: Data("module.exports = '\(nome)';".utf8),
                isDir: false,
                mode: 0o644,
                link: nil
            ),
        ]))!
    }

    @Test func tarballPorURLEGithub() async throws {
        let reg = FakeRegistry()
        reg.add("b", "1.2.0", files: ["index.js": "b"])
        reg.tarballs["https://exemplo.com/x-1.0.0.tgz"] = tgz("x", "1.0.0", deps: ["b": "^1.0.0"])
        reg.tarballs["https://codeload.github.com/dono/repo/tar.gz/v2"] = tgz("gh", "2.0.0", raiz: "repo-abc123")
        reg.tarballs["https://codeload.github.com/dono/outro/tar.gz/HEAD"] = tgz("outro", "0.1.0", raiz: "outro-HEAD")
        let dir = try project([
            "x": "https://exemplo.com/x-1.0.0.tgz", "gh": "github:dono/repo#v2", "outro": "dono/outro",
        ])
        let rep = try await Installer(project: dir, registry: reg).install()
        #expect(rep.failed.isEmpty, "\(rep.failed)")
        #expect(rep.skipped.isEmpty, "\(rep.skipped)")
        #expect(try texto(dir.appending(path: "node_modules/x/index.js")) == "module.exports = 'x';")
        #expect(existe(dir.appending(path: "node_modules/b/index.js")))
        #expect(try texto(dir.appending(path: "node_modules/gh/index.js")) == "module.exports = 'gh';")
        #expect(existe(dir.appending(path: "node_modules/outro/index.js")))
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        #expect(lock.packages["node_modules/x"]?.resolved == "https://exemplo.com/x-1.0.0.tgz")
        #expect(lock.packages["node_modules/x"]?.integrity?.hasPrefix("sha512-") == true)
        #expect(lock.packages["node_modules/gh"]?.resolved == "git+ssh://git@github.com/dono/repo.git#v2")
    }

    /// `file:` de pasta vira atalho relativo, como no npm; `.tgz` local é extraído.
    @Test func fileDePastaEDeTgz() async throws {
        let reg = FakeRegistry()
        reg.add("b", "1.2.0", files: ["index.js": "b"])
        let dir = try project(["lib": "file:./libs/lib", "pac": "file:pac-1.0.0.tgz"])
        try escrever(
            #"{"name":"lib","version":"1.0.0","dependencies":{"b":"^1.0.0"}}"#,
            dir.appending(path: "libs/lib/package.json")
        )
        try escrever("module.exports = 'lib';", dir.appending(path: "libs/lib/index.js"))
        try tgz("pac", "1.0.0").write(to: dir.appending(path: "pac-1.0.0.tgz"))
        let rep = try await Installer(project: dir, registry: reg).install()
        #expect(rep.failed.isEmpty, "\(rep.failed)")
        let link = dir.appending(path: "node_modules/lib")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../libs/lib")
        #expect(try texto(link.appending(path: "index.js")) == "module.exports = 'lib';")
        #expect(existe(dir.appending(path: "node_modules/b/index.js")))
        #expect(try texto(dir.appending(path: "node_modules/pac/index.js")) == "module.exports = 'pac';")
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        #expect(lock.packages["node_modules/lib"]?.link == true)
        #expect(lock.packages["node_modules/lib"]?.resolved == "libs/lib")
        #expect(lock.packages["libs/lib"]?.version == "1.0.0")
        // O install seguinte não apaga a pasta do projeto pelo atalho.
        _ = try await Installer(project: dir, registry: reg).install()
        #expect(existe(dir.appending(path: "libs/lib/index.js")))
    }

    @Test func workspacesEProtocoloWorkspace() async throws {
        let reg = FakeRegistry()
        reg.add("b", "1.2.0", files: ["index.js": "b"])
        let dir = try project([:])
        try escrever(
            #"{"name":"mono","private":true,"workspaces":["packages/*"],"dependencies":{"@mono/ui":"workspace:*"}}"#,
            dir.appending(path: "package.json")
        )
        try escrever(
            #"{"name":"@mono/ui","version":"1.0.0","dependencies":{"b":"^1.0.0"}}"#,
            dir.appending(path: "packages/ui/package.json")
        )
        try escrever(
            #"{"name":"web","version":"0.1.0","dependencies":{"@mono/ui":"^1.0.0"}}"#,
            dir.appending(path: "packages/web/package.json")
        )
        let rep = try await Installer(project: dir, registry: reg).install()
        #expect(rep.failed.isEmpty, "\(rep.failed)")
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: dir.appending(path: "node_modules/@mono/ui").path
        ) == "../../packages/ui")
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: dir.appending(path: "node_modules/web").path
        ) == "../packages/web")
        #expect(existe(dir.appending(path: "node_modules/b/index.js")))
        // O `@mono/ui` do web é o workspace, não um download do registro.
        #expect(!existe(dir.appending(path: "packages/web/node_modules/@mono/ui")))
        #expect(reg.downloads.withLock { $0 } == ["fake://b/1.2.0.tgz"])
    }

    /// Dependência que não dá para instalar é falha, não "ignorado" com saída 0.
    @Test func gitForaDoGithubFalha() async throws {
        let dir = try project(["x": "git+https://gitlab.com/a/b.git"])
        let rep = try await Installer(project: dir, registry: FakeRegistry()).install()
        #expect(rep.failed["x"] != nil)
        #expect(rep.skipped.isEmpty)
    }

    // MARK: - overrides

    @Test func overridesGlobalEAninhado() async throws {
        let reg = FakeRegistry()
        reg.add("b", "1.0.0", files: ["index.js": "b1"], latest: false)
        reg.add("b", "1.2.0", files: ["index.js": "b12"])
        reg.add("b", "2.0.0", files: ["index.js": "b2"], latest: false)
        reg.add("a", "1.0.0", deps: ["b": "^1.0.0"])
        reg.add("c", "3.1.0", deps: ["b": "^2"])
        let dir = try project([:])
        try escrever(
            #"{"name":"p","dependencies":{"a":"^1.0.0","c":"^3.0.0"},"overrides":{"b":"1.0.0","c":{"b":"1.2.0"}}}"#,
            dir.appending(path: "package.json")
        )
        let rep = try await Installer(project: dir, registry: reg).install()
        #expect(rep.failed.isEmpty, "\(rep.failed)")
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        #expect(lock.packages["node_modules/b"]?.version == "1.0.0")
        #expect(lock.packages["node_modules/c/node_modules/b"]?.version == "1.2.0")
    }

    // MARK: - package.json e lock no formato do npm

    /// Quatro espaços, CRLF, ordem dos campos e `/` sem escape ficam; as listas de
    /// dependências saem ordenadas; `npm i b@1` grava `^1.2.0` (não `1`), e `-E` grava exato.
    @Test func packageJSONComoONpmGrava() async throws {
        let reg = InstallerTests().registry()
        let dir = try project([:])
        let original = "{\r\n    \"name\": \"p\",\r\n    \"scripts\": {\"dev\": \"vite --host 0.0.0.0/0\"},\r\n"
            + "    \"dependencies\": {\"c\": \"^3.0.0\"},\r\n    \"zzz\": {\"url\": \"https://x.y/z\", \"n\": 1.50}\r\n}"
        try escrever(original, dir.appending(path: "package.json"))
        _ = try await Installer(project: dir, registry: reg).install(add: [Installer.Spec("b@1")])
        let gravado = try texto(dir.appending(path: "package.json"))
        #expect(
            gravado == "{\r\n    \"name\": \"p\",\r\n    \"scripts\": {\r\n        \"dev\": \"vite --host 0.0.0.0/0\"\r\n    },\r\n"
                + "    \"dependencies\": {\r\n        \"b\": \"^1.2.0\",\r\n        \"c\": \"^3.0.0\"\r\n    },\r\n"
                + "    \"zzz\": {\r\n        \"url\": \"https://x.y/z\",\r\n        \"n\": 1.5\r\n    }\r\n}\r\n"
        )
        _ = try await Installer(project: dir, registry: reg).install(add: [Installer.Spec("a")], exato: true)
        #expect(PackageJSON(url: dir.appending(path: "package.json")).dependencies["a"] == "1.0.0")
    }

    @Test(arguments: [
        ("16", "16.6.1", "^16.6.1"), ("latest", "16.6.1", "^16.6.1"), (">=16 <17", "16.6.1", "^16.6.1"),
        ("16.6.1", "16.6.1", "^16.6.1"), ("1.x <1.2.3", "1.2.2", "1.x <1.2.3"), ("~1.2.0", "1.2.9", "~1.2.0"),
        ("*", "3.0.0", "^3.0.0"),
    ])
    func faixaGravada(pedido: String, versao: String, esperado: String) throws {
        #expect(try Installer.faixaParaSalvar(pedido: pedido, versao: #require(Version(versao)), exato: false)
            == esperado)
    }

    /// O lock sai como o do npm: `": "`, URL sem `\/`, ordem do `json-stringify-nice`, e os
    /// campos que a Odete não usa (`license`, `engines`) continuam lá depois de um install.
    @Test func lockNoFormatoDoNpm() async throws {
        let reg = InstallerTests().registry()
        let dir = try project(["a": "^1.0.0"])
        let inst = Installer(project: dir, registry: reg)
        _ = try await inst.install()
        let lockURL = dir.appending(path: "package-lock.json")
        var t = try texto(lockURL)
        #expect(!t.contains(" : ") && !t.contains("\\/"))
        #expect(t
            .hasPrefix(
                "{\n  \"name\": \"proj\",\n  \"lockfileVersion\": 3,\n  \"requires\": true,\n  \"packages\": {\n    \"\": {"
            ))
        // Um campo que o npm escreveu e a Odete não conhece sobrevive ao próximo install.
        t = t.replacingOccurrences(
            of: "\"resolved\": \"fake://a/1.0.0.tgz\",",
            with: "\"resolved\": \"fake://a/1.0.0.tgz\",\n      \"license\": \"MIT\","
        )
        try escrever(t, lockURL)
        _ = try await inst.install()
        let depois = try texto(lockURL)
        #expect(depois.contains("\"license\": \"MIT\""))
        let a = try #require(depois.range(of: "\"node_modules/a\": {"))
        let trecho = depois[a.upperBound...].prefix(260)
        // version, resolved, (integrity), licença, e só depois os objetos.
        let ordem = ["\"version\"", "\"resolved\"", "\"license\"", "\"dependencies\""]
            .compactMap { trecho.range(of: $0)?.lowerBound }
        #expect(ordem.count == 4 && ordem == ordem.sorted(), "\(trecho)")
        // E o lock escondido do npm, em node_modules.
        #expect(existe(dir.appending(path: "node_modules/.package-lock.json")))
    }

    // MARK: - scripts x nativo

    /// `core-js` tem `postinstall` e nada de nativo: vai para `scripts`, não para o aviso
    /// de "código nativo que não roda no iPad". `binding.gyp` continua sendo nativo.
    @Test func scriptDeInstalacaoNaoEhNativo() async throws {
        let reg = FakeRegistry()
        reg.add("core-js", "3.40.0", files: ["index.js": "1"], install: true)
        reg.add("sqlite", "5.0.0", files: ["binding.gyp": "{}"], install: true)
        reg.add("addon", "1.0.0", deps: ["node-gyp-build": "^4"])
        reg.add("node-gyp-build", "4.8.0")
        let dir = try project(["core-js": "^3.0.0", "sqlite": "^5.0.0", "addon": "^1.0.0"])
        let rep = try await Installer(project: dir, registry: reg).install()
        #expect(rep.scripts == ["core-js@3.40.0"])
        #expect(rep.native.sorted() == ["addon@1.0.0", "sqlite@5.0.0"])
    }
}

/// A árvore como o npm monta: quem fica no topo, peers, marcas e o tar.
extension CompatibilidadeTests {
    // MARK: - hoisting

    /// Um nível do meio com outra versão: o pacote não pode ir para o topo, senão quem
    /// está embaixo enxerga a do meio.
    @Test func hoistingConfereOsNiveisDoMeio() async throws {
        let reg = FakeRegistry()
        reg.add("x", "2.0.0", files: ["index.js": "x2"], latest: false)
        reg.add("x", "3.0.0", files: ["index.js": "x3"])
        // O topo tem x@3 e k@2. `a` pede x@2 e k@1, que ficam em a/node_modules. O k@1
        // pede x@3 — a mesma versão do topo, mas o topo está escondido pelo x@2 de
        // a/node_modules. Conferindo só o topo, o k@1 ficava enxergando o x@2.
        reg.add("a", "1.0.0", deps: ["x": "^2.0.0", "k": "^1.0.0"])
        reg.add("k", "1.0.0", deps: ["x": "^3.0.0"], latest: false)
        reg.add("k", "2.0.0")
        let dir = try project(["a": "^1.0.0", "k": "^2.0.0", "x": "^3.0.0"])
        let rep = try await Installer(project: dir, registry: reg).install()
        #expect(rep.failed.isEmpty, "\(rep.failed)")
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        #expect(lock.packages["node_modules/a/node_modules/x"]?.version == "2.0.0")
        #expect(lock.packages["node_modules/a/node_modules/k"]?.version == "1.0.0")
        #expect(lock.resolve("x", from: "node_modules/a/node_modules/k")?.entry.version == "3.0.0")
        for (k, e) in lock.packages {
            for (dep, faixa) in e.dependencies {
                let achado = try #require(lock.resolve(dep, from: k), "\(k) não acha \(dep)")
                #expect(try SemverRange(faixa).satisfies(#require(Version(achado.entry.version))), "\(k) → \(dep)")
            }
        }
    }

    /// A ordem do npm: os nós mais rasos primeiro e, na mesma profundidade, pelo caminho —
    /// não pela ordem de chegada. `beta` (posto no topo por `alfa`) é processado antes de
    /// `zeta`, e o `semver` do topo é o 6 que ele pede.
    @Test func ordemDoNpmDecideQuemFicaNoTopo() async throws {
        let reg = FakeRegistry()
        reg.add("semver", "6.3.1", latest: false)
        reg.add("semver", "7.7.0")
        reg.add("alfa", "1.0.0", deps: ["beta": "^1.0.0"])
        reg.add("beta", "1.0.0", deps: ["semver": "^6.0.0"])
        reg.add("zeta", "1.0.0", deps: ["semver": "^7.0.0"])
        let dir = try project(["zeta": "^1.0.0", "alfa": "^1.0.0"])
        _ = try await Installer(project: dir, registry: reg).install()
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        #expect(lock.packages["node_modules/semver"]?.version == "6.3.1")
        #expect(lock.packages["node_modules/zeta/node_modules/semver"]?.version == "7.7.0")
    }

    /// Peer (mesmo opcional) que não bate no nível de cima prende o pacote embaixo: o
    /// `fdir` fica dentro do `tinyglobby`, ao lado do `picomatch@4`.
    @Test func peerPrendeOPacoteOndeEleServe() async throws {
        let reg = FakeRegistry()
        reg.add("picomatch", "2.3.1", latest: false)
        reg.add("picomatch", "4.0.2")
        reg.add("micromatch", "4.0.8", deps: ["picomatch": "^2.3.1"])
        reg.add("fdir", "6.5.0", peer: ["picomatch": "^3 || ^4"], peersOpcionais: ["picomatch"])
        reg.add("tinyglobby", "0.2.14", deps: ["fdir": "^6.4.0", "picomatch": "^4.0.2"])
        let dir = try project(["micromatch": "^4.0.0", "tinyglobby": "^0.2.0"])
        _ = try await Installer(project: dir, registry: reg).install()
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        #expect(lock.packages["node_modules/fdir"] == nil)
        #expect(lock.packages["node_modules/tinyglobby/node_modules/fdir"]?.version == "6.5.0")
        #expect(lock.packages["node_modules/tinyglobby/node_modules/picomatch"]?.version == "4.0.2")
    }

    /// O que um binário de plataforma puxa entra no lock (como no npm) e não no disco;
    /// dependência embutida no tarball (`bundleDependencies`) não se resolve à parte.
    @Test func filhosDePlataformaEEmbutidas() async throws {
        let reg = FakeRegistry()
        reg.add("ferramenta", "1.0.0", optional: ["@ferr/wasm32": "1.0.0"], files: ["index.js": "1"])
        reg.add("@ferr/wasm32", "1.0.0", deps: ["runtime-wasm": "^1.0.0", "embutido": "^1.0.0"], cpu: ["wasm32"])
        reg.add("runtime-wasm", "1.2.0", files: ["index.js": "1"])
        reg.add("embutido", "1.0.0")
        reg.packuments["@ferr/wasm32"]?.versions[Version(1, 0, 0)]?.extras = .objeto([
            ("bundleDependencies", .lista([.texto("embutido")])),
        ])
        let dir = try project(["ferramenta": "^1.0.0"])
        let rep = try await Installer(project: dir, registry: reg).install()
        #expect(rep.failed.isEmpty, "\(rep.failed)")
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        #expect(lock.packages["node_modules/runtime-wasm"]?.optional == true)
        #expect(lock.packages["node_modules/embutido"] == nil)
        #expect(!existe(dir.appending(path: "node_modules/runtime-wasm")))
        #expect(!reg.downloads.withLock { $0 }.contains { $0.contains("runtime-wasm") })
        #expect(!Installer(project: dir, registry: reg).list().contains { $0.name == "runtime-wasm" })
    }

    /// `license`, `funding` e `engines` do package.json instalado entram no lock, com o
    /// `funding` em texto virando `{ "url": … }` e o `bin` sem `./` — como o npm grava.
    @Test func lockLevaOsCamposDoPacoteInstalado() async throws {
        let reg = FakeRegistry()
        reg.add("x", "1.0.0", bin: ["x": "./bin/x.js"], files: ["bin/x.js": "1"])
        let url = "fake://x/1.0.0.tgz"
        let pj = #"{"name":"x","version":"1.0.0","license":"MIT","funding":"https://f.example","engines":{"node":">=18"},"bin":{"x":"./bin/x.js"}}"#
        reg.tarballs[url] = try #require(GzipCodec.compress(Tar.write([
            Tar.Entry(path: "package/package.json", data: Data(pj.utf8), isDir: false, mode: 0o644, link: nil),
            Tar.Entry(path: "package/bin/x.js", data: Data("1".utf8), isDir: false, mode: 0o755, link: nil),
        ])))
        let dir = try project(["x": "^1.0.0"])
        _ = try await Installer(project: dir, registry: reg).install()
        let t = try texto(dir.appending(path: "package-lock.json"))
        #expect(t.contains("\"license\": \"MIT\""), "\(t)")
        #expect(t.contains("\"funding\": {\n        \"url\": \"https://f.example\"\n      }"), "\(t)")
        #expect(t.contains("\"x\": \"bin/x.js\""), "\(t)")
        #expect(t.contains("\"node\": \">=18\""))
    }

    /// Alcançado por uma opcional do projeto e por uma ferramenta de dev: `devOptional`,
    /// como o `detect-libc` num projeto Next.
    @Test func devOptionalComoONpm() async throws {
        let reg = FakeRegistry()
        reg.add("libc", "2.1.2")
        reg.add("app", "1.0.0", optional: ["libc": "^2.0.0"])
        reg.add("css", "1.0.0", deps: ["libc": "^2.0.0"])
        let dir = try project([:])
        try escrever(
            #"{"name":"p","dependencies":{"app":"^1"},"devDependencies":{"css":"^1"}}"#,
            dir.appending(path: "package.json")
        )
        _ = try await Installer(project: dir, registry: reg).install()
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        let e = try #require(lock.packages["node_modules/libc"])
        #expect(e.devOptional && !e.dev && !e.optional)
        #expect(try texto(dir.appending(path: "package-lock.json")).contains("\"devOptional\": true"))
    }

    /// O primeiro a pedir `b` é um dev, o segundo é do projeto: `b` não é `dev`.
    @Test func marcaDevPeloCaminho() async throws {
        let reg = FakeRegistry()
        reg.add("b", "1.0.0")
        reg.add("ferramenta", "1.0.0", deps: ["b": "^1.0.0"])
        reg.add("app", "1.0.0", deps: ["b": "^1.0.0"])
        let dir = try project([:])
        try escrever(
            #"{"name":"p","dependencies":{"app":"^1"},"devDependencies":{"b":"^1","ferramenta":"^1"}}"#,
            dir.appending(path: "package.json")
        )
        _ = try await Installer(project: dir, registry: reg).install()
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        #expect(lock.packages["node_modules/b"]?.dev == false)
        #expect(lock.packages["node_modules/ferramenta"]?.dev == true)
    }

    // MARK: - tar

    /// Link que sai da pasta do pacote não é criado, e arquivo que viria através dele
    /// não é escrito lá fora.
    @Test func tarNaoEscreveForaDoPacote() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "odete-tar-\(UUID().uuidString)")
        let dir = base.appending(path: "node_modules/mau")
        let fora = base.appending(path: "fora")
        try FileManager.default.createDirectory(at: fora, withIntermediateDirectories: true)
        let tar = Tar.write([
            Tar.Entry(path: "package/package.json", data: Data("{}".utf8), isDir: false, mode: 0o644, link: nil),
            Tar.Entry(path: "package/fuga", data: Data(), isDir: false, mode: 0o777, link: "../../fora"),
            Tar.Entry(path: "package/absoluto", data: Data(), isDir: false, mode: 0o777, link: "/etc"),
            Tar.Entry(path: "package/fuga/x.js", data: Data("pego".utf8), isDir: false, mode: 0o644, link: nil),
            // Corrente: cada um fica dentro sozinho, os dois juntos saem.
            Tar.Entry(path: "package/d/um", data: Data(), isDir: false, mode: 0o777, link: ".."),
            Tar.Entry(path: "package/dois", data: Data(), isDir: false, mode: 0o777, link: "d/um/.."),
            Tar.Entry(path: "package/lib/bom.js", data: Data("ok".utf8), isDir: false, mode: 0o644, link: nil),
            Tar.Entry(path: "package/atalho.js", data: Data(), isDir: false, mode: 0o777, link: "lib/bom.js"),
        ])
        try Tar.extractPackage(#require(GzipCodec.compress(tar)), to: dir)
        #expect(!existe(fora.appending(path: "x.js")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fora.path).isEmpty)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: dir.appending(path: "fuga").path)) == nil)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: dir.appending(path: "absoluto").path)) ==
            nil)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: dir.appending(path: "dois").path)) == nil)
        #expect(try texto(dir.appending(path: "atalho.js")) == "ok")
    }
}
