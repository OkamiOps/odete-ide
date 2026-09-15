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

/// Editar o banco: célula, linha nova, coluna nova — e o dump de volta em SQL.
struct SQLiteEdicaoTests {
    let dump = """
    CREATE TABLE pecas (id TEXT PRIMARY KEY, nome TEXT, preco REAL);
    INSERT INTO pecas VALUES ('01','Tigela funda',128.0);
    INSERT INTO pecas VALUES ('02','Caneca alta',96.0);
    """

    @Test func trocarValorDeUmaCelula() throws {
        let db = try SQLiteReader(script: dump)
        #expect(db.executar("UPDATE \"pecas\" SET \"nome\" = ? WHERE \"id\" = ?", ["Tigela rasa", "01"]) == nil)
        #expect(db.pagina("pecas").linhas[0][1] == "Tigela rasa")
    }

    @Test func linhaNovaEntraMesmoComNotNull() throws {
        let db = try SQLiteReader(script: """
        CREATE TABLE p (id INTEGER PRIMARY KEY, nome TEXT NOT NULL, preco REAL NOT NULL, obs TEXT);
        INSERT INTO p (nome, preco) VALUES ('Tigela', 128.0);
        """)
        // `DEFAULT VALUES` falharia aqui: `nome` e `preco` são NOT NULL sem padrão.
        #expect(db.executar("INSERT INTO \"p\" DEFAULT VALUES") != nil)
        #expect(db.inserirLinha("p") == nil)
        #expect(db.contar("p") == 2)
        let nova = db.pagina("p").linhas[1]
        #expect(nova[1] == "")
        #expect(nova[2] == "0.0")
    }

    @Test func linhaNovaSemObrigatoriasUsaOsPadroes() throws {
        let db = try SQLiteReader(script: "CREATE TABLE s (a TEXT, b INTEGER DEFAULT 7);")
        #expect(db.inserirLinha("s") == nil)
        #expect(db.pagina("s").linhas[0][1] == "7")
    }

    @Test func colunaNovaAparecePraTodaLinha() throws {
        let db = try SQLiteReader(script: dump)
        #expect(db.executar("ALTER TABLE \"pecas\" ADD COLUMN \"estoque\" TEXT") == nil)
        let p = db.pagina("pecas")
        #expect(p.colunas == ["id", "nome", "preco", "estoque"])
        #expect(p.linhas[0][3] == "")
    }

    @Test func somenteLeituraRecusa() throws {
        let u = FileManager.default.temporaryDirectory.appending(path: "ro-\(UUID().uuidString).sqlite")
        var p: OpaquePointer?
        #expect(sqlite3_open(u.path, &p) == SQLITE_OK)
        #expect(sqlite3_exec(p, dump, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(p)
        let db = try SQLiteReader(arquivo: u)
        #expect(!db.editavel)
        #expect(db.executar("DELETE FROM \"pecas\"") != nil)
        #expect(db.contar("pecas") == 2)
        try? FileManager.default.removeItem(at: u)
    }

    @Test func dumpPreservaTipoDosValores() throws {
        let db = try SQLiteReader(script: dump)
        let sql = db.dump()
        // Número sem aspas: aspeando tudo na mão, um REAL voltava do dump como texto.
        #expect(sql.contains("128.0"))
        #expect(!sql.contains("'128.0'"))
        db.executar("UPDATE \"pecas\" SET \"preco\" = NULL WHERE \"id\" = ?", ["02"])
        #expect(db.dump().contains(",NULL)"))
    }

    @Test func dumpVoltaComOQueFoiEditado() throws {
        let db = try SQLiteReader(script: dump)
        db.executar("UPDATE \"pecas\" SET \"nome\" = ? WHERE \"id\" = ?", ["Tigela d'água", "01"])
        let sql = db.dump()
        #expect(sql.contains("CREATE TABLE pecas"))
        // Aspas simples no valor precisam sair dobradas, senão o dump não recarrega.
        #expect(sql.contains("'Tigela d''água'"))
        let volta = try SQLiteReader(script: sql)
        #expect(volta.pagina("pecas").linhas[0][1] == "Tigela d'água")
    }

    @Test func colunasDizemQualEhAChave() throws {
        let db = try SQLiteReader(script: dump)
        let cols = db.colunas("pecas")
        #expect(cols.map(\.nome) == ["id", "nome", "preco"])
        #expect(cols.first?.pk == true)
        #expect(cols.last?.pk == false)
        #expect(cols.last?.valorInicial == "0")
        #expect(cols[1].valorInicial == "")
    }
}
