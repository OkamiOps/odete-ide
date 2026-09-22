import Foundation
import OdeteFiles
@testable import OdeteNpm
import Testing

/// Um projeto num caminho que parece o iCloud Drive (`…/Mobile Documents/…`), que é uma
/// das pistas que `PastaDeModulos.naNuvem` usa. O teste não tem iCloud de verdade.
func projetoNaNuvem(_ deps: [String: String]) throws -> URL {
    let u = FileManager.default.temporaryDirectory
        .appending(path: "odete-npm-\(UUID().uuidString)/Mobile Documents/iCloud~odete/Documents/Projects/proj")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["name": "proj", "dependencies": deps])
        .write(to: u.appending(path: "package.json"))
    return u
}

/// O que existe em `caminho`, sem seguir link.
func tipo(_ caminho: URL) -> FileAttributeType? {
    (try? FileManager.default.attributesOfItem(atPath: caminho.path))?[.type] as? FileAttributeType
}

/// No iCloud, `node_modules` é link para `node_modules.nosync`. Fora dele, nada muda.
struct NuvemTests {
    func registro() -> FakeRegistry {
        InstallerTests().registry()
    }

    @Test func noICloudOsPacotesVaoParaNosyncEONodeModulesViraLink() async throws {
        let reg = registro()
        let dir = try projetoNaNuvem(["a": "^1.0.0", "c": "^3.0.0"])
        let inst = Installer(project: dir, registry: reg)
        #expect(inst.nuvem)
        let rep = try await inst.install()
        #expect(rep.failed.isEmpty, "\(rep.failed)")
        let fm = FileManager.default
        #expect(tipo(dir.appending(path: "node_modules")) == .typeSymbolicLink)
        #expect(try fm
            .destinationOfSymbolicLink(atPath: dir.appending(path: "node_modules").path) == "node_modules.nosync")
        #expect(tipo(dir.appending(path: "node_modules.nosync")) == .typeDirectory)
        // Pelo link e na pasta real, o mesmo arquivo.
        #expect(fm.fileExists(atPath: dir.appending(path: "node_modules/a/index.js").path))
        #expect(fm.fileExists(atPath: dir.appending(path: "node_modules.nosync/a/index.js").path))
        #expect(fm.fileExists(atPath: dir.appending(path: "node_modules.nosync/c/node_modules/b/index.js").path))
        // O atalho do .bin resolve atravessando o link.
        #expect(fm.fileExists(atPath: dir.appending(path: "node_modules/.bin/cee").path))
        // O lock não sabe de nuvem: as chaves são as do npm.
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        #expect(lock.packages["node_modules/a"] != nil)
        #expect(!lock.packages.keys.contains { $0.contains("nosync") })
    }

    @Test func projetoLocalContinuaComPastaDeVerdade() async throws {
        let dir = try project(["a": "^1.0.0"])
        let inst = Installer(project: dir, registry: registro())
        #expect(!inst.nuvem)
        _ = try await inst.install()
        #expect(tipo(dir.appending(path: "node_modules")) == .typeDirectory)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "node_modules.nosync").path))
        #expect(PastaDeModulos.migrarSePreciso(dir) == false)
        #expect(tipo(dir.appending(path: "node_modules")) == .typeDirectory)
    }

    /// Projeto do iCloud instalado por uma versão anterior tem a pasta de verdade: a
    /// abertura troca pelo arranjo, uma vez só, sem perder nada.
    @Test func migracaoNaAberturaTrocaAPastaPeloLink() async throws {
        let dir = try projetoNaNuvem(["a": "^1.0.0"])
        let pacote = dir.appending(path: "node_modules/a")
        try FileManager.default.createDirectory(at: pacote, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: pacote.appending(path: "package.json"))
        try "node_modules/\n".write(to: dir.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        #expect(PastaDeModulos.migrarSePreciso(dir))
        #expect(tipo(dir.appending(path: "node_modules")) == .typeSymbolicLink)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "node_modules.nosync/a/package.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "node_modules/a/package.json").path))
        // O link não é pasta para o git: `node_modules/` sozinho não bastava.
        let gitignore = try String(contentsOf: dir.appending(path: ".gitignore"), encoding: .utf8)
        #expect(gitignore == "node_modules/\nnode_modules\nnode_modules.nosync/\n")
        // Uma vez só.
        #expect(PastaDeModulos.migrarSePreciso(dir) == false)
        // E o install seguinte usa o que migrou.
        let reg = registro()
        _ = try await Installer(project: dir, registry: reg).install()
        #expect(tipo(dir.appending(path: "node_modules")) == .typeSymbolicLink)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "node_modules/a/index.js").path))
    }

    /// `rm -rf node_modules` no terminal leva só o link. O que a pessoa quis foi começar
    /// do zero: a pasta real órfã não pode voltar calada.
    @Test func semOLinkOInstallRecomecaDoZero() async throws {
        let reg = registro()
        let dir = try projetoNaNuvem(["a": "^1.0.0"])
        let inst = Installer(project: dir, registry: reg)
        _ = try await inst.install()
        let sobra = dir.appending(path: "node_modules.nosync/a/sobra.txt")
        try Data("velho".utf8).write(to: sobra)
        try FileManager.default.removeItem(at: dir.appending(path: "node_modules"))
        let antes = reg.downloads.withLock { $0.count }
        let rep = try await inst.install()
        #expect(rep.failed.isEmpty)
        #expect(tipo(dir.appending(path: "node_modules")) == .typeSymbolicLink)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "node_modules/a/index.js").path))
        #expect(!FileManager.default.fileExists(atPath: sobra.path))
        #expect(reg.downloads.withLock { $0.count } > antes)
    }

    /// A pasta real apagada e o link sobrando (apontando para o nada): o install refaz
    /// a pasta e deixa o link como estava.
    @Test func semAPastaRealOInstallRefazOsPacotes() async throws {
        let reg = registro()
        let dir = try projetoNaNuvem(["a": "^1.0.0"])
        let inst = Installer(project: dir, registry: reg)
        _ = try await inst.install()
        try FileManager.default.removeItem(at: dir.appending(path: "node_modules.nosync"))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "node_modules").path))
        _ = try await inst.install()
        #expect(tipo(dir.appending(path: "node_modules")) == .typeSymbolicLink)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "node_modules/a/index.js").path))
    }

    /// `npm uninstall` apaga pelo link: a limpeza lista a pasta real, que o
    /// `contentsOfDirectory(at:)` não alcançaria através do link.
    @Test func uninstallNaNuvemTiraDaPastaReal() async throws {
        let reg = registro()
        let dir = try projetoNaNuvem(["a": "^1.0.0", "c": "^3.0.0"])
        let inst = Installer(project: dir, registry: reg)
        _ = try await inst.install()
        _ = try await inst.uninstall(["c"])
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "node_modules.nosync/c").path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "node_modules.nosync/a").path))
    }

    @Test(arguments: [
        (nil, false, ["node_modules/"]),
        ("node_modules/\n", false, []),
        ("dist/\nnode_modules.nosync/\n", false, ["node_modules/"]),
        (nil, true, ["node_modules", "node_modules.nosync/"]),
        ("node_modules/\n", true, ["node_modules", "node_modules.nosync/"]),
        ("node_modules\nnode_modules.nosync/\n", true, []),
        ("/node_modules\n*.nosync\n", true, []),
        ("**/node_modules*\n", true, []),
    ] as [(String?, Bool, [String])])
    func linhasDoGitignore(texto: String?, nuvem: Bool, esperado: [String]) {
        #expect(PastaDeModulos.linhasQueFaltam(noGitignore: texto, nuvem: nuvem) == esperado)
    }

    @Test func gitignoreNovoNaNuvem() throws {
        let dir = try projetoNaNuvem([:])
        #expect(Installer(project: dir, registry: registro()).garantirGitignore() == [
            "node_modules", "node_modules.nosync/",
        ])
        let texto = try String(contentsOf: dir.appending(path: ".gitignore"), encoding: .utf8)
        #expect(texto == "node_modules\nnode_modules.nosync/\ndist/\n.DS_Store\n")
        #expect(Installer(project: dir, registry: registro()).garantirGitignore().isEmpty)
    }
}

/// Binários de plataforma opcionais: ficam no lock, não são baixados.
struct PlataformaTests {
    /// `ferramenta` puxa um binário por plataforma, como esbuild, rollup, swc do next,
    /// lightningcss e sharp fazem.
    func registro() -> FakeRegistry {
        let r = FakeRegistry()
        r.add(
            "ferramenta",
            "1.0.0",
            optional: [
                "@ferr/darwin-arm64": "1.0.0", "@ferr/linux-x64": "1.0.0", "@ferr/win32-x64": "1.0.0",
                "ajudante": "^1.0.0",
            ],
            files: ["index.js": "module.exports = 1;"]
        )
        r.add("@ferr/darwin-arm64", "1.0.0", files: ["bin": "binário"], os: ["darwin"], cpu: ["arm64"])
        r.add("@ferr/linux-x64", "1.0.0", files: ["bin": "binário"], os: ["linux"], cpu: ["x64"])
        r.add("@ferr/win32-x64", "1.0.0", files: ["bin": "binário"], os: ["win32"], cpu: ["x64"])
        // Opcional sem restrição de plataforma: esse instala normalmente.
        r.add("ajudante", "1.0.0", files: ["index.js": "module.exports = 2;"])
        r.add(
            "esbuild",
            "0.25.0",
            optional: ["@esbuild/darwin-arm64": "0.25.0", "@esbuild/linux-x64": "0.25.0"],
            install: true
        )
        r.add("@esbuild/darwin-arm64", "0.25.0", files: ["bin/esbuild": "binário"], os: ["darwin"], cpu: ["arm64"])
        r.add("@esbuild/linux-x64", "0.25.0", files: ["bin/esbuild": "binário"], os: ["linux"], cpu: ["x64"])
        return r
    }

    @Test func opcionalDePlataformaFicaSoNoLock() async throws {
        let reg = registro()
        let dir = try project(["ferramenta": "^1.0.0"])
        let inst = Installer(project: dir, registry: reg)
        let rep = try await inst.install()
        #expect(rep.failed.isEmpty, "\(rep.failed)")
        let baixados = reg.downloads.withLock { $0 }
        #expect(!baixados.contains { $0.contains("@ferr/") })
        #expect(baixados.contains { $0.contains("ajudante") })
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "node_modules/@ferr").path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "node_modules/ajudante/index.js").path))
        // Nem o de darwin/arm64: é do macOS, não roda no iPad.
        #expect(rep.plataforma.count == 3)
        #expect(rep.plataforma.contains { $0.hasPrefix("@ferr/darwin-arm64") })
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        let darwin = try #require(lock.packages["node_modules/@ferr/darwin-arm64"])
        #expect(darwin.optional && darwin.os == ["darwin"] && darwin.cpu == ["arm64"] && darwin.soDePlataforma)
        #expect(lock.packages["node_modules/ajudante"]?.soDePlataforma == false)
        #expect(!inst.list().contains { $0.name.hasPrefix("@ferr/") })

        // Segunda instalação pelo lock: nenhuma pergunta ao registro, nenhum download de
        // binário de plataforma, e o relatório continua dizendo o que ficou de fora.
        let perguntas = reg.hits.withLock { $0 }
        let downloads = reg.downloads.withLock { $0.count }
        try FileManager.default.removeItem(at: dir.appending(path: "node_modules"))
        let rep2 = try await inst.install()
        #expect(reg.hits.withLock { $0 } == perguntas)
        #expect(!reg.downloads.withLock { $0.dropFirst(downloads) }.contains { $0.contains("@ferr/") })
        #expect(rep2.plataforma.count == 3)
        #expect(try Lockfile.load(dir.appending(path: "package-lock.json")) == lock)
    }

    /// O esbuild continua coberto pela Odete e o binário dele não é baixado — nem era
    /// preciso: quem roda é o esbuild embutido.
    @Test func esbuildContinuaCobertoSemOBinario() async throws {
        let reg = registro()
        let dir = try project(["esbuild": "^0.25.0"])
        let rep = try await Installer(project: dir, registry: reg).install()
        #expect(rep.failed.isEmpty)
        #expect(rep.nativosCobertos == ["esbuild@0.25.0"])
        #expect(rep.native.isEmpty)
        #expect(!reg.downloads.withLock { $0 }.contains { $0.contains("@esbuild/") })
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "node_modules/esbuild/package.json").path))
    }

    /// Lock escrito pelo npm de verdade traz o binário de todas as plataformas, com
    /// `optional`, `os` e `cpu`. Nenhum deles pode ser baixado.
    @Test func lockDoNpmComBinariosDeTodasAsPlataformas() async throws {
        let reg = registro()
        let dir = try project(["ferramenta": "^1.0.0"])
        func entrada(_ nome: String, os: String, cpu: String) -> [String: Any] {
            ["version": "1.0.0", "resolved": "fake://\(nome)/1.0.0.tgz", "optional": true, "os": [os], "cpu": [cpu]]
        }
        let lock: [String: Any] = [
            "name": "proj", "lockfileVersion": 3, "requires": true,
            "packages": [
                "": ["name": "proj", "dependencies": ["ferramenta": "^1.0.0"]],
                "node_modules/ferramenta": [
                    "version": "1.0.0", "resolved": "fake://ferramenta/1.0.0.tgz",
                    "optionalDependencies": ["@ferr/darwin-arm64": "1.0.0", "@ferr/linux-x64": "1.0.0"],
                ],
                "node_modules/@ferr/darwin-arm64": entrada("@ferr/darwin-arm64", os: "darwin", cpu: "arm64"),
                "node_modules/@ferr/linux-x64": entrada("@ferr/linux-x64", os: "linux", cpu: "x64"),
            ],
        ]
        try JSONSerialization.data(withJSONObject: lock).write(to: dir.appending(path: "package-lock.json"))
        let rep = try await Installer(project: dir, registry: reg).install()
        #expect(rep.failed.isEmpty)
        #expect(reg.hits.withLock { $0 } == 0)
        #expect(reg.downloads.withLock { $0 } == ["fake://ferramenta/1.0.0.tgz"])
        #expect(rep.plataforma.count == 2)
    }

    /// Lock de uma versão anterior da Odete: o binário de darwin/arm64 foi instalado e o
    /// lock só diz que era nativo. O install pergunta ao registro uma vez, tira o binário
    /// do disco e grava o lock já no formato novo.
    @Test func lockAntigoDaOdeteComOBinarioInstalado() async throws {
        let reg = registro()
        let dir = try project(["ferramenta": "^1.0.0"])
        _ = try await Installer(project: dir, registry: reg).install()
        // Simula o estado deixado pela versão anterior.
        let lockURL = dir.appending(path: "package-lock.json")
        var antigo = try #require(Lockfile.load(lockURL))
        var velho = try #require(antigo.packages["node_modules/@ferr/darwin-arm64"])
        velho.optional = false; velho.os = []; velho.cpu = []; velho.native = true
        antigo.packages["node_modules/@ferr/darwin-arm64"] = velho
        antigo.packages["node_modules/@ferr/linux-x64"] = nil
        antigo.packages["node_modules/@ferr/win32-x64"] = nil
        try antigo.save(to: lockURL, root: ["name": "proj"])
        let binario = dir.appending(path: "node_modules/@ferr/darwin-arm64")
        try FileManager.default.createDirectory(at: binario, withIntermediateDirectories: true)
        try Data(#"{"version":"1.0.0"}"#.utf8).write(to: binario.appending(path: "package.json"))

        let perguntas = reg.hits.withLock { $0 }
        let rep = try await Installer(project: dir, registry: reg).install()
        #expect(rep.failed.isEmpty)
        #expect(reg.hits.withLock { $0 } > perguntas)
        #expect(!FileManager.default.fileExists(atPath: binario.path))
        #expect(try #require(Lockfile.load(lockURL)).packages["node_modules/@ferr/darwin-arm64"]?
            .soDePlataforma == true)
    }
}

/// A resolução e o download em paralelo, e o que eles não podem quebrar.
struct ParaleloTests {
    @Test func packumentsETarballsVaoEmParaleloComTeto() async throws {
        let reg = FakeRegistry()
        var deps: [String: String] = [:]
        for i in 0 ..< 30 {
            reg.add("p\(i)", "1.0.0", files: ["index.js": "\(i)"])
            deps["p\(i)"] = "^1.0.0"
        }
        reg.latencia = { _ in .milliseconds(15) }
        let dir = try project(deps)
        let inst = Installer(project: dir, registry: reg)
        let rep = try await inst.install()
        #expect(rep.installed.count == 30)
        let buscas = reg.simultaneas.withLock { $0.pico }
        #expect(buscas > 1 && buscas <= inst.buscasSimultaneas)
        let downloads = reg.tarballsNoAr.withLock { $0.pico }
        #expect(downloads > 1 && downloads <= inst.concurrency)
    }

    /// Dois pedidos do mesmo pacote com faixas que não se cruzam: o packument guardado
    /// depois da primeira escolha é enxuto, e a segunda busca de novo.
    @Test func conflitoDeVersaoAindaAchaASegunda() async throws {
        let reg = InstallerTests().registry()
        let dir = try project(["a": "^1.0.0", "c": "^3.0.0"])
        _ = try await Installer(project: dir, registry: reg).install()
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        #expect(lock.packages["node_modules/b"]?.version == "1.2.0")
        #expect(lock.packages["node_modules/c/node_modules/b"]?.version == "2.0.0")
        #expect(reg.hits.withLock { $0 } <= 4)
    }

    /// Pacote atualizado não leva junto os aninhados que não mudaram. Antes, a pasta
    /// inteira do pai era apagada, e o aninhado — que não estava na lista para extrair
    /// de novo — sumia.
    @Test func paiAtualizadoMantemOsAninhados() async throws {
        let reg = InstallerTests().registry()
        let dir = try project(["a": "^1.0.0", "c": "^3.0.0"])
        let inst = Installer(project: dir, registry: reg)
        _ = try await inst.install()
        reg.add("c", "3.2.0", deps: ["b": "^2"], files: ["cli.js": "// nova"])
        var pkg = PackageJSON(url: dir.appending(path: "package.json"))
        pkg.set("c", range: "^3.2.0", dev: false)
        try pkg.save()
        let rep = try await inst.install()
        #expect(rep.failed.isEmpty)
        #expect(rep.installed.map(\.name) == ["c"])
        #expect(FileManager.default
            .fileExists(atPath: dir.appending(path: "node_modules/c/node_modules/b/index.js").path))
        #expect(try String(contentsOf: dir.appending(path: "node_modules/c/cli.js"), encoding: .utf8) == "// nova")
    }

    /// Tarball que não descomprime não pode deixar meio pacote no disco: com o
    /// package.json no lugar, o próximo install acharia que está tudo lá.
    @Test func pacoteQuebradoNaoFicaPelaMetade() async throws {
        let reg = InstallerTests().registry()
        let url = "fake://a/1.0.0.tgz"
        let bom = try #require(reg.tarballs[url])
        reg.tarballs[url] = bom.prefix(bom.count - 12)
        let dir = try project(["a": "^1.0.0"])
        let rep = try await Installer(project: dir, registry: reg).install()
        #expect(rep.failed["a"] != nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "node_modules/a").path))
    }
}
