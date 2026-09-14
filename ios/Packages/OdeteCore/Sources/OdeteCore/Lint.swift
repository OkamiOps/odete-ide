import Foundation

/// Um aviso do lint leve. `line`/`column` são 1-based; `length` cobre o trecho a sublinhar.
public struct LintIssue: Sendable, Hashable, Identifiable {
    public enum Severity: String, Sendable, Hashable { case error, warning, info }
    public var rule: String
    public var message: String
    public var severity: Severity
    public var line: Int
    public var column: Int
    public var length: Int
    public var id: String {
        "\(rule):\(line):\(column)"
    }

    public init(rule: String, message: String, severity: Severity, line: Int, column: Int, length: Int) {
        self.rule = rule
        self.message = message
        self.severity = severity
        self.line = line
        self.column = column
        self.length = length
    }
}

/// Regras simples por linguagem, sem parser. Erros de sintaxe vêm de fora
/// (esbuild para JS/TS, o parser Swift da Odete para Swift) e são somados a estes.
public enum Lint {
    public static func rules(text: String, language: Language) -> [LintIssue] {
        switch language {
        case .javascript, .jsx, .typescript, .tsx: js(text)
        case .json: json(text)
        case .css: css(text)
        case .swift: swift(text)
        default: []
        }
    }

    private struct Rule {
        let id: String
        let rx: NSRegularExpression
        let message: String
        let severity: LintIssue.Severity
    }

    private static let jsRules: [Rule] = [
        Rule(id: "no-debugger", rx: re(#"(?<![\w$.])debugger\b"#), message: "`debugger` esquecido", severity: .warning),
        Rule(
            id: "no-console",
            rx: re(#"(?<![\w$.])console\.(log|debug|info)\("#),
            message: "console.log no código",
            severity: .info
        ),
        Rule(
            id: "no-var",
            rx: re(#"(?<![\w$.])var\s+[A-Za-z_$]"#),
            message: "Use `let` ou `const` em vez de `var`",
            severity: .warning
        ),
        Rule(id: "eqeqeq", rx: re(#"[^=!<>]==[^=]|!=[^=]"#), message: "Prefira `===` / `!==`", severity: .warning),
        Rule(id: "no-alert", rx: re(#"(?<![\w$.])alert\("#), message: "`alert` trava a página", severity: .info),
    ]

    private static func js(_ text: String) -> [LintIssue] {
        var out: [LintIssue] = []
        for (i, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = stripComments(rawLine)
            let ns = NSRange(line.startIndex..., in: line)
            for rule in jsRules {
                for m in rule.rx.matches(in: line, range: ns) {
                    guard let r = Range(m.range, in: line) else { continue }
                    var col = line.distance(from: line.startIndex, to: r.lowerBound) + 1
                    var len = line.distance(from: r.lowerBound, to: r.upperBound)
                    if rule.id == "eqeqeq" {
                        // o match leva um char de cada lado
                        let sub = line[r]
                        if let op = sub.range(of: "==") ?? sub.range(of: "!=") {
                            col += sub.distance(from: sub.startIndex, to: op.lowerBound)
                            len = 2
                        }
                    }
                    out.append(LintIssue(
                        rule: rule.id,
                        message: rule.message,
                        severity: rule.severity,
                        line: i + 1,
                        column: col,
                        length: len
                    ))
                }
            }
        }
        return out.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    /// Remove `// …` e strings simples da linha para as regras não dispararem dentro de texto.
    static func stripComments(_ line: String) -> String {
        var out = ""
        var quote: Character?
        var it = line.makeIterator()
        var prev: Character = " "
        while let c = it.next() {
            if let q = quote {
                out.append(" ")
                if c == q, prev != "\\" {
                    quote = nil
                }
            } else if c == "\"" || c == "'" || c == "`" {
                quote = c
                out.append(" ")
            } else if c == "/", prev == "/" {
                out.removeLast()
                break
            } else {
                out.append(c)
            }
            prev = c
        }
        return out
    }

    private static func json(_ text: String) -> [LintIssue] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        do {
            _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            return []
        } catch {
            let ns = error as NSError
            let idx = ns.userInfo["NSJSONSerializationErrorIndex"] as? Int ?? 0
            let (line, col) = position(of: idx, in: text)
            let msg = (ns.userInfo[NSDebugDescriptionErrorKey] as? String ?? "JSON inválido")
                .replacingOccurrences(of: #" around (line|character) \d+.*$"#, with: "", options: .regularExpression)
            return [LintIssue(rule: "json", message: msg, severity: .error, line: line, column: col, length: 1)]
        }
    }

    private static func css(_ text: String) -> [LintIssue] {
        var out: [LintIssue] = []
        var depth = 0
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if depth < 0 {
                out.append(LintIssue(
                    rule: "css-brace",
                    message: "`}` sem abertura",
                    severity: .error,
                    line: i + 1,
                    column: 1,
                    length: line.count
                ))
                depth = 0
            }
            if let r = line.range(of: "!important") {
                out.append(LintIssue(
                    rule: "no-important",
                    message: "`!important` dificulta sobrescrever",
                    severity: .info,
                    line: i + 1,
                    column: line.distance(from: line.startIndex, to: r.lowerBound) + 1,
                    length: 10
                ))
            }
        }
        if depth > 0, let last = text.components(separatedBy: "\n").indices.last {
            out.append(LintIssue(
                rule: "css-brace",
                message: "`{` sem fechamento",
                severity: .error,
                line: last + 1,
                column: 1,
                length: 1
            ))
        }
        return out
    }

    private static let swiftRules: [Rule] = [
        Rule(id: "no-force-try", rx: re(#"\btry!"#), message: "`try!` derruba o app se falhar", severity: .warning),
        Rule(id: "no-print", rx: re(#"(?<![\w.])print\("#), message: "`print` esquecido", severity: .info),
        Rule(id: "todo", rx: re(#"//\s*(TODO|FIXME)\b"#), message: "Pendência marcada", severity: .info),
    ]

    private static func swift(_ text: String) -> [LintIssue] {
        var out: [LintIssue] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let ns = NSRange(line.startIndex..., in: line)
            for rule in swiftRules {
                for m in rule.rx.matches(in: line, range: ns) {
                    guard let r = Range(m.range, in: line) else { continue }
                    out.append(LintIssue(
                        rule: rule.id, message: rule.message, severity: rule.severity, line: i + 1,
                        column: line.distance(from: line.startIndex, to: r.lowerBound) + 1,
                        length: line.distance(from: r.lowerBound, to: r.upperBound)
                    ))
                }
            }
        }
        return out
    }

    /// Converte um offset em (linha, coluna) 1-based.
    public static func position(of offset: Int, in text: String) -> (Int, Int) {
        var line = 1, col = 1, i = 0
        for c in text.utf8 {
            if i >= offset {
                break
            }
            if c == UInt8(ascii: "\n") {
                line += 1
                col = 1
            } else {
                col += 1
            }
            i += 1
        }
        return (line, col)
    }

    private static func re(_ p: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p)
    }
}
