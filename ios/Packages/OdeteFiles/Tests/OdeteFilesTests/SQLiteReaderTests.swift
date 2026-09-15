import Foundation
@testable import OdeteFiles
import SQLite3
import Testing

/// Banco aberto para ver: tabelas, contagem e uma página de linhas.
struct SQLiteReaderTests {
    let dump = """
    CREATE TABLE pecas (id TEXT PRIMARY KEY, nome TEXT, preco REAL, estoque INTEGER);
    INSERT INTO pecas VALUES ('01','Tigela funda',128.0,7);
    INSERT INTO pecas VALUES ('02','Caneca alta',96.0,12);
    INSERT INTO pecas VALUES ('03','Copo torcido',74.0,NULL);
    CREATE TABLE vazia (a TEXT);
    """

    @Test func dumpViraTabelas() throws {
        let db = try SQLiteReader(script: dump)
        #expect(db.tabelas().map(\.nome) == ["pecas", "vazia"])
        #expect(db.tabelas().first?.linhas == 3)
    }

    @Test func paginaTrazColunasELinhas() throws {
        let db = try SQLiteReader(script: dump)
        let p = db.pagina("pecas")
        #expect(p.colunas == ["id", "nome", "preco", "estoque"])
        #expect(p.linhas.count == 3)
        #expect(p.linhas[0][1] == "Tigela funda")
        #expect(p.total == 3)
    }

    @Test func nuloViraVazioENaoSumeAColuna() throws {
        let db = try SQLiteReader(script: dump)
        #expect(db.pagina("pecas").linhas[2][3] == "")
    }

    @Test func limiteEOffsetRecortam() throws {
        let db = try SQLiteReader(script: dump)
        let p = db.pagina("pecas", limite: 1, offset: 1)
        #expect(p.linhas.count == 1)
        #expect(p.linhas[0][0] == "02")
        #expect(p.total == 3)
    }

    @Test func tabelaVaziaNaoQuebra() throws {
        let db = try SQLiteReader(script: dump)
        let p = db.pagina("vazia")
        #expect(p.colunas == ["a"])
        #expect(p.linhas.isEmpty)
    }

    @Test func sqlInvalidoFalhaComMotivo() {
        #expect(throws: SQLiteReader.Falha.self) { try SQLiteReader(script: "ISTO NAO E SQL;") }
    }

    @Test func arquivoQueNaoEBancoFalha() throws {
        let u = FileManager.default.temporaryDirectory.appending(path: "nao-banco-\(UUID().uuidString).bin")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: u)
        #expect(throws: SQLiteReader.Falha.self) { try SQLiteReader(arquivo: u) }
    }

    @Test func bancoEmDiscoEhLido() throws {
        let u = FileManager.default.temporaryDirectory.appending(path: "loja-\(UUID().uuidString).sqlite")
        var p: OpaquePointer?
        #expect(sqlite3_open(u.path, &p) == SQLITE_OK)
        #expect(sqlite3_exec(p, dump, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(p)
        let db = try SQLiteReader(arquivo: u)
        #expect(db.tabelas().map(\.nome) == ["pecas", "vazia"])
        #expect(db.pagina("pecas").linhas.count == 3)
        try? FileManager.default.removeItem(at: u)
    }
}
