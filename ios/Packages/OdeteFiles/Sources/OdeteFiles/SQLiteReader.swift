import Foundation
import SQLite3

/// Uma tabela do banco e quantas linhas ela tem.
public struct DBTable: Sendable, Hashable, Identifiable {
    public var nome: String
    public var linhas: Int
    public var id: String {
        nome
    }
}

/// Um pedaço de tabela, já em texto, pronto para desenhar.
public struct DBPage: Sendable, Hashable {
    public var colunas: [String]
    public var linhas: [[String]]
    public var total: Int

    public init(colunas: [String] = [], linhas: [[String]] = [], total: Int = 0) {
        self.colunas = colunas
        self.linhas = linhas
        self.total = total
    }
}

/// Lê um banco SQLite só para mostrar.
///
/// Abre sempre em modo leitura: um banco do projeto aberto por engano no editor não pode
/// sair estragado, que é justamente o que acontecia quando arquivo binário virava texto.
/// Também serve para um dump `.sql`, carregado num banco em memória.
public final class SQLiteReader: @unchecked Sendable {
    private var db: OpaquePointer?

    public enum Falha: LocalizedError {
        case naoAbriu(String)
        public var errorDescription: String? {
            switch self {
            case let .naoAbriu(m): m
            }
        }
    }

    /// Banco em disco, só leitura.
    public init(arquivo: URL) throws {
        var ponteiro: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(arquivo.path, &ponteiro, flags, nil) == SQLITE_OK, let ponteiro else {
            let msg = ponteiro.map { String(cString: sqlite3_errmsg($0)) } ?? "não é um banco SQLite"
            sqlite3_close(ponteiro)
            throw Falha.naoAbriu(msg)
        }
        db = ponteiro
        // `open` é preguiçoso e não olha o conteúdo: só uma consulta de verdade revela que
        // o arquivo não é um banco. Sem isto, qualquer binário "abria" e vinha vazio.
        guard sqlite3_exec(ponteiro, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(ponteiro)
            db = nil
            throw Falha.naoAbriu("não é um banco SQLite")
        }
    }

    /// Dump `.sql` executado num banco em memória, para ver o mesmo em forma de tabela.
    public init(script: String) throws {
        var ponteiro: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &ponteiro, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let ponteiro else { throw Falha.naoAbriu("não consegui abrir um banco em memória") }
        db = ponteiro
        var erro: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(ponteiro, script, nil, nil, &erro) != SQLITE_OK {
            let msg = erro.map { String(cString: $0) } ?? "SQL inválido"
            sqlite3_free(erro)
            sqlite3_close(ponteiro)
            db = nil
            throw Falha.naoAbriu(msg)
        }
    }

    deinit { sqlite3_close(db) }

    public func tabelas() -> [DBTable] {
        let nomes = consultar(
            "SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).linhas.compactMap(\.first)
        return nomes.map { DBTable(nome: $0, linhas: contar($0)) }
    }

    public func contar(_ tabela: String) -> Int {
        Int(consultar("SELECT count(*) FROM \(citar(tabela))").linhas.first?.first ?? "") ?? 0
    }

    /// Uma página de linhas. Sem `LIMIT` uma tabela grande viraria memória à toa.
    public func pagina(_ tabela: String, limite: Int = 200, offset: Int = 0) -> DBPage {
        var p = consultar("SELECT * FROM \(citar(tabela)) LIMIT \(limite) OFFSET \(offset)")
        p.total = contar(tabela)
        return p
    }

    /// Nome de tabela entre aspas duplas, com as internas dobradas: nome com espaço ou
    /// palavra reservada quebraria a consulta.
    private func citar(_ nome: String) -> String {
        "\"" + nome.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public func consultar(_ sql: String) -> DBPage {
        guard let db else { return DBPage() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return DBPage() }
        defer { sqlite3_finalize(st) }
        let n = Int(sqlite3_column_count(st))
        let colunas = (0 ..< n).map { String(cString: sqlite3_column_name(st, Int32($0))) }
        var linhas: [[String]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            linhas.append((0 ..< n).map { celula(st, Int32($0)) })
        }
        return DBPage(colunas: colunas, linhas: linhas, total: linhas.count)
    }

    /// Valor já em texto. `NULL` vira vazio e blob vira o tamanho: mostrar bytes crus numa
    /// célula não ajuda ninguém.
    private func celula(_ st: OpaquePointer, _ i: Int32) -> String {
        switch sqlite3_column_type(st, i) {
        case SQLITE_NULL: ""
        case SQLITE_INTEGER: String(sqlite3_column_int64(st, i))
        case SQLITE_FLOAT: String(sqlite3_column_double(st, i))
        case SQLITE_BLOB: "⟨\(sqlite3_column_bytes(st, i)) bytes⟩"
        default: sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
        }
    }
}
