import Foundation
import OdeteBundler
import OdeteCore
import OdeteI18n
@testable import OdeteNpm
@testable import OdeteShell
import Synchronization
import Testing

/// Registro montado na hora, sem rede: pacotes com `index.js`, bin e dependências.
final class RegistroDeTeste: RegistryClient, @unchecked Sendable {
    struct Pacote {
        var versao: String
        var arquivos: [String: String]
        var deps: [String: String] = [:]
        var bin: [String: String] = [:]
    }

    var pacotes: [String: Pacote] = [:]
    /// Sem rede: toda chamada falha como o URLSession falha sem internet.
    var offline = false
    let downloads = Mutex(0)

    func packument(_ name: String) async throws -> Packument {
        if offline {
            throw URLError(.notConnectedToInternet)
        }
        guard let p = pacotes[name], let v = Version(p.versao) else { throw NpmError.notFound(name) }
        let pv = PackumentVersion(
            version: v, dependencies: p.deps, optionalDependencies: [:], peerDependencies: [:], bin: p.bin,
            tarball: "fake://\(name)/\(p.versao).tgz", integrity: nil, os: [], cpu: [], hasInstallScript: false,
            deprecated: nil
        )
        return Packument(name: name, distTags: ["latest": p.versao], versions: [v: pv])
    }

    func tarball(_ url: String, integrity: String?) async throws -> Data {
        if offline {
            throw URLError(.notConnectedToInternet)
        }
        downloads.withLock { $0 += 1 }
        let nome = String(url.dropFirst("fake://".count).split(separator: "/").dropLast().joined(separator: "/"))
        guard let p = pacotes[nome] else { throw NpmError.tarball("404") }
        var pj: [String: Any] = ["name": nome, "version": p.versao, "main": "index.js", "dependencies": p.deps]
        if !p.bin.isEmpty {
            pj["bin"] = p.bin
        }
        var entradas = try [Tar.Entry(
            path: "package/package.json", data: JSONSerialization.data(withJSONObject: pj), isDir: false,
            mode: 0o644, link: nil
        )]
        for (caminho, texto) in p.arquivos.sorted(by: { $0.key < $1.key }) {
            entradas.append(Tar.Entry(
                path: "package/" + caminho,
                data: Data(texto.utf8),
                isDir: false,
                mode: 0o755,
                link: nil
            ))
        }
        guard let tgz = GzipCodec.compress(Tar.write(entradas)) else { throw NpmError.tarball("gzip") }
        return tgz
    }
}

/// `npm run dev` num projeto sem node_modules, scripts `pre`/`post`, `npm ci`, `yarn`,
/// `npx -y` e o package.json mais próximo.
@Suite(.serialized) struct NpmRunDevTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func registro() -> RegistroDeTeste {
        let r = RegistroDeTeste()
        r.pacotes["saudacao"] = .init(versao: "1.0.0", arquivos: ["index.js": "module.exports = 'olá do pacote';"])
        r.pacotes["ferramenta"] = .init(
            versao: "2.0.0",
            arquivos: ["cli.js": "console.log('ferramenta rodou', process.argv.slice(2).join(' '));"],
            bin: ["ferramenta": "cli.js"]
        )
        return r
    }

    func escrever(_ s: String, _ u: URL) throws {
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: u, atomically: true, encoding: .utf8)
    }

    /// O projeto como o modelo Vite do Hub cria: package.json, index.html e o main, sem
    /// node_modules.
    func projetoVite() throws -> URL {
        let raiz = try project()
        try escrever(
            #"{"name":"app","private":true,"type":"module","scripts":{"dev":"vite"},"dependencies":{"saudacao":"^1.0.0"}}"#,
            raiz.appending(path: "package.json")
        )
        try escrever(
            #"<!doctype html><html><head></head><body><script type="module" src="/src/main.js"></script></body></html>"#,
            raiz.appending(path: "index.html")
        )
        try escrever(
            "import s from \"saudacao\";\ndocument.body.textContent = s;\n",
            raiz.appending(path: "src/main.js")
        )
        return raiz
    }

    func texto(_ u: URL) async throws -> String {
        let (d, _) = try await URLSession.shared.data(from: u)
        return String(decoding: d, as: UTF8.self)
    }

    /// Antes: o servidor subia, mandava `saudacao` para o esm.sh, e com React eram duas
    /// cópias e o Preview preto. Agora o `npm install` roda antes, com a saída no terminal.
    @Test func npmRunDevSemNodeModulesInstalaAntes() async throws {
        let raiz = try projetoVite()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let portas = Mutex<[Int]>([])
        let sh = Shell(root: raiz, services: ShellServices(
            registry: registro(),
            onServer: { p, _ in portas.withLock { $0.append(p) } }
        ))
        defer { sh.killAll() }
        let o = Out()
        #expect(
            await sh.run("npm run dev -- --port \(20000 + Int.random(in: 0 ..< 20000))", sink: o.sink) == 0,
            Comment(rawValue: o.err)
        )
        #expect(o.out.contains("rodando npm install"), Comment(rawValue: o.out))
        #expect(o.out.contains("1 pacote(s) instalado(s)"), Comment(rawValue: o.out))
        #expect(FileManager.default.fileExists(atPath: raiz.appending(path: "node_modules/saudacao/index.js").path))
        let porta = try #require(portas.withLock { $0.first })
        let html = try await texto(#require(URL(string: "http://127.0.0.1:\(porta)/")))
        #expect(!html.contains("esm.sh"), "\(html)")
        let enderecoDasDeps = try #require(URL(string: "http://127.0.0.1:\(porta)/@odete/deps.js?de=src%2Fmain.js"))
        let deps = try await texto(enderecoDasDeps)
        // O esbuild escapa o acento (`ol\\xE1`): confere o resto.
        #expect(deps.contains(" do pacote"), "\(deps.prefix(400))")
    }

    /// Sem rede e sem node_modules: não sobe servidor e diz por quê.
    @Test func npmRunDevSemRedeDaErroClaro() async throws {
        let raiz = try projetoVite()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let reg = registro()
        reg.offline = true
        let portas = Mutex<[Int]>([])
        let sh = Shell(root: raiz, services: ShellServices(
            registry: reg,
            onServer: { p, _ in portas.withLock { $0.append(p) } }
        ))
        defer { sh.killAll() }
        let o = Out()
        #expect(await sh.run("npm run dev", sink: o.sink) == 1)
        #expect(o.err.contains("sem conexão"), Comment(rawValue: o.err))
        #expect(portas.withLock { $0 }.isEmpty, "o servidor subiu sem as dependências")
        #expect(sh.jobs.isEmpty)
    }

    /// `npm install` num projeto com index.html prepara o pacote de dependências do dev
    /// server em segundo plano.
    @Test func npmInstallAqueceODevServer() async throws {
        let raiz = try projetoVite()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let sh = Shell(root: raiz, services: ShellServices(registry: registro()))
        let o = Out()
        #expect(await sh.run("npm install", sink: o.sink) == 0, Comment(rawValue: o.err))
        #expect(o.out.contains("segundo plano"))
        let r = try #require(await Aquecimento.esperar(raiz: raiz))
        #expect(r.feito, "\(r)")
        let pasta = raiz.appending(path: "node_modules/.odete-deps")
        #expect(try FileManager.default.contentsOfDirectory(atPath: pasta.path).contains { $0.hasSuffix(".js") })
    }

    @Test func scriptsPreEPost() async throws {
        let raiz = try project()
        defer { try? FileManager.default.removeItem(at: raiz) }
        try escrever(
            #"{"name":"p","scripts":{"prebuild":"echo antes","build":"echo durante","postbuild":"echo depois","prefalha":"false","falha":"echo nunca"}}"#,
            raiz.appending(path: "package.json")
        )
        let sh = Shell(root: raiz)
        let o = Out()
        #expect(await sh.run("npm run build -- x", sink: o.sink) == 0)
        #expect(o.out.contains("antes\n> echo durante x\ndurante x\n> echo depois\ndepois"), Comment(rawValue: o.out))
        let o2 = Out()
        #expect(await sh.run("npm run falha", sink: o2.sink) != 0)
        #expect(!o2.out.contains("nunca"))
    }

    /// `yarn` e `pnpm` sozinhos instalam; `yarn dev` roda o script.
    @Test func yarnSemArgumentosInstala() async throws {
        let raiz = try project()
        defer { try? FileManager.default.removeItem(at: raiz) }
        try escrever(
            #"{"name":"p","scripts":{"oi":"echo oi do yarn"},"dependencies":{"saudacao":"^1.0.0"}}"#,
            raiz.appending(path: "package.json")
        )
        let sh = Shell(root: raiz, services: ShellServices(registry: registro()))
        let o = Out()
        #expect(await sh.run("yarn", sink: o.sink) == 0, Comment(rawValue: o.err))
        #expect(FileManager.default.fileExists(atPath: raiz.appending(path: "node_modules/saudacao/index.js").path))
        #expect(await sh.run("yarn oi", sink: o.sink) == 0)
        #expect(o.out.contains("oi do yarn"))
        let o2 = Out()
        #expect(await sh.run("npm", sink: o2.sink) == 0)
        #expect(o2.out.contains("npm <install"))
    }

    /// `npm ci` instala o que o lock diz e recusa lock que não bate com o package.json.
    @Test func npmCi() async throws {
        let raiz = try project()
        defer { try? FileManager.default.removeItem(at: raiz) }
        try escrever(#"{"name":"p","dependencies":{"saudacao":"^1.0.0"}}"#, raiz.appending(path: "package.json"))
        let reg = registro()
        let sh = Shell(root: raiz, services: ShellServices(registry: reg))
        let o = Out()
        #expect(await sh.run("npm ci", sink: o.sink) == 1)
        #expect(o.err.contains("package-lock.json"))
        #expect(await sh.run("npm install", sink: o.sink) == 0)
        try escrever("sobra", raiz.appending(path: "node_modules/lixo/x.txt"))
        let o2 = Out()
        #expect(await sh.run("npm ci", sink: o2.sink) == 0, Comment(rawValue: o2.err))
        #expect(!FileManager.default.fileExists(atPath: raiz.appending(path: "node_modules/lixo").path))
        #expect(FileManager.default.fileExists(atPath: raiz.appending(path: "node_modules/saudacao/index.js").path))
        try escrever(
            #"{"name":"p","dependencies":{"saudacao":"^1.0.0","ferramenta":"^2"}}"#,
            raiz.appending(path: "package.json")
        )
        let o3 = Out()
        #expect(await sh.run("npm ci", sink: o3.sink) == 1)
        #expect(o3.err.contains("ferramenta@^2"), Comment(rawValue: o3.err))
    }

    /// `npx -y ferramenta`: o `-y` não é o binário; e o que não está no projeto é baixado
    /// para o cache do npx, não para o projeto.
    @Test func npxComOpcoesEDownload() async throws {
        let raiz = try project()
        defer { try? FileManager.default.removeItem(at: raiz) }
        try escrever(#"{"name":"p"}"#, raiz.appending(path: "package.json"))
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "odete-npx/ferramenta")
        try? FileManager.default.removeItem(at: cache)
        let sh = Shell(root: raiz, services: ShellServices(registry: registro()))
        let o = Out()
        #expect(await sh.run("npx -y ferramenta um dois", sink: o.sink) == 0, Comment(rawValue: o.err))
        #expect(o.out.contains("ferramenta rodou um dois"), Comment(rawValue: o.out))
        #expect(!FileManager.default.fileExists(atPath: raiz.appending(path: "node_modules").path))
    }

    /// `cd packages/web && npm install` instala no web, e `npm run` roda o script dele.
    @Test func packageJSONMaisProximo() async throws {
        let raiz = try project()
        defer { try? FileManager.default.removeItem(at: raiz) }
        try escrever(#"{"name":"raiz","scripts":{"qual":"echo raiz"}}"#, raiz.appending(path: "package.json"))
        let web = raiz.appending(path: "packages/web")
        try escrever(
            #"{"name":"web","scripts":{"qual":"echo web"},"dependencies":{"saudacao":"^1"}}"#,
            web.appending(path: "package.json")
        )
        try FileManager.default.createDirectory(at: web.appending(path: "src"), withIntermediateDirectories: true)
        let sh = Shell(root: raiz, services: ShellServices(registry: registro()))
        let o = Out()
        #expect(
            await sh.run("cd packages/web/src && npm run qual && npm install", sink: o.sink) == 0,
            Comment(rawValue: o.err)
        )
        #expect(o.out.contains("web") && !o.out.contains("\nraiz"), Comment(rawValue: o.out))
        #expect(FileManager.default.fileExists(atPath: web.appending(path: "node_modules/saudacao/index.js").path))
        #expect(!FileManager.default.fileExists(atPath: raiz.appending(path: "node_modules").path))
    }
}
