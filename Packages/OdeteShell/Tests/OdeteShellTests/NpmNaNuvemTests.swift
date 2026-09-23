import Foundation
import OdeteCore
import OdeteI18n
@testable import OdeteNpm
@testable import OdeteShell
import Testing

/// Registro com um pacote só, montado na hora: o teste não vai à rede.
struct RegistroDeUmPacote: RegistryClient {
    static let url = "fake://um/1.0.0.tgz"

    func packument(_ name: String) async throws -> Packument {
        guard name == "um", let v = Version("1.0.0") else { throw NpmError.notFound(name) }
        let pv = PackumentVersion(
            version: v, dependencies: [:], optionalDependencies: [:], peerDependencies: [:], bin: [:],
            tarball: Self.url, integrity: nil, os: [], cpu: [], hasInstallScript: false, deprecated: nil
        )
        return Packument(name: "um", distTags: ["latest": "1.0.0"], versions: [v: pv])
    }

    func tarball(_ url: String, integrity: String?) async throws -> Data {
        let tar = Tar.write([
            Tar.Entry(
                path: "package/package.json",
                data: Data(#"{"name":"um","version":"1.0.0","main":"index.js"}"#.utf8),
                isDir: false, mode: 0o644, link: nil
            ),
            Tar.Entry(
                path: "package/index.js",
                data: Data("module.exports = 'um pelo link';".utf8),
                isDir: false, mode: 0o644, link: nil
            ),
        ])
        guard let tgz = GzipCodec.compress(tar) else { throw NpmError.tarball("gzip") }
        return tgz
    }
}

/// `npm install` num projeto do iCloud pelo terminal, e o `rm -rf node_modules` de
/// quem quer começar de novo.
struct NpmNaNuvemTests {
    /// O teste confere o resumo do install na frase em português; no simulador em inglês
    /// ele chegaria traduzido.
    init() {
        Texto.escolher(.ptBR)
    }

    func projetoNaNuvem() throws -> URL {
        let u = FileManager.default.temporaryDirectory
            .appending(path: "odete-sh-\(UUID().uuidString)/Mobile Documents/iCloud~odete/Documents/Projects/app")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try #"{"name":"app","dependencies":{"um":"^1.0.0"}}"#
            .write(to: u.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try "console.log(require('um'));"
            .write(to: u.appending(path: "index.js"), atomically: true, encoding: .utf8)
        return u
    }

    func tipo(_ u: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[.type] as? FileAttributeType
    }

    @Test func installRmEInstallDeNovoRefazemOArranjo() async throws {
        let root = try projetoNaNuvem()
        defer { try? FileManager.default.removeItem(at: root) }
        let sh = Shell(root: root, services: ShellServices(registry: RegistroDeUmPacote()))
        let o = Out()
        #expect(await sh.run("npm install", sink: o.sink) == 0, Comment(rawValue: o.err))
        #expect(o.out.contains(".gitignore: node_modules, node_modules.nosync/"))
        #expect(tipo(root.appending(path: "node_modules")) == .typeSymbolicLink)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "node_modules.nosync/um/index.js").path))
        let o2 = Out()
        #expect(await sh.run("node index.js", sink: o2.sink) == 0, Comment(rawValue: o2.err))
        #expect(o2.out.contains("um pelo link"))

        // `rm -rf node_modules` leva o link; a pasta real fica órfã até o próximo install.
        #expect(await sh.run("rm -rf node_modules", sink: o.sink) == 0)
        #expect(tipo(root.appending(path: "node_modules")) == nil)
        let o3 = Out()
        #expect(await sh.run("npm install", sink: o3.sink) == 0, Comment(rawValue: o3.err))
        #expect(tipo(root.appending(path: "node_modules")) == .typeSymbolicLink)
        #expect(o3.out.contains("1 pacote(s) instalado(s)"))
        let o4 = Out()
        #expect(await sh.run("node index.js", sink: o4.sink) == 0, Comment(rawValue: o4.err))
        #expect(o4.out.contains("um pelo link"))

        // A pasta real apagada: o link fica sem destino, e o install refaz a pasta.
        #expect(await sh.run("rm -rf node_modules.nosync", sink: o.sink) == 0)
        let o5 = Out()
        #expect(await sh.run("npm install", sink: o5.sink) == 0, Comment(rawValue: o5.err))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "node_modules/um/index.js").path))

        // `npm uninstall` passa pelo mesmo caminho e tira o pacote da pasta real.
        let o6 = Out()
        #expect(await sh.run("npm uninstall um", sink: o6.sink) == 0, Comment(rawValue: o6.err))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "node_modules.nosync/um").path))
        #expect(tipo(root.appending(path: "node_modules")) == .typeSymbolicLink)
    }

    /// Fora do iCloud, a linha de sempre.
    @Test func projetoLocalGanhaOGitignoreDeSempre() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"name":"app","dependencies":{"um":"^1.0.0"}}"#
            .write(to: root.appending(path: "package.json"), atomically: true, encoding: .utf8)
        let sh = Shell(root: root, services: ShellServices(registry: RegistroDeUmPacote()))
        let o = Out()
        #expect(await sh.run("npm install", sink: o.sink) == 0, Comment(rawValue: o.err))
        #expect(o.out.contains(".gitignore: node_modules/ adicionado"))
        #expect(tipo(root.appending(path: "node_modules")) == .typeDirectory)
        #expect(try String(contentsOf: root.appending(path: ".gitignore"), encoding: .utf8)
            == "node_modules/\ndist/\n.DS_Store\n")
    }
}
