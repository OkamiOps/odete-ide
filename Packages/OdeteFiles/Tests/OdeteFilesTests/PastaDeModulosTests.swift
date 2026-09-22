import Foundation
@testable import OdeteFiles
import Testing

/// O arranjo do `node_modules` no iCloud, e tudo o que trata `node_modules` como pasta
/// pesada tratando `node_modules.nosync` igual.
struct PastaDeModulosTests {
    /// Projeto num caminho que parece o iCloud Drive; o teste não tem iCloud de verdade.
    func naNuvem() throws -> URL {
        let u = try tempDir().appending(path: "Mobile Documents/iCloud~odete/Documents/Projects/app")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func tipo(_ u: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: u.path))?[.type] as? FileAttributeType
    }

    @Test func reconheceOICloudPeloCaminho() throws {
        #expect(try PastaDeModulos.naNuvem(naNuvem()))
        #expect(try !PastaDeModulos.naNuvem(tempDir()))
    }

    @Test func prepararNaNuvemCriaPastaRealELinkRelativo() throws {
        let raiz = try naNuvem()
        try PastaDeModulos.preparar(raiz, nuvem: true)
        #expect(tipo(raiz.appending(path: "node_modules")) == .typeSymbolicLink)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: raiz.appending(path: "node_modules").path)
            == "node_modules.nosync")
        #expect(PastaDeModulos.pastaReal(raiz).lastPathComponent == "node_modules.nosync")
        // De novo não muda nada.
        try PastaDeModulos.preparar(raiz, nuvem: true)
        #expect(PastaDeModulos.situacao(raiz) == .nosso)
    }

    @Test func prepararForaDaNuvemCriaAPastaComoSempre() throws {
        let raiz = try tempDir()
        try PastaDeModulos.preparar(raiz, nuvem: false)
        #expect(tipo(raiz.appending(path: "node_modules")) == .typeDirectory)
        #expect(PastaDeModulos.pastaReal(raiz) == raiz.appending(path: "node_modules"))
        #expect(!FileManager.default.fileExists(atPath: raiz.appending(path: "node_modules.nosync").path))
    }

    /// Link que a pessoa fez para outro lugar é dela: nem no iCloud a Odete mexe.
    @Test func linkAlheioFicaComoEsta() throws {
        let raiz = try naNuvem()
        let outro = try tempDir()
        try FileManager.default.createSymbolicLink(
            atPath: raiz.appending(path: "node_modules").path,
            withDestinationPath: outro.path
        )
        try PastaDeModulos.preparar(raiz, nuvem: true)
        #expect(PastaDeModulos.situacao(raiz) == .alheio)
        #expect(!FileManager.default.fileExists(atPath: raiz.appending(path: "node_modules.nosync").path))
        #expect(PastaDeModulos.migrarSePreciso(raiz) == false)
    }

    /// Mover um projeto local para o iCloud: migrar antes, forçando.
    @Test func migracaoForcadaAntesDeIrParaONuvem() throws {
        let raiz = try tempDir()
        try FileManager.default.createDirectory(
            at: raiz.appending(path: "node_modules/react"),
            withIntermediateDirectories: true
        )
        #expect(PastaDeModulos.migrarSePreciso(raiz) == false)
        #expect(PastaDeModulos.migrarSePreciso(raiz, nuvem: true))
        #expect(FileManager.default.fileExists(atPath: raiz.appending(path: "node_modules/react").path))
        #expect(tipo(raiz.appending(path: "node_modules")) == .typeSymbolicLink)
    }

    /// Busca, zip e lixeira tratam `node_modules.nosync` como tratam `node_modules`.
    @Test func buscaEZipPulamOsPacotesNaNuvem() throws {
        let raiz = try naNuvem()
        let ops = FileOps(root: raiz)
        try ops.write("src/a.ts", "procura aqui")
        try ops.write("node_modules.nosync/pkg/index.js", "procura aqui também")
        try FileManager.default.createSymbolicLink(
            atPath: raiz.appending(path: "node_modules").path,
            withDestinationPath: "node_modules.nosync"
        )
        #expect(try TextSearch.search(root: raiz, query: "procura").map(\.path) == ["src/a.ts"])
        let zip = try tempDir().appending(path: "app.zip")
        try Zip.create(directory: raiz, to: zip)
        let fora = try tempDir()
        try Zip.extract(zip, to: fora)
        #expect(FileManager.default.fileExists(atPath: fora.appending(path: "src/a.ts").path))
        #expect(!FileManager.default.fileExists(atPath: fora.appending(path: "node_modules.nosync").path))
        #expect(!FileManager.default.fileExists(atPath: fora.appending(path: "node_modules").path))
    }

    @Test func pacoteApagadoVaiParaALixeiraSemSincronizar() throws {
        let agora = Date(timeIntervalSince1970: 1000)
        #expect(FileOps.nomeNaLixeira("src/a.ts", agora: agora) == "1000-a.ts")
        #expect(FileOps.nomeNaLixeira("node_modules/react", agora: agora) == "1000-react.nosync")
        #expect(FileOps.nomeNaLixeira("node_modules", agora: agora) == "1000-node_modules.nosync")
        #expect(FileOps.nomeNaLixeira("node_modules.nosync", agora: agora) == "1000-node_modules.nosync")
        // E o desfazer devolve com o nome de antes.
        let raiz = try tempDir()
        let ops = FileOps(root: raiz)
        try ops.write("node_modules/react/index.js", "x")
        let lixo = try #require(try ops.delete("node_modules/react"))
        #expect(lixo.lastPathComponent.hasSuffix("-react.nosync"))
        try ops.restore(from: lixo, to: "node_modules/react")
        #expect(try ops.read("node_modules/react/index.js") == "x")
    }
}
