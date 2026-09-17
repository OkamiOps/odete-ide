import OdeteCore
import OdeteI18n
import TreeSitter
import TreeSitterPython

/// Nome usado que não foi declarado em lugar nenhum — o `NameError` antes de rodar.
///
/// Esta é a parte do interpretador que não é sintaxe: a sintaxe pergunta "isto está bem
/// escrito?", isto aqui pergunta "isto existe?". Em Python a pergunta tem resposta sem
/// compilador, porque o módulo é plano: tudo que existe foi ligado a um nome em algum
/// lugar do arquivo, ou importado, ou é embutido na linguagem.
///
/// A leitura é de propósito **sem escopo**: um nome ligado em qualquer ponto do arquivo
/// conta como existente em todos. Isso deixa passar o erro de usar antes de definir
/// dentro de uma função, e em troca não acusa nada por não entender um escopo — que é o
/// tipo de engano que faria a pessoa desligar o painel de problemas. Entre deixar passar
/// e inventar, deixa passar.
///
/// Só Python. Em Rust, Java ou Go a maior parte dos nomes vem de outros arquivos e de
/// pacotes que a Odete não lê, e a mesma conta daria falso a cada linha.
public enum ResolvePython {
    public static let teto = 30

    public nonisolated static func problemas(text: String) -> [LintIssue] {
        guard let lang = ParserErros.gramatica(.python), let parser = ts_parser_new() else { return [] }
        defer { ts_parser_delete(parser) }
        guard ts_parser_set_language(parser, lang) else { return [] }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return [] }
        let arvore = bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress.flatMap { base in
                base.withMemoryRebound(to: CChar.self, capacity: buf.count) { c in
                    ts_parser_parse_string(parser, nil, c, UInt32(buf.count))
                }
            }
        }
        guard let arvore else { return [] }
        defer { ts_tree_delete(arvore) }
        let raiz = ts_tree_root_node(arvore)
        // Com erro de sintaxe a árvore é um chute: os nomes saem trocados e o recado
        // viraria ruído em cima de um erro que a pessoa já está vendo.
        guard !ts_node_has_error(raiz) else { return [] }

        var ligados = Set<String>()
        var posicoesLigadas = Set<UInt32>()
        var importados: [(nome: String, inicio: UInt32, linha: Int, coluna: Int)] = []
        colheLigacoes(raiz, bytes, &ligados, &posicoesLigadas, &importados)

        var leitura = Leitura(bytes: bytes, ligados: ligados, posicoes: posicoesLigadas)
        colheUsos(raiz, &leitura)
        var out = leitura.achados

        // Import que ninguém usa: a outra metade da mesma leitura, e de graça.
        for i in importados where !leitura.usados.contains(i.nome) {
            out.append(LintIssue(
                rule: "import-sem-uso",
                message: tr("`%1$@` é importado e não é usado", i.nome),
                severity: .warning,
                line: i.linha,
                column: i.coluna,
                length: i.nome.count
            ))
        }
        return Array(out.sorted { ($0.line, $0.column) < ($1.line, $1.column) }.prefix(teto))
    }

    // MARK: - o que liga um nome

    private nonisolated static func texto(_ node: TSNode, _ bytes: [UInt8]) -> String {
        let ini = Int(ts_node_start_byte(node)), fim = Int(ts_node_end_byte(node))
        guard ini < fim, fim <= bytes.count else { return "" }
        return String(decoding: bytes[ini ..< fim], as: UTF8.self)
    }

    private nonisolated static func tipo(_ node: TSNode) -> String {
        ts_node_type(node).map { String(cString: $0) } ?? ""
    }

    private nonisolated static func campo(_ node: TSNode, _ nome: String) -> TSNode? {
        let filho = nome.withCString { ts_node_child_by_field_name(node, $0, UInt32(nome.utf8.count)) }
        return ts_node_is_null(filho) ? nil : filho
    }

    /// Marca como ligado todo identificador dentro de um alvo de atribuição: cobre
    /// `a = 1`, `a, b = f()`, `[a, b] = xs` e `for a, b in …` de uma vez.
    private nonisolated static func liga(
        _ node: TSNode,
        _ bytes: [UInt8],
        _ ligados: inout Set<String>,
        _ posicoes: inout Set<UInt32>
    ) {
        let t = tipo(node)
        if t == "identifier" {
            ligados.insert(texto(node, bytes))
            posicoes.insert(ts_node_start_byte(node))
            return
        }
        // `obj.attr = 1` e `xs[0] = 1` não ligam nome novo: o que aparece ali já tem que
        // existir, e é o uso que confere isso.
        if t == "attribute" || t == "subscript" {
            return
        }
        for i in 0 ..< ts_node_child_count(node) {
            liga(ts_node_child(node, i), bytes, &ligados, &posicoes)
        }
    }

    private nonisolated static func colheLigacoes(
        _ node: TSNode,
        _ bytes: [UInt8],
        _ ligados: inout Set<String>,
        _ posicoes: inout Set<UInt32>,
        _ importados: inout [(nome: String, inicio: UInt32, linha: Int, coluna: Int)]
    ) {
        switch tipo(node) {
        case "function_definition", "class_definition":
            if let n = campo(node, "name") {
                liga(n, bytes, &ligados, &posicoes)
            }
        case "parameters", "lambda_parameters":
            for i in 0 ..< ts_node_child_count(node) {
                let f = ts_node_child(node, i)
                switch tipo(f) {
                case "identifier":
                    liga(f, bytes, &ligados, &posicoes)
                case "list_splat_pattern", "dictionary_splat_pattern":
                    // `*args` e `**kwargs`: o primeiro filho é o `*`, o nome vem depois.
                    liga(f, bytes, &ligados, &posicoes)
                case "typed_parameter", "default_parameter", "typed_default_parameter":
                    // O valor padrão é uso, não ligação: só o nome do parâmetro liga.
                    if let n = campo(f, "name") {
                        liga(n, bytes, &ligados, &posicoes)
                    } else if ts_node_child_count(f) > 0 {
                        liga(ts_node_child(f, 0), bytes, &ligados, &posicoes)
                    }
                default:
                    break
                }
            }
        case "assignment", "augmented_assignment":
            if let e = campo(node, "left") {
                liga(e, bytes, &ligados, &posicoes)
            }
        case "named_expression":
            if let n = campo(node, "name") {
                liga(n, bytes, &ligados, &posicoes)
            }
        case "for_statement", "for_in_clause":
            if let e = campo(node, "left") {
                liga(e, bytes, &ligados, &posicoes)
            }
        case "as_pattern":
            // `with open() as f`, `except E as e`, `import x as y`.
            if let alias = campo(node, "alias") {
                liga(alias, bytes, &ligados, &posicoes)
            } else if ts_node_child_count(node) > 1 {
                liga(ts_node_child(node, ts_node_child_count(node) - 1), bytes, &ligados, &posicoes)
            }
        case "global_statement", "nonlocal_statement":
            for i in 0 ..< ts_node_child_count(node) {
                liga(ts_node_child(node, i), bytes, &ligados, &posicoes)
            }
        case "import_statement", "import_from_statement", "future_import_statement":
            colheImport(node, bytes, &ligados, &posicoes, &importados)
            return
        default:
            break
        }
        for i in 0 ..< ts_node_child_count(node) {
            colheLigacoes(ts_node_child(node, i), bytes, &ligados, &posicoes, &importados)
        }
    }

    /// `import a.b` liga `a`; `import a.b as c` liga `c`; `from a import b, c as d` liga
    /// `b` e `d`; `from a import *` desliga a checagem, porque aí tudo pode existir.
    private nonisolated static func colheImport(
        _ node: TSNode,
        _ bytes: [UInt8],
        _ ligados: inout Set<String>,
        _ posicoes: inout Set<UInt32>,
        _ importados: inout [(nome: String, inicio: UInt32, linha: Int, coluna: Int)]
    ) {
        let deOnde = campo(node, "module_name")
        for i in 0 ..< ts_node_child_count(node) {
            let f = ts_node_child(node, i)
            if let deOnde, ts_node_eq(f, deOnde) {
                continue
            }
            switch tipo(f) {
            case "wildcard_import":
                // `from x import *`: o que entrou é desconhecido, então nada mais é
                // "não declarado" neste arquivo. Melhor calar do que acusar errado.
                ligados.insert(Self.tudoPode)
            case "dotted_name":
                guard let primeiro = ts_node_child_count(f) > 0 ? ts_node_child(f, 0) : nil else { continue }
                let nome = texto(primeiro, bytes)
                ligados.insert(nome)
                posicoes.insert(ts_node_start_byte(primeiro))
                registra(nome, primeiro, &importados)
            case "aliased_import":
                guard let alias = campo(f, "alias") else { continue }
                let nome = texto(alias, bytes)
                ligados.insert(nome)
                posicoes.insert(ts_node_start_byte(alias))
                registra(nome, alias, &importados)
            case "identifier":
                let nome = texto(f, bytes)
                ligados.insert(nome)
                posicoes.insert(ts_node_start_byte(f))
                registra(nome, f, &importados)
            default:
                break
            }
        }
    }

    private nonisolated static func registra(
        _ nome: String,
        _ node: TSNode,
        _ importados: inout [(nome: String, inicio: UInt32, linha: Int, coluna: Int)]
    ) {
        let p = ts_node_start_point(node)
        importados.append((nome, ts_node_start_byte(node), Int(p.row) + 1, Int(p.column) + 1))
    }

    /// Marca de "não dá para saber", vinda de `from x import *`.
    static let tudoPode = "*"

    // MARK: - o que usa um nome

    /// O que a leitura de usos precisa carregar. Junto num tipo porque passar seis
    /// coisas soltas por uma recursão é como se perde o fio.
    struct Leitura {
        var bytes: [UInt8]
        var ligados: Set<String>
        var posicoes: Set<UInt32>
        var usados = Set<String>()
        var achados: [LintIssue] = []
    }

    private nonisolated static func colheUsos(_ node: TSNode, _ l: inout Leitura) {
        let bytes = l.bytes
        // A linha de import não tem uso nenhum: `from pathlib import Path` fala de um
        // pacote lá fora, não de um nome deste arquivo. Sem isto, `pathlib` virava "não
        // declarado" — e, pior, `Path` contava como usado e o aviso de import sem uso
        // nunca disparava.
        let t = tipo(node)
        if t == "import_statement" || t == "import_from_statement" || t == "future_import_statement" {
            return
        }
        if t == "identifier" {
            let nome = texto(node, bytes)
            l.usados.insert(nome)
            guard !l.posicoes.contains(ts_node_start_byte(node)),
                  !l.ligados.contains(nome),
                  !l.ligados.contains(Self.tudoPode),
                  !embutidos.contains(nome)
            else { return }
            let p = ts_node_start_point(node)
            l.achados.append(LintIssue(
                rule: "nome-nao-declarado",
                message: tr("`%1$@` não foi declarado neste arquivo", nome),
                severity: .error,
                line: Int(p.row) + 1,
                column: Int(p.column) + 1,
                length: nome.count
            ))
            return
        }
        // `obj.attr`: só `obj` é nome deste arquivo. O `attr` vem do objeto, e a Odete
        // não sabe o que ele tem.
        if t == "attribute" {
            if let alvo = campo(node, "object") {
                colheUsos(alvo, &l)
            }
            return
        }
        // `f(nome=1)`: `nome` é o parâmetro de quem recebe, não um nome daqui.
        if t == "keyword_argument" {
            if let valor = campo(node, "value") {
                colheUsos(valor, &l)
            }
            return
        }
        for i in 0 ..< ts_node_child_count(node) {
            colheUsos(ts_node_child(node, i), &l)
        }
    }

    /// Embutidos da linguagem. Faltar um aqui é acusar código certo, então a lista é
    /// larga de propósito — inclui o que vem do runtime (`__name__`) e as exceções.
    static let embutidos: Set<String> = [
        "abs", "aiter", "all", "anext", "any", "ascii", "bin", "bool", "breakpoint",
        "bytearray", "bytes", "callable", "chr", "classmethod", "compile", "complex",
        "delattr", "dict", "dir", "divmod", "enumerate", "eval", "exec", "filter", "float",
        "format", "frozenset", "getattr", "globals", "hasattr", "hash", "help", "hex", "id",
        "input", "int", "isinstance", "issubclass", "iter", "len", "list", "locals", "map",
        "max", "memoryview", "min", "next", "object", "oct", "open", "ord", "pow", "print",
        "property", "range", "repr", "reversed", "round", "set", "setattr", "slice",
        "sorted", "staticmethod", "str", "sum", "super", "tuple", "type", "vars", "zip",
        "True", "False", "None", "NotImplemented", "Ellipsis", "self", "cls",
        "__name__", "__file__", "__doc__", "__package__", "__spec__", "__loader__",
        "__builtins__", "__debug__", "__import__", "__init__", "__main__",
        "BaseException", "Exception", "ArithmeticError", "AssertionError", "AttributeError",
        "BlockingIOError", "BrokenPipeError", "BufferError", "BytesWarning",
        "ChildProcessError", "ConnectionError", "ConnectionAbortedError",
        "ConnectionRefusedError", "ConnectionResetError", "DeprecationWarning", "EOFError",
        "EnvironmentError", "FileExistsError", "FileNotFoundError", "FloatingPointError",
        "FutureWarning", "GeneratorExit", "IOError", "ImportError", "ImportWarning",
        "IndentationError", "IndexError", "InterruptedError", "IsADirectoryError",
        "KeyError", "KeyboardInterrupt", "LookupError", "MemoryError", "ModuleNotFoundError",
        "NameError", "NotADirectoryError", "NotImplementedError", "OSError", "OverflowError",
        "PendingDeprecationWarning", "PermissionError", "ProcessLookupError", "RecursionError",
        "ReferenceError", "ResourceWarning", "RuntimeError", "RuntimeWarning", "StopAsyncIteration",
        "StopIteration", "SyntaxError", "SyntaxWarning", "SystemError", "SystemExit",
        "TabError", "TimeoutError", "TypeError", "UnboundLocalError", "UnicodeDecodeError",
        "UnicodeEncodeError", "UnicodeError", "UnicodeTranslateError", "UnicodeWarning",
        "UserWarning", "ValueError", "Warning", "ZeroDivisionError",
    ]
}
