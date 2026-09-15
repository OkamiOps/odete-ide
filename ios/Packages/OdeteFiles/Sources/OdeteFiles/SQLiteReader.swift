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
    /// `rowid` de cada linha, para saber qual atualizar. Vazio quando a tabela não tem
    /// (tabela `WITHOUT ROWID` ou view): aí não dá para editar.
    public var ids: [Int64]

    public var editavel: Bool {
        ids.count == linhas.count && !linhas.isEmpty
    }

    public init(colunas: [String] = [], linhas: [[String]] = [], total: Int = 0, ids: [Int64] = []) {
        self.colunas = colunas
        self.linhas = linhas
        self.total = total
        self.ids = ids
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

    /// Se este banco aceita escrita. Em disco só quando pedido; o dump `.sql` sempre,
    /// porque ali a edição acontece em memória e volta como texto.
    public private(set) var editavel = false

    /// Banco em disco. `escrita` só quando a pessoa pede para editar.
    public init(arquivo: URL, escrita: Bool = false) throws {
        var ponteiro: OpaquePointer?
        let flags = (escrita ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_NOMUTEX
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
        editavel = escrita
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
        editavel = true
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
        // Com o rowid junto dá para editar a linha certa mesmo sem chave primária; sem
        // ele (view, tabela `WITHOUT ROWID`) a tabela ainda é mostrada, só não editada.
        var p = consultar("SELECT rowid, * FROM \(citar(tabela)) LIMIT \(limite) OFFSET \(offset)")
        if p.colunas.first == "rowid" {
            p.ids = p.linhas.map { Int64($0.first ?? "") ?? 0 }
            p.colunas.removeFirst()
            p.linhas = p.linhas.map { Array($0.dropFirst()) }
        } else {
            p = consultar("SELECT * FROM \(citar(tabela)) LIMIT \(limite) OFFSET \(offset)")
        }
        p.total = contar(tabela)
        return p
    }

    /// Nome de tabela entre aspas duplas, com as internas dobradas: nome com espaço ou
    /// palavra reservada quebraria a consulta.
    private func citar(_ nome: String) -> String {
        "\"" + nome.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: escrever

    /// Roda um comando que muda o banco. Devolve o erro do SQLite, se houver.
    @discardableResult
    public func executar(_ sql: String, _ valores: [String?] = []) -> String? {
        guard let db, editavel else { return "banco aberto só para leitura" }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            return String(cString: sqlite3_errmsg(db))
        }
        defer { sqlite3_finalize(st) }
        for (i, v) in valores.enumerated() {
            if let v {
                sqlite3_bind_text(st, Int32(i + 1), v, -1, Self.transiente)
            } else {
                sqlite3_bind_null(st, Int32(i + 1))
            }
        }
        guard sqlite3_step(st) == SQLITE_DONE else { return String(cString: sqlite3_errmsg(db)) }
        return nil
    }

    /// `sqlite3_bind_text` sem isto guarda o ponteiro do Swift, que já morreu na hora do
    /// `step`; `SQLITE_TRANSIENT` manda o SQLite copiar.
    private static let transiente = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Nome de coluna citado, como o de tabela.
    public func citarNome(_ n: String) -> String {
        citar(n)
    }

    /// Uma coluna da tabela, com o que é preciso saber para inserir uma linha.
    public struct Coluna: Sendable, Hashable {
        public var nome: String
        public var tipo: String
        public var obrigatoria: Bool
        public var temPadrao: Bool
        public var pk: Bool

        /// Valor de partida para uma linha nova: vazio para texto, zero para número.
        public var valorInicial: String {
            let t = tipo.uppercased()
            if t.contains("INT") || t.contains("REAL") || t.contains("FLOA") || t.contains("DOUB")
                || t.contains("NUM") || t.contains("DEC")
            {
                return "0"
            }
            return ""
        }
    }

    /// As colunas da tabela, do `PRAGMA table_info`.
    public func colunas(_ tabela: String) -> [Coluna] {
        consultar("PRAGMA table_info(\(citar(tabela)))").linhas.compactMap { l in
            guard l.count >= 6 else { return nil }
            return Coluna(nome: l[1], tipo: l[2], obrigatoria: l[3] != "0", temPadrao: !l[4].isEmpty, pk: l[5] != "0")
        }
    }

    /// Insere uma linha preenchendo só o que o banco exige.
    ///
    /// `INSERT ... DEFAULT VALUES` falha em qualquer tabela com coluna `NOT NULL` sem
    /// padrão, que é a maioria — e "não deu" não é resposta para quem clicou em "nova
    /// linha". As obrigatórias entram com um valor de partida, o resto fica com o padrão.
    public func inserirLinha(_ tabela: String) -> String? {
        let cols = colunas(tabela).filter { $0.obrigatoria && !$0.temPadrao }
        guard !cols.isEmpty else { return executar("INSERT INTO \(citar(tabela)) DEFAULT VALUES") }
        let nomes = cols.map { citar($0.nome) }.joined(separator: ", ")
        let marcas = Array(repeating: "?", count: cols.count).joined(separator: ", ")
        return executar(
            "INSERT INTO \(citar(tabela)) (\(nomes)) VALUES (\(marcas))",
            cols.map(\.valorInicial)
        )
    }

    /// O banco inteiro de volta como SQL, que é o formato de um `.sql`.
    public func dump() -> String {
        var out = "BEGIN TRANSACTION;\n"
        let objetos = consultar(
            "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY rowid"
        )
        for o in objetos.linhas where o.count >= 3 {
            out += o[2] + ";\n"
            guard o[0] == "table" else { continue }
            // `quote()` do próprio SQLite escreve o literal certo para cada valor: número
            // sem aspas, texto com as aspas dobradas, NULL como NULL, blob como X''. Com
            // aspas postas na mão, um REAL voltava do dump como texto.
            let cols = colunas(o[1]).map { "quote(\(citar($0.nome)))" }
            guard !cols.isEmpty else { continue }
            let p = consultar("SELECT \(cols.joined(separator: ", ")) FROM \(citar(o[1]))")
            for linha in p.linhas {
                out += "INSERT INTO \(citar(o[1])) VALUES(\(linha.joined(separator: ",")));\n"
            }
        }
        return out + "COMMIT;\n"
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
