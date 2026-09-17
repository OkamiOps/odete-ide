import OdeteCore
@testable import OdeteEditor
import Testing

/// SQL de verdade não pode ser acusado.
///
/// A gramática que a Odete embarca é de um SQL genérico e não conhece tudo que o SQLite
/// aceita. Quando ela tropeça numa palavra que é perfeitamente válida no arquivo da
/// pessoa, quem está errado é a ferramenta.
struct SQLDialetoTests {
    func erros(_ texto: String) -> String {
        ParserErros.problemas(text: texto, language: .sql)
            .map { "l\($0.line):\($0.column) \($0.message)" }.joined(separator: " | ")
    }

    @Test func chavePrimariaComAutoincrement() {
        #expect(erros("CREATE TABLE p (id INTEGER PRIMARY KEY AUTOINCREMENT);") == "")
    }

    @Test func outrasFormasDoSQLite() {
        #expect(erros("CREATE TABLE IF NOT EXISTS p (id INTEGER PRIMARY KEY);") == "", "if not exists")
        #expect(erros("CREATE TABLE p (id INTEGER PRIMARY KEY) WITHOUT ROWID;") == "", "without rowid")
        #expect(erros("CREATE TABLE p (id TEXT REFERENCES q(id));") == "", "references")
        #expect(erros("BEGIN TRANSACTION;\nCOMMIT;") == "", "transação")
        #expect(erros("INSERT INTO \"p\" VALUES('01','a',1.0,2);") == "", "insert com aspas")
        #expect(erros("CREATE INDEX idx_p ON p(nome);") == "", "índice")
        #expect(erros("CREATE TABLE p (a TEXT NOT NULL DEFAULT '');") == "", "default")
        #expect(erros("SELECT a, COUNT(*) FROM p GROUP BY a HAVING COUNT(*) > 1;") == "", "group by")
        #expect(erros("PRAGMA foreign_keys = ON;") == "", "pragma")
    }

    /// O arquivo que estava aberto no iPad, do jeito que ele é.
    @Test func esquemaDeVerdadeNaoEhAcusado() {
        #expect(erros("""
        PRAGMA foreign_keys = ON;

        BEGIN TRANSACTION;
        CREATE TABLE pecas (
          id     TEXT PRIMARY KEY,
          nome   TEXT NOT NULL,
          preco  REAL NOT NULL,
          estoque INTEGER NOT NULL
        );
        INSERT INTO "pecas" VALUES('01','Tigela funda',128.0,7);
        CREATE TABLE pedidos (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          peca    TEXT REFERENCES pecas(id),
          cliente TEXT NOT NULL
        );
        COMMIT;
        """) == "")
    }

    /// E erro de verdade continua sendo erro — apagar o que a gramática não conhece não
    /// pode virar desculpa para calar o arquivo inteiro.
    @Test func erroDeVerdadeContinuaAcusado() {
        #expect(erros("CREATE TABLE p (id INTEGER") != "", "faltou fechar")
        #expect(
            erros("CREATE TABLE p (id INTEGER PRIMARY KEY AUTOINCREMENT;") != "",
            "falta o parêntese, mesmo com a palavra apagada"
        )
    }
}
