import Foundation
import OdeteI18n

/// Uma linha de shell: lista de pipelines ligados por `&&`, `||` ou `;`.
public struct CommandLine: Equatable, Sendable {
    public enum Link: Equatable, Sendable { case always, andThen, orElse }
    public struct Pipeline: Equatable, Sendable {
        public var commands: [Simple]
        public var background: Bool
    }

    public struct Simple: Equatable, Sendable {
        public var argv: [String]
        public var stdinFile: String?
        public var stdoutFile: String?
        public var append: Bool
        public var stderrToStdout: Bool
        public init(
            argv: [String],
            stdinFile: String? = nil,
            stdoutFile: String? = nil,
            append: Bool = false,
            stderrToStdout: Bool = false
        ) {
            self.argv = argv; self.stdinFile = stdinFile; self.stdoutFile = stdoutFile; self.append = append; self
                .stderrToStdout = stderrToStdout
        }
    }

    public var items: [(link: Link, pipeline: Pipeline)]

    public static func == (a: CommandLine, b: CommandLine) -> Bool {
        a.items.count == b.items.count && zip(a.items, b.items)
            .allSatisfy { $0.link == $1.link && $0.pipeline == $1.pipeline }
    }
}

public enum ParseError: LocalizedError, Equatable {
    case unterminatedQuote, unexpected(String), emptyCommand
    /// `$(…)` e crases. Antes o `$(` passava como texto: um `git commit -m "$(cat
    /// <<'EOF' … EOF)"` — que é como todo agente escreve mensagem de várias linhas —
    /// virava um commit com essa sopa de caracteres na mensagem, sem um aviso sequer.
    case semSubstituicao
    /// `<<'EOF'`, pelo mesmo motivo.
    case semHeredoc

    public var errorDescription: String? {
        switch self {
        case .unterminatedQuote: "aspas sem fechar"
        case let .unexpected(t): "inesperado: \(t)"
        case .emptyCommand: "comando vazio"
        case .semSubstituicao: "não tenho substituição de comando ($(…) nem crase): "
            + tr("rode o comando antes e passe a saída na mão")
        case .semHeredoc: "não tenho heredoc (<<): para mensagem de várias linhas, "
            + tr("repita -m uma vez por parágrafo")
        }
    }
}

/// Uma palavra da linha antes da expansão: pedaços de texto e referências a variáveis,
/// na ordem em que apareceram.
///
/// O shell expandia a linha inteira antes de rodar o primeiro comando. Em
/// `npx vitest run; echo fim $?` o `$?` nem era reconhecido, mas mesmo reconhecido valeria
/// o de antes da linha — e um `export X=1; echo $X` mostrava o `X` velho. Guardando a
/// palavra crua, cada pipeline se expande logo antes de rodar, como no sh.
struct Palavra: Equatable, Sendable {
    enum Pedaco: Equatable, Sendable {
        case texto(String)
        case variavel(String)
    }

    var pedacos: [Pedaco] = []

    /// A palavra com cada variável trocada pelo valor que `valor` der agora.
    func expandida(_ valor: (String) -> String) -> String {
        var s = ""
        for p in pedacos {
            switch p {
            case let .texto(t): s += t
            case let .variavel(nome): s += valor(nome)
            }
        }
        return s
    }
}

/// A linha já conferida e separada em pipelines, com as palavras ainda por expandir.
struct LinhaCrua: Sendable {
    struct Simples: Sendable {
        var argv: [Palavra] = []
        var stdinFile: Palavra?
        var stdoutFile: Palavra?
        var append = false
        var stderrToStdout = false

        func expandido(_ valor: (String) -> String) -> CommandLine.Simple {
            CommandLine.Simple(
                argv: argv.map { $0.expandida(valor) },
                stdinFile: stdinFile?.expandida(valor),
                stdoutFile: stdoutFile?.expandida(valor),
                append: append,
                stderrToStdout: stderrToStdout
            )
        }
    }

    struct Pipeline: Sendable {
        var commands: [Simples]
        var background: Bool

        func expandido(_ valor: (String) -> String) -> CommandLine.Pipeline {
            CommandLine.Pipeline(commands: commands.map { $0.expandido(valor) }, background: background)
        }
    }

    var items: [(link: CommandLine.Link, pipeline: Pipeline)]
}

public enum Parser {
    enum Token: Equatable { case word(Palavra), op(String) }

    /// Tokeniza com aspas simples/duplas e escapes. `$VAR`, `${VAR}` e os especiais
    /// (`$?`, `$$`, `$#`, `$0`) ficam anotados na palavra, sem valor: quem expande é
    /// quem roda, pipeline a pipeline.
    static func tokenize(_ line: String) throws -> [Token] {
        var out: [Token] = []
        var palavra = Palavra()
        var cur = "" // texto literal que ainda não foi para `palavra`
        var hasWord = false
        var i = line.startIndex
        func fecharTexto() {
            if !cur.isEmpty {
                palavra.pedacos.append(.texto(cur)); cur = ""
            }
        }
        func flush() {
            if hasWord {
                fecharTexto()
                out.append(.word(palavra)); palavra = Palavra(); hasWord = false
            }
        }
        /// O nome da variável cujo `$` está em `from`, deixando `from` no último caractere
        /// dela; nil quando o `$` é só um cifrão.
        func variavel(_ from: inout String.Index) throws -> String? {
            let j = line.index(after: from)
            guard j < line.endIndex else { return nil }
            let c = line[j]
            if c == "(" {
                throw ParseError.semSubstituicao
            }
            if c == "{", let close = line[j...].firstIndex(of: "}") {
                from = close
                return String(line[line.index(after: j) ..< close])
            }
            // Especiais e posicionais têm um caractere só, como no sh: `$?x` é o código
            // seguido de "x", e `$10` é `$1` seguido de "0".
            if c == "?" || c == "$" || c == "#" || (c.isASCII && c.isNumber) {
                from = j
                return String(c)
            }
            var k = j
            var name = ""
            while k < line.endIndex, line[k].isLetter || line[k].isNumber || line[k] == "_" {
                name.append(line[k]); k = line.index(after: k)
            }
            if name.isEmpty {
                return nil
            }
            from = line.index(before: k)
            return name
        }
        func dolar(_ from: inout String.Index) throws {
            if let nome = try variavel(&from) {
                fecharTexto(); palavra.pedacos.append(.variavel(nome))
            } else {
                cur.append("$")
            }
        }
        while i < line.endIndex {
            let c = line[i]
            switch c {
            case "'":
                guard let close = line[line.index(after: i)...].firstIndex(of: "'")
                else { throw ParseError.unterminatedQuote }
                cur += line[line.index(after: i) ..< close]; hasWord = true; i = close
            case "\"":
                var j = line.index(after: i)
                var closed = false
                while j < line.endIndex {
                    let d = line[j]
                    if d == "\\", line.index(after: j) < line.endIndex {
                        j = line.index(after: j); cur.append(line[j])
                    } else if d == "$" {
                        try dolar(&j)
                    } else if d == "\"" {
                        closed = true; break
                    } else {
                        cur.append(d)
                    }
                    j = line.index(after: j)
                }
                guard closed else { throw ParseError.unterminatedQuote }
                hasWord = true; i = j
            case "\\":
                let n = line.index(after: i)
                if n < line.endIndex {
                    cur.append(line[n]); hasWord = true; i = n
                }
            case "$": try dolar(&i); hasWord = true
            case "`": throw ParseError.semSubstituicao
            case " ", "\t": flush()
            case "#" where !hasWord: i = line.endIndex; continue
            case "|", "&", ";", ">", "<":
                flush()
                let n = line.index(after: i)
                if c == "<", n < line.endIndex, line[n] == "<" {
                    throw ParseError.semHeredoc
                }
                if n < line.endIndex, line[n] == c,
                   c == "|" || c == "&" || c == ">"
                {
                    out.append(.op(String(c) + String(c))); i = n
                } else if c == "2", false {}
                else {
                    out.append(.op(String(c)))
                }
            default:
                // 2> e 2>&1
                if c == "2", !hasWord, line.index(after: i) < line.endIndex, line[line.index(after: i)] == ">" {
                    let rest = line[line.index(after: i)...]
                    if rest.hasPrefix(">&1") {
                        out.append(.op("2>&1")); i = line.index(i, offsetBy: 3)
                    } else {
                        out.append(.op("2>")); i = line.index(after: i)
                    }
                } else {
                    cur.append(c); hasWord = true
                }
            }
            i = line.index(after: i)
        }
        flush()
        return out
    }

    /// A linha inteira expandida de uma vez com `env`. O shell não usa isto — ver
    /// `separar` —, mas é o jeito direto de ver o que uma linha vira.
    public static func parse(_ line: String, env: [String: String] = [:]) throws -> CommandLine {
        let crua = try separar(line)
        return CommandLine(items: crua.items.map { item in
            (item.link, item.pipeline.expandido { env[$0] ?? "" })
        })
    }

    /// Confere a linha toda (aspas, `$(…)`, heredoc, `|` solto) antes de rodar qualquer
    /// coisa e a separa em pipelines, sem expandir nada.
    static func separar(_ line: String) throws -> LinhaCrua {
        let tokens = try tokenize(line)
        var items: [(link: CommandLine.Link, pipeline: LinhaCrua.Pipeline)] = []
        var link: CommandLine.Link = .always
        var commands: [LinhaCrua.Simples] = []
        var cur = LinhaCrua.Simples()
        var i = 0
        func endSimple() throws {
            guard !cur.argv.isEmpty else { throw ParseError.emptyCommand }
            commands.append(cur); cur = LinhaCrua.Simples()
        }
        func endPipeline(background: Bool) throws {
            // fim vazio (linha em branco, `;` ou `&` no final) é permitido; `a |` não é
            if cur.argv.isEmpty, commands.isEmpty {
                return
            }
            try endSimple()
            if !commands
                .isEmpty
            {
                items.append((link, LinhaCrua.Pipeline(commands: commands, background: background)))
            }
            commands = []
        }
        while i < tokens.count {
            switch tokens[i] {
            case let .word(w): cur.argv.append(w)
            case let .op(o):
                switch o {
                case "|": try endSimple()
                case "||": try endPipeline(background: false); link = .orElse
                case "&&": try endPipeline(background: false); link = .andThen
                case ";": try endPipeline(background: false); link = .always
                case "&": try endPipeline(background: true); link = .always
                case ">", ">>", "2>":
                    guard i + 1 < tokens.count,
                          case let .word(f) = tokens[i + 1] else { throw ParseError.unexpected(o) }
                    if o == "2>" {
                        cur.stderrToStdout = false
                    } else {
                        cur.stdoutFile = f; cur.append = o == ">>"
                    }
                    i += 1
                case "<":
                    guard i + 1 < tokens.count,
                          case let .word(f) = tokens[i + 1] else { throw ParseError.unexpected(o) }
                    cur.stdinFile = f; i += 1
                case "2>&1": cur.stderrToStdout = true
                default: throw ParseError.unexpected(o)
                }
            }
            i += 1
        }
        try endPipeline(background: false)
        return LinhaCrua(items: items)
    }
}
