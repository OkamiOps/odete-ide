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

public enum Parser {
    enum Token: Equatable { case word(String), op(String) }

    /// Tokeniza com aspas simples/duplas, escapes e expansão de `$VAR`/`${VAR}`.
    static func tokenize(_ line: String, env: [String: String]) throws -> [Token] {
        var out: [Token] = []
        var cur = ""
        var hasWord = false
        var i = line.startIndex
        func flush() {
            if hasWord {
                out.append(.word(cur)); cur = ""; hasWord = false
            }
        }
        func expand(_ from: inout String.Index) throws -> String {
            var j = line.index(after: from)
            if j < line.endIndex, line[j] == "(" {
                throw ParseError.semSubstituicao
            }
            if j < line.endIndex, line[j] == "{" {
                if let close = line[j...]
                    .firstIndex(of: "}")
                {
                    let name = String(line[line.index(after: j) ..< close]); from = close; return env[name] ?? ""
                }
            }
            var name = ""
            while j < line.endIndex,
                  line[j].isLetter || line[j]
                  .isNumber || line[j] == "_"
            {
                name.append(line[j]); j = line.index(after: j)
            }
            if name.isEmpty {
                return "$"
            }
            from = line.index(before: j)
            return env[name] ?? ""
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
                        cur += try expand(&j)
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
            case "$": cur += try expand(&i); hasWord = true
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

    public static func parse(_ line: String, env: [String: String] = [:]) throws -> CommandLine {
        let tokens = try tokenize(line, env: env)
        var items: [(link: CommandLine.Link, pipeline: CommandLine.Pipeline)] = []
        var link: CommandLine.Link = .always
        var commands: [CommandLine.Simple] = []
        var cur = CommandLine.Simple(argv: [])
        var i = 0
        func endSimple() throws {
            guard !cur.argv.isEmpty else { throw ParseError.emptyCommand }
            commands.append(cur); cur = CommandLine.Simple(argv: [])
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
                items.append((link, CommandLine.Pipeline(commands: commands, background: background)))
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
        return CommandLine(items: items)
    }
}
