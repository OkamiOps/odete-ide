import Foundation
@testable import OdeteFiles
import Testing

struct FileOpsTests {
    @Test func crud() throws {
        let ops = try FileOps(root: tempDir())
        try ops.createFile("a.txt", contents: "olá")
        #expect(try ops.read("a.txt") == "olá")
        #expect(throws: FileError.alreadyExists("a.txt")) { try ops.createFile("a.txt") }
        let renamed = try ops.rename("a.txt", to: "b.txt")
        #expect(renamed == "b.txt")
        #expect(!ops.exists("a.txt") && ops.exists("b.txt"))
        try ops.createDirectory("dir")
        try ops.move("b.txt", to: "dir/c.txt")
        #expect(try ops.read("dir/c.txt") == "olá")
        #expect(ops.isDirectory("dir"))
        try ops.delete("dir")
        #expect(!ops.exists("dir"))
        #expect(throws: FileError.notFound("nada")) { try ops.delete("nada") }
    }

    @Test func refusesEscapingRoot() throws {
        let ops = try FileOps(root: tempDir())
        #expect(throws: FileError.outsideRoot("../x")) { try ops.write("../x", "") }
        #expect(throws: FileError.outsideRoot("/etc/passwd")) { try ops.read("/etc/passwd") }
        try ops.createDirectory("d")
        #expect(throws: FileError.outsideRoot("d/inner")) { try ops.move("d", to: "d/inner") }
    }

    @Test func freeNames() throws {
        let ops = try FileOps(root: tempDir())
        #expect(ops.freeName(in: "", base: "sem-titulo", ext: "txt") == "sem-titulo.txt")
        try ops.createFile("sem-titulo.txt")
        #expect(ops.freeName(in: "", base: "sem-titulo", ext: "txt") == "sem-titulo-2.txt")
    }
}

/// Apagar no iPad não some com o arquivo: ele fica na lixeira do projeto até a poda.
struct LixeiraTests {
    func projeto() throws -> FileOps {
        let raiz = FileManager.default.temporaryDirectory.appending(path: "odete-lixo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
        return FileOps(root: raiz)
    }

    @Test func apagarGuardaEDesfazerTrazDeVolta() throws {
        let ops = try projeto()
        try ops.write("a.txt", "conteúdo")
        let lixo = try #require(try ops.delete("a.txt"))
        #expect(!ops.exists("a.txt"))
        #expect(FileManager.default.fileExists(atPath: lixo.path))
        try ops.restore(from: lixo, to: "a.txt")
        #expect(try ops.read("a.txt") == "conteúdo")
    }

    @Test func aLixeiraNaoCresceSemFim() throws {
        let ops = try projeto()
        for i in 0 ..< 60 {
            try ops.write("f\(i).txt", "x")
            _ = try ops.delete("f\(i).txt")
        }
        let itens = try FileManager.default.contentsOfDirectory(at: ops.lixeira, includingPropertiesForKeys: nil)
        #expect(itens.count <= 50)
        #expect(ops.tamanhoDaLixeira() > 0)
        ops.esvaziarLixeira()
        #expect(ops.tamanhoDaLixeira() == 0)
    }
}

/// Ler não pode estragar o arquivo. `String(decoding:as:)` troca byte inválido por
/// `\u{FFFD}` sem reclamar, e salvar depois gravava os losangos por cima do original.
struct LeituraDeTextoTests {
    func projeto() throws -> FileOps {
        let raiz = FileManager.default.temporaryDirectory.appending(path: "odete-txt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
        return FileOps(root: raiz)
    }

    @Test func binarioNaoEhLidoComoTexto() throws {
        let ops = try projeto()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x1A, 0x0A, 0xFF, 0xD8])
        try bytes.write(to: ops.url("imagem.png"))
        #expect(throws: FileError.naoEhTexto("imagem.png")) { try ops.read("imagem.png") }
    }

    @Test func latin1NaoEhLidoComoTexto() throws {
        let ops = try projeto()
        let bytes = try #require("ação".data(using: .isoLatin1))
        try bytes.write(to: ops.url("velho.txt"))
        #expect(throws: FileError.naoEhTexto("velho.txt")) { try ops.read("velho.txt") }
    }

    @Test func utf8ContinuaAbrindo() throws {
        let ops = try projeto()
        try ops.write("ok.txt", "ação, café — tudo certo ✅")
        #expect(try ops.read("ok.txt") == "ação, café — tudo certo ✅")
    }

    @Test func arquivoVazioEhTexto() throws {
        let ops = try projeto()
        try ops.write("vazio.txt", "")
        #expect(try ops.read("vazio.txt") == "")
    }
}
