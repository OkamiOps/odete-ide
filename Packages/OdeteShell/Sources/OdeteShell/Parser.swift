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
        /// `2> arquivo` (`2>> arquivo` com `stderrAppend`). Antes o nome era jogado fora.
        public var stderrFile: String?
        public var stderrAppend: Bool
        /// `>&2`: o stdout vai para o stderr.
        public var stdoutToStderr: Bool
        public init(
            argv: [String],
            stdinFile: String? = nil,
            stdoutFile: String? = nil,
            append: Bool = false,
            stderrToStdout: Bool = false,
            stderrFile: String? = nil,
            stderrAppend: Bool = false,
            stdoutToStderr: Bool = false
        ) {
            self.argv = argv; self.stdinFile = stdinFile; self.stdoutFile = stdoutFile; self.append = append; self
                .stderrToStdout = stderrToStdout
            self.stderrFile = stderrFile; self.stderrAppend = stderrAppend; self.stdoutToStderr = stdoutToStderr
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
        /// Texto entre aspas ou escapado com `\`: nunca vira padrão de glob.
        case citado(String)
        case variavel(String)
    }

    var pedacos: [Pedaco] = []

    /// A palavra com cada variável trocada pelo valor que `valor` der agora.
    func expandida(_ valor: (String) -> String) -> String {
        var s = ""
        for p in pedacos {
            switch p {
            case let .texto(t), let .citado(t): s += t
            case let .variavel(nome): s += valor(nome)
            }
        }
        return s
    }

    /// O padrão de glob (para `fnmatch`), se a palavra tem `*`, `?` ou `[` fora de aspas; o
    /// que veio entre aspas ou de variável entra escapado. Nil quando não há o que expandir.
    func padraoDeGlob(_ valor: (String) -> String) -> String? {
        var temCuringa = false
        var s = ""
        func escapar(_ t: String) -> String {
            var r = ""
            for c in t {
                if c == "*" || c == "?" || c == "[" || c == "]" || c == "\\" {
                    r.append("\\")
                }
                r.append(c)
            }
            return r
        }
        for p in pedacos {
            switch p {
            case let .texto(t):
                if t.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" }) {
                    temCuringa = true
                }
                s += t
            case let .citado(t): s += escapar(t)
            case let .variavel(nome): s += escapar(valor(nome))
            }
        }
        return temCuringa ? s : nil
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
        var stderrFile: Palavra?
        var stderrAppend = false
        var stdoutToStderr = false

        /// `glob` recebe o padrão e devolve os caminhos que casam (vazio: fica o texto, como
        /// no sh).
        func expandido(_ valor: (String) -> String, glob: ((String) -> [String])? = nil) -> CommandLine.Simple {
            var args: [String] = []
            for p in argv {
                if let glob, let padrao = p.padraoDeGlob(valor) {
                    let achados = glob(padrao)
                    if !achados.isEmpty {
                        args.append(contentsOf: achados)
                        continue
                    }
                }
                args.append(p.expandida(valor))
            }
            return CommandLine.Simple(
                argv: args,
                stdinFile: stdinFile?.expandida(valor),
                stdoutFile: stdoutFile?.expandida(valor),
                append: append,
                stderrToStdout: stderrToStdout,
                stderrFile: stderrFile?.expandida(valor),
                stderrAppend: stderrAppend,
                stdoutToStderr: stdoutToStderr
            )
        }
    }

    struct Pipeline: Sendable {
        var commands: [Simples]
        var background: Bool

        func expandido(_ valor: (String) -> String, glob: ((String) -> [String])? = nil) -> CommandLine.Pipeline {
            CommandLine.Pipeline(commands: commands.map { $0.expandido(valor, glob: glob) }, background: background)
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
        var cur = "" // texto que ainda não foi para `palavra`
        var curCitado = false // `cur` veio de aspas/escape?
        var hasWord = false
        var i = line.startIndex
        func fecharTexto() {
            if !cur.isEmpty {
                palavra.pedacos.append(curCitado ? .citado(cur) : .texto(cur)); cur = ""
            }
        }
        func literal(_ t: some StringProtocol, citado: Bool) {
            if citado != curCitado {
                fecharTexto()
                curCitado = citado
            }
            cur += t
        }
        func flush() {
            if hasWord {
                fecharTexto()
                out.append(.word(palavra)); palavra = Palavra(); hasWord = false
            }
        }
        func proximo(_ k: Int) -> Character? {
            guard let j = line.index(i, offsetBy: k, limitedBy: line.endIndex), j < line.endIndex else { return nil }
            return line[j]
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
        func dolar(_ from: inout String.Index, citado: Bool) throws {
            if let nome = try variavel(&from) {
                fecharTexto(); palavra.pedacos.append(.variavel(nome))
            } else {
                literal("$", citado: citado)
            }
        }
        /// Um redirecionamento que começa em `i` (`>`, `>>`, `>&2`, `2>`, `1>&2`, `&>`…).
        /// Devolve o operador e deixa `i` no último caractere dele.
        func redirecionamento() -> String? {
            var op = ""
            var k = 0
            if let c = proximo(0), c == "1" || c == "2" || c == "&" {
                guard proximo(1) == ">" else { return nil }
                op = String(c); k = 1
            }
            guard proximo(k) == ">" else { return nil }
            op += ">"; k += 1
            if proximo(k) == ">" {
                op += ">"; k += 1
            } else if op != "&>", proximo(k) == "&", let d = proximo(k + 1), d == "1" || d == "2" {
                op += "&" + String(d); k += 2
            }
            i = line.index(i, offsetBy: k - 1)
            return op
        }
        /// O que a barra escapa dentro de aspas duplas.
        let escapaveis: Set<Character> = ["$", "`", "\"", "\\", "\n"]
        while i < line.endIndex {
            let c = line[i]
            switch c {
            case "'":
                guard let close = line[line.index(after: i)...].firstIndex(of: "'")
                else { throw ParseError.unterminatedQuote }
                literal(line[line.index(after: i) ..< close], citado: true); hasWord = true; i = close
            case "\"":
                var j = line.index(after: i)
                var closed = false
                while j < line.endIndex {
                    let d = line[j]
                    let depois = line.index(after: j)
                    if d == "\\", depois < line.endIndex {
                        // Nas aspas duplas a barra só escapa `$`, crase, aspas, a própria barra e
                        // a quebra de linha; antes dos outros ela fica, como no sh: "a\nb" é a,
                        // barra, n, b. Antes o shell comia a barra e o "a\nb" virava "anb".
                        if escapaveis.contains(line[depois]) {
                            j = depois; literal(String(line[depois]), citado: true)
                        } else {
                            literal("\\", citado: true)
                        }
                    } else if d == "$" {
                        try dolar(&j, citado: true)
                    } else if d == "\"" {
                        closed = true; break
                    } else {
                        literal(String(d), citado: true)
                    }
                    j = line.index(after: j)
                }
                guard closed else { throw ParseError.unterminatedQuote }
                hasWord = true; i = j
            case "\\":
                let n = line.index(after: i)
                if n < line.endIndex {
                    literal(String(line[n]), citado: true); hasWord = true; i = n
                }
            case "$": try dolar(&i, citado: false); hasWord = true
            case "`": throw ParseError.semSubstituicao
            case " ", "\t": flush()
            case "#" where !hasWord: i = line.endIndex; continue
            case "|", "&", ";", ">", "<":
                flush()
                if c == ">" || (c == "&" && proximo(1) == ">"), let op = redirecionamento() {
                    out.append(.op(op))
                    break
                }
                let n = line.index(after: i)
                if c == "<", n < line.endIndex, line[n] == "<" {
                    throw ParseError.semHeredoc
                }
                if n < line.endIndex, line[n] == c, c == "|" || c == "&" {
                    out.append(.op(String(c) + String(c))); i = n
                } else {
                    out.append(.op(String(c)))
                }
            default:
                // 2> 2>> 2>&1 1> 1>&2 no começo de uma palavra
                if c == "1" || c == "2", !hasWord, proximo(1) == ">", let op = redirecionamento() {
                    out.append(.op(op))
                } else {
                    literal(String(c), citado: false); hasWord = true
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
                case ">", ">>", "1>", "1>>", "2>", "2>>", "&>", "&>>":
                    guard i + 1 < tokens.count,
                          case let .word(f) = tokens[i + 1] else { throw ParseError.unexpected(o) }
                    if o.hasPrefix("2") {
                        cur.stderrFile = f; cur.stderrAppend = o == "2>>"
                    } else {
                        cur.stdoutFile = f; cur.append = o.hasSuffix(">>")
                        if o.hasPrefix("&") {
                            cur.stderrToStdout = true
                        }
                    }
                    i += 1
                case "<":
                    guard i + 1 < tokens.count,
                          case let .word(f) = tokens[i + 1] else { throw ParseError.unexpected(o) }
                    cur.stdinFile = f; i += 1
                case "2>&1": cur.stderrToStdout = true
                case ">&2", "1>&2": cur.stdoutToStderr = true
                case ">&1", "1>&1", "2>&2": break
                default: throw ParseError.unexpected(o)
                }
            }
            i += 1
        }
        try endPipeline(background: false)
        return LinhaCrua(items: items)
    }
}
