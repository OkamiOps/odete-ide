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

    /// `moveItem` guarda a data de modificação: a poda, que olhava essa data, apagava de
    /// vez um arquivo antigo no mesmo instante em que ele chegava — e o desfazer falhava.
    @Test func arquivoAntigoNaoSomeAoChegarNaLixeira() throws {
        let ops = try projeto()
        try ops.write("velho.txt", "de outubro")
        let mes = Date().addingTimeInterval(-30 * 86400)
        try FileManager.default.setAttributes([.modificationDate: mes], ofItemAtPath: ops.url("velho.txt").path)
        let lixo = try #require(try ops.delete("velho.txt"))
        #expect(FileManager.default.fileExists(atPath: lixo.path), "a poda apagou o que acabou de chegar")
        try ops.restore(from: lixo, to: "velho.txt")
        #expect(try ops.read("velho.txt") == "de outubro")
    }

    @Test func pastaAntigaTambemVoltaDaLixeira() throws {
        let ops = try projeto()
        try ops.write("antiga/dentro.txt", "x")
        let ano = Date().addingTimeInterval(-365 * 86400)
        try FileManager.default.setAttributes([.modificationDate: ano], ofItemAtPath: ops.url("antiga").path)
        let lixo = try #require(try ops.delete("antiga"))
        try ops.restore(from: lixo, to: "antiga")
        #expect(try ops.read("antiga/dentro.txt") == "x")
    }

    /// A idade na lixeira é a hora do nome — quando foi apagado —, não a do arquivo.
    @Test func podaPelaHoraDoNome() throws {
        let ops = try projeto()
        try FileManager.default.createDirectory(at: ops.lixeira, withIntermediateDirectories: true)
        let dezDias = Int(Date().addingTimeInterval(-10 * 86400).timeIntervalSince1970)
        let ontem = Int(Date().addingTimeInterval(-86400).timeIntervalSince1970)
        let velho = ops.lixeira.appending(path: "\(dezDias)-velho.txt")
        let novo = ops.lixeira.appending(path: "\(ontem)-novo.txt")
        try "v".write(to: velho, atomically: true, encoding: .utf8)
        try "n".write(to: novo, atomically: true, encoding: .utf8)
        // O novo tem data de arquivo antiga; o velho, data de agora. Vale o nome.
        let ano = Date().addingTimeInterval(-365 * 86400)
        try FileManager.default.setAttributes([.modificationDate: ano], ofItemAtPath: novo.path)
        ops.podarLixeira()
        #expect(!FileManager.default.fileExists(atPath: velho.path))
        #expect(FileManager.default.fileExists(atPath: novo.path))
    }

    /// Mandar para a lixeira falhou: antes o código apagava de vez. Agora é erro, e o
    /// arquivo fica onde estava.
    @Test func semLixeiraNadaEApagado() throws {
        let ops = try projeto()
        try ops.write("importante.txt", "não pode sumir")
        // Um arquivo no lugar da pasta da lixeira: mover para dentro dela não dá.
        try FileManager.default.createDirectory(
            at: ops.lixeira.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "atrapalha".write(to: ops.lixeira, atomically: true, encoding: .utf8)
        #expect(throws: FileError.self) { try ops.delete("importante.txt") }
        #expect(try ops.read("importante.txt") == "não pode sumir")
    }

    /// Dois apagares do mesmo nome no mesmo segundo: o segundo `moveItem` batia no
    /// primeiro e caía no `removeItem`.
    @Test func mesmoNomeNoMesmoSegundoNaoColide() throws {
        let ops = try projeto()
        try ops.write("a.txt", "primeiro")
        let um = try #require(try ops.delete("a.txt"))
        try ops.write("a.txt", "segundo")
        let dois = try #require(try ops.delete("a.txt"))
        #expect(um != dois)
        #expect(try String(contentsOf: um, encoding: .utf8) == "primeiro")
        #expect(try String(contentsOf: dois, encoding: .utf8) == "segundo")
    }

    /// O mesmo nome em pastas diferentes, apagados juntos (uma seleção, `src/index.ts` e
    /// `test/index.ts`): os dois vão para a lixeira e os dois voltam.
    @Test func mesmoNomeEmPastasDiferentesApagadosJuntos() throws {
        let ops = try projeto()
        try ops.write("src/index.ts", "do src")
        try ops.write("test/index.ts", "do test")
        let a = try #require(try ops.delete("src/index.ts"))
        let b = try #require(try ops.delete("test/index.ts"))
        #expect(a != b)
        try ops.restore(from: b, to: "test/index.ts")
        try ops.restore(from: a, to: "src/index.ts")
        #expect(try ops.read("src/index.ts") == "do src")
        #expect(try ops.read("test/index.ts") == "do test")
    }

    @Test func horaDoNome() {
        #expect(FileOps.horaNaLixeira("1700000000-a.txt") == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(FileOps.horaNaLixeira("1700000000-2-a.txt") == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(FileOps.horaNaLixeira("sem-hora.txt") == nil)
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
