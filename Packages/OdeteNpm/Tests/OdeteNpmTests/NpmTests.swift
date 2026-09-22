import CryptoKit
import Foundation
import OdeteCore
@testable import OdeteNpm
import Synchronization
import Testing

struct SemverTests {
    @Test func versionsCompare() throws {
        #expect(try #require(Version("1.2.3")) < Version("1.10.0")!)
        #expect(try #require(Version("1.0.0-alpha")) < Version("1.0.0")!)
        #expect(try #require(Version("1.0.0-alpha.1")) < Version("1.0.0-alpha.2")!)
        #expect(Version("v2.0.0")?.description == "2.0.0")
        #expect(Version("1.2") == nil)
    }

    @Test(arguments: [
        ("^1.2.3", "1.9.9", true), ("^1.2.3", "2.0.0", false), ("^0.2.3", "0.2.9", true), ("^0.2.3", "0.3.0", false), (
            "^0.0.3",
            "0.0.4",
            false
        ),
        ("~1.2.3", "1.2.9", true), ("~1.2.3", "1.3.0", false), ("~1", "1.9.0", true), ("1.x", "1.5.0", true), (
            "1.x",
            "2.0.0",
            false
        ),
        (">=1.0.0 <2.0.0", "1.5.0", true), (">=1.0.0 <2.0.0", "2.0.0", false), ("1.2.3 - 2.3.4", "2.0.0", true), (
            "1.2 - 2.3",
            "2.3.9",
            true
        ),
        ("*", "9.9.9", true), ("", "1.0.0", true), ("1 || 3", "3.2.1", true), ("1 || 3", "2.0.0", false), (
            "^1.0.0",
            "2.0.0-beta",
            false
        ), ("^1.0.0-beta", "1.0.0-beta.2", true), ("=1.2.3", "1.2.3", true),
    ])
    func satisfies(range: String, version: String, expected: Bool) throws {
        #expect(try SemverRange(range).satisfies(#require(Version(version))) == expected, "\(range) vs \(version)")
    }

    @Test func maxSatisfying() {
        let vs = ["1.0.0", "1.2.0", "1.9.3", "2.0.0", "2.1.0-rc.1"].compactMap(Version.init)
        #expect(SemverRange("^1.0.0").maxSatisfying(vs)?.description == "1.9.3")
        #expect(SemverRange("^2").maxSatisfying(vs)?.description == "2.0.0")
        #expect(SemverRange("^3").maxSatisfying(vs) == nil)
    }

    @Test func specParsing() {
        #expect(Installer.Spec("react").name == "react" && Installer.Spec("react").range == "latest")
        #expect(Installer.Spec("react@^19").range == "^19")
        #expect(Installer.Spec("@types/node@22").name == "@types/node" && Installer.Spec("@types/node@22")
            .range == "22")
    }
}

/// Registro fake em memória com contagem de acessos.
final class FakeRegistry: RegistryClient, @unchecked Sendable {
    var packuments: [String: Packument] = [:]
    var tarballs: [String: Data] = [:]
    let hits = Mutex<Int>(0)
    let downloads = Mutex<[String]>([])
    /// Atraso simulado de rede, por URL de tarball ou nome de packument. Sem isto o
    /// registro fake responde na hora e não dá para ver o custo de esperar o mais lento.
    var latencia: (@Sendable (String) -> Duration)?
    /// Quantas buscas de packument estão no ar ao mesmo tempo, e o máximo visto.
    let simultaneas = Mutex<(agora: Int, pico: Int)>((0, 0))

    func packument(_ name: String) async throws -> Packument {
        hits.withLock { $0 += 1 }
        simultaneas.withLock { $0.agora += 1; $0.pico = max($0.pico, $0.agora) }
        defer { simultaneas.withLock { $0.agora -= 1 } }
        if let latencia {
            try await Task.sleep(for: latencia(name))
        }
        guard let p = packuments[name] else { throw NpmError.notFound(name) }
        return p
    }

    /// Downloads no ar ao mesmo tempo, e o máximo visto.
    let tarballsNoAr = Mutex<(agora: Int, pico: Int)>((0, 0))

    func tarball(_ url: String, integrity: String?) async throws -> Data {
        downloads.withLock { $0.append(url) }
        tarballsNoAr.withLock { $0.agora += 1; $0.pico = max($0.pico, $0.agora) }
        defer { tarballsNoAr.withLock { $0.agora -= 1 } }
        if let latencia {
            try await Task.sleep(for: latencia(url))
        }
        guard let d = tarballs[url] else { throw NpmError.tarball("404 \(url)") }
        return d
    }

    func add(
        _ name: String,
        _ version: String,
        deps: [String: String] = [:],
        optional: [String: String] = [:],
        bin: [String: String] = [:],
        files: [String: String] = [:],
        os: [String] = [],
        cpu: [String] = [],
        install: Bool = false,
        latest: Bool = true
    ) {
        let url = "fake://\(name)/\(version).tgz"
        var pkgJSON: [String: Any] = ["name": name, "version": version, "dependencies": deps]
        if !bin.isEmpty {
            pkgJSON["bin"] = bin
        }
        var entries = [Tar.Entry(
            path: "package/package.json",
            data: try! JSONSerialization.data(withJSONObject: pkgJSON, options: [.sortedKeys]),
            isDir: false,
            mode: 0o644,
            link: nil
        )]
        for (p, c) in files.sorted(by: { $0.key < $1.key }) {
            entries.append(Tar.Entry(
                path: "package/" + p,
                data: Data(c.utf8),
                isDir: false,
                mode: p.hasSuffix(".js") ? 0o755 : 0o644,
                link: nil
            ))
        }
        tarballs[url] = GzipCodec.compress(Tar.write(entries))!
        let pv = PackumentVersion(
            version: Version(version)!,
            dependencies: deps,
            optionalDependencies: optional,
            peerDependencies: [:],
            bin: bin,
            tarball: url,
            integrity: nil,
            os: os,
            cpu: cpu,
            hasInstallScript: install,
            deprecated: nil
        )
        var p = packuments[name] ?? Packument(name: name, distTags: [:], versions: [:])
        p.versions[pv.version] = pv
        if latest {
            p.distTags["latest"] = version
        }
        packuments[name] = p
    }
}

func project(_ deps: [String: String]) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appending(
        path: "odete-npm-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["name": "proj", "dependencies": deps])
        .write(to: u.appending(path: "package.json"))
    return u
}

struct InstallerTests {
    func registry() -> FakeRegistry {
        let r = FakeRegistry()
        r.add("b", "1.0.0", latest: false); r.add("b", "1.2.0"); r.add(
            "b",
            "2.0.0",
            files: ["index.js": "module.exports = 'b2';"]
        )
        r.add("a", "1.0.0", deps: ["b": "^1.0.0"], files: ["index.js": "module.exports = require('b');"])
        r.add(
            "c",
            "3.1.0",
            deps: ["b": "^2"],
            bin: ["cee": "cli.js"],
            files: ["cli.js": "#!/usr/bin/env node\nconsole.log('cee');"]
        )
        r.add("nativo", "1.0.0", install: true)
        r.add("sowin", "1.0.0", os: ["win32"])
        return r
    }

    @Test func installHoistsNestsAndWritesLock() async throws {
        let reg = registry()
        let dir = try project(["a": "^1.0.0", "c": "^3.0.0"])
        let inst = Installer(project: dir, registry: reg)
        let rep = try await inst.install()
        #expect(rep.failed.isEmpty, "\(rep.failed)")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appending(path: "node_modules/a/index.js").path))
        #expect(fm.fileExists(atPath: dir.appending(path: "node_modules/b/package.json").path))
        #expect(fm.fileExists(atPath: dir.appending(path: "node_modules/c/node_modules/b/index.js").path))
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        #expect(lock.packages["node_modules/b"]?.version == "1.2.0")
        #expect(lock.packages["node_modules/c/node_modules/b"]?.version == "2.0.0")
        #expect(lock.resolve("b", from: "node_modules/c")?.entry.version == "2.0.0")
        #expect(lock.resolve("b", from: "node_modules/a")?.entry.version == "1.2.0")
        let bin = dir.appending(path: "node_modules/.bin/cee")
        #expect(try fm.destinationOfSymbolicLink(atPath: bin.path) == "../c/cli.js")
        #expect(inst.list().map(\.name) == ["a", "b", "c"])

        // segunda instalação usa o lock: sem novas consultas ao registro
        let before = reg.hits.withLock { $0 }
        _ = try await inst.install()
        #expect(reg.hits.withLock { $0 } == before)
    }

    @Test func addUninstallAndReports() async throws {
        let reg = registry()
        let dir = try project([:])
        let inst = Installer(project: dir, registry: reg)
        let rep = try await inst.install(add: [Installer.Spec("b"), Installer.Spec("nativo")], dev: false)
        #expect(rep.added.sorted() == ["b@2.0.0", "nativo@1.0.0"])
        #expect(rep.native == ["nativo@1.0.0"])
        let pkg = PackageJSON(url: dir.appending(path: "package.json"))
        #expect(pkg.dependencies == ["b": "^2.0.0", "nativo": "^1.0.0"])
        _ = try await inst.uninstall(["nativo"])
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "node_modules/nativo").path))
        #expect(PackageJSON(url: dir.appending(path: "package.json")).dependencies == ["b": "^2.0.0"])
        let rep2 = try await Installer(project: project(["sowin": "1.0.0", "inexistente": "1"]), registry: reg)
            .install()
        // Pacote de outro sistema não é "pulado por problema": sai em `plataforma`,
        // que a shell resume numa linha só em vez de um erro vermelho por pacote.
        #expect(rep2.plataforma.first?.hasPrefix("sowin") == true)
        #expect(rep2.skipped.isEmpty)
        #expect(rep2.failed["inexistente"] != nil)
    }

    @Test func nativoComEquivalenteEmbutidoNaoViraAviso() {
        for n in ["esbuild", "@esbuild/linux-x64", "@rollup/rollup-darwin-arm64", "fsevents", "@swc/core"] {
            #expect(Installer.cobertoPorDentro(n))
        }
        // Estes faltam de verdade: o aviso vermelho continua valendo.
        for n in ["sharp", "better-sqlite3", "node-sass", "rollup-plugin-x"] {
            #expect(!Installer.cobertoPorDentro(n))
        }
    }

    @Test func tarRoundTripAndLongNames() throws {
        let long = String(repeating: "pasta-longa/", count: 12) + "arquivo.js"
        let entries = [
            Tar.Entry(path: "package/" + long, data: Data("x".utf8), isDir: false, mode: 0o644, link: nil),
            Tar.Entry(path: "package/dir", data: Data(), isDir: true, mode: 0o755, link: nil),
        ]
        let back = try Tar.read(Tar.write(entries))
        #expect(back.map(\.path) == ["package/" + long, "package/dir"])
        let gz = try #require(GzipCodec.compress(Data("olá".utf8)))
        #expect(GzipCodec.decompress(gz) == Data("olá".utf8))
    }

    @Test func esmFallback() throws {
        let map = EsmFallback.importMap(packages: ["react": "^19.2.0"])
        #expect(map.contains("\"react\" : \"https://esm.sh/react@19.2.0?dev\""))
        let dir = try project(["react": "^19"])
        #expect(EsmFallback.missing(project: dir) == ["react": "^19"])
    }
}

struct RegistryURLTests {
    @Test func scopedPackagesAreEncodedOnce() {
        let r = HTTPRegistry()
        #expect(r.packumentURL("react").absoluteString == "https://registry.npmjs.org/react")
        #expect(r.packumentURL("@vitejs/plugin-react")
            .absoluteString == "https://registry.npmjs.org/@vitejs%2Fplugin-react")
    }
}

/// O pacote baixado tem que bater com o `integrity` do registro.
struct IntegridadeTests {
    let dados = Data("conteúdo do tarball".utf8)

    func integridade(_ algoritmo: String) -> String {
        switch algoritmo {
        case "sha512": "sha512-" + Data(SHA512.hash(data: dados)).base64EncodedString()
        case "sha1": "sha1-" + Data(Insecure.SHA1.hash(data: dados)).base64EncodedString()
        default: "sha256-" + Data(SHA256.hash(data: dados)).base64EncodedString()
        }
    }

    @Test func passaQuandoBate() throws {
        for a in ["sha512", "sha256", "sha1"] {
            try HTTPRegistry.conferir(dados, contra: integridade(a), nome: "x")
        }
    }

    @Test func falhaQuandoNaoBate() {
        #expect(throws: NpmError.self) {
            try HTTPRegistry.conferir(Data("outra coisa".utf8), contra: integridade("sha512"), nome: "x")
        }
    }

    @Test func semIntegridadeOuComAlgoritmoDesconhecidoNaoTrava() throws {
        try HTTPRegistry.conferir(dados, contra: nil, nome: "x")
        try HTTPRegistry.conferir(dados, contra: "sha999-abc", nome: "x")
    }
}
