import Foundation

/// Um símbolo do arquivo aberto (função, classe, título de Markdown, seletor CSS…).
public struct OutlineItem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case function, `class`, `struct`, `enum`, `protocol`, variable, export, heading, selector, key, property

        public var symbol: String {
            switch self {
            case .function: "f.cursive"
            case .class: "c.square"
            case .struct: "s.square"
            case .enum: "e.square"
            case .protocol: "p.square"
            case .variable: "v.square"
            case .export: "arrow.up.right.square"
            case .heading: "number"
            case .selector: "paintbrush"
            case .key: "curlybraces"
            case .property: "circle.fill"
            }
        }
    }

    public var name: String
    public var kind: Kind
    /// Linha 1-based.
    public var line: Int
    /// Profundidade (0 = topo).
    public var level: Int
    public var id: String {
        "\(line):\(kind.rawValue):\(name)"
    }

    public init(name: String, kind: Kind, line: Int, level: Int = 0) {
        self.name = name
        self.kind = kind
        self.line = line
        self.level = level
    }
}

/// Esboço leve por linguagem: uma passada por linha com regex. Não substitui um parser,
/// mas cobre o que aparece em projetos web e Swift do dia a dia.
public enum Outline {
    public static func items(text: String, language: Language) -> [OutlineItem] {
        let lines = text.components(separatedBy: "\n")
        switch language {
        case .javascript, .jsx, .typescript, .tsx: return js(lines)
        case .swift: return swift(lines)
        case .markdown: return markdown(lines)
        case .css: return css(lines)
        case .json: return json(lines)
        case .html: return html(lines)
        case .yaml: return yaml(lines)
        case .plain: return []
        }
    }

    // MARK: - JS / TS

    private static let jsPatterns: [(NSRegularExpression, OutlineItem.Kind)] = [
        (re(#"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)"#), .function),
        (re(#"^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)"#), .class),
        (re(#"^\s*(?:export\s+)?(?:interface|type)\s+([A-Za-z_$][\w$]*)"#), .struct),
        (re(#"^\s*(?:export\s+)?enum\s+([A-Za-z_$][\w$]*)"#), .enum),
        (
            re(
                #"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>"#
            ),
            .function
        ),
        (
            re(#"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?function"#),
            .function
        ),
        (re(#"^\s*export\s+(?:const|let|var)\s+([A-Za-z_$][\w$]*)"#), .export),
        (re(#"^\s*(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?="#), .variable),
        (
            re(
                #"^\s+(?:public\s+|private\s+|protected\s+|static\s+|async\s+|readonly\s+)*([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*(?::\s*[^{]+)?\{\s*$"#
            ),
            .property
        ),
    ]

    private static func js(_ lines: [String]) -> [OutlineItem] {
        var out: [OutlineItem] = []
        var depth = 0
        for (i, line) in lines.enumerated() {
            let indentTop = !line.hasPrefix(" ") && !line.hasPrefix("\t")
            for (rx, kind) in jsPatterns {
                if let m = rx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let r = Range(m.range(at: 1), in: line)
                {
                    var k = kind
                    if kind == .property, depth == 0 {
                        continue
                    }
                    if kind == .variable, !indentTop {
                        continue
                    }
                    if kind == .property,
                       line.contains("if (") || line.contains("for (") || line.contains("while (") || line
                       .contains("switch (")
                    {
                        continue
                    }
                    let name = String(line[r])
                    if ["if", "for", "while", "switch", "catch", "function", "return"].contains(name) {
                        continue
                    }
                    if k == .function, line.trimmingCharacters(in: .whitespaces).hasPrefix("export") {
                        k = .export
                    }
                    out.append(OutlineItem(name: name, kind: k, line: i + 1, level: indentTop ? 0 : 1))
                    break
                }
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            depth = max(depth, 0)
        }
        return out
    }

    // MARK: - Swift

    private static let swiftPatterns: [(NSRegularExpression, OutlineItem.Kind)] = [
        (
            re(
                #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|private\s+|internal\s+|fileprivate\s+|open\s+|final\s+|static\s+|mutating\s+|override\s+|nonisolated\s+)*func\s+([A-Za-z_][\w]*)"#
            ),
            .function
        ),
        (
            re(
                #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|private\s+|internal\s+|fileprivate\s+|open\s+|final\s+)*(?:class|actor)\s+([A-Za-z_][\w]*)"#
            ),
            .class
        ),
        (
            re(
                #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|private\s+|internal\s+|fileprivate\s+)*struct\s+([A-Za-z_][\w]*)"#
            ),
            .struct
        ),
        (
            re(
                #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|private\s+|internal\s+|fileprivate\s+|indirect\s+)*enum\s+([A-Za-z_][\w]*)"#
            ),
            .enum
        ),
        (re(#"^\s*(?:public\s+|private\s+|internal\s+)*protocol\s+([A-Za-z_][\w]*)"#), .protocol),
        (re(#"^\s*(?:public\s+|private\s+|internal\s+)*extension\s+([A-Za-z_][\w.]*)"#), .class),
        (
            re(
                #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|private\s+|internal\s+|fileprivate\s+|static\s+|lazy\s+)*(?:var|let)\s+([A-Za-z_][\w]*)\b"#
            ),
            .variable
        ),
    ]

    private static func swift(_ lines: [String]) -> [OutlineItem] {
        var out: [OutlineItem] = []
        var depth = 0
        for (i, line) in lines.enumerated() {
            for (rx, kind) in swiftPatterns {
                if let m = rx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let r = Range(m.range(at: 1), in: line)
                {
                    // Variáveis locais (dentro de funções) ficam de fora; propriedades de tipo entram.
                    if kind == .variable, depth > 1 {
                        break
                    }
                    let name = String(line[r])
                    let k: OutlineItem.Kind = (kind == .variable && name == "body") ? .property : kind
                    out.append(OutlineItem(name: name, kind: k, line: i + 1, level: min(depth, 3)))
                    break
                }
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            depth = max(depth, 0)
        }
        return out
    }

    // MARK: - Markdown

    private static func markdown(_ lines: [String]) -> [OutlineItem] {
        var out: [OutlineItem] = []
        var inFence = false
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard !inFence, line.hasPrefix("#") else { continue }
            let hashes = line.prefix { $0 == "#" }.count
            guard hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") else { continue }
            let title = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                out.append(OutlineItem(name: title, kind: .heading, line: i + 1, level: hashes - 1))
            }
        }
        return out
    }

    // MARK: - CSS

    private static func css(_ lines: [String]) -> [OutlineItem] {
        var out: [OutlineItem] = []
        var depth = 0
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let brace = line.firstIndex(of: "{"), !line.hasPrefix("/*") {
                let sel = line[..<brace].trimmingCharacters(in: .whitespaces)
                if !sel.isEmpty {
                    out.append(OutlineItem(name: sel, kind: .selector, line: i + 1, level: min(depth, 2)))
                }
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            depth = max(depth, 0)
        }
        return out
    }

    // MARK: - JSON

    private static let jsonKey = re(#"^\s*"([^"]+)"\s*:"#)

    private static func json(_ lines: [String]) -> [OutlineItem] {
        var out: [OutlineItem] = []
        var depth = 0
        for (i, line) in lines.enumerated() {
            if depth == 1, let m = jsonKey.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let r = Range(m.range(at: 1), in: line)
            {
                out.append(OutlineItem(name: String(line[r]), kind: .key, line: i + 1))
            }
            depth += line.filter { $0 == "{" || $0 == "[" }.count - line.filter { $0 == "}" || $0 == "]" }.count
            depth = max(depth, 0)
        }
        return out
    }

    // MARK: - HTML

    private static let htmlTag =
        re(#"<(h[1-6]|section|header|main|footer|nav|article|aside|form|template|script|style)\b([^>]*)>"#)
    private static let htmlId = re(#"id=\"([^\"]+)\""#)

    private static func html(_ lines: [String]) -> [OutlineItem] {
        var out: [OutlineItem] = []
        for (i, line) in lines.enumerated() {
            let ns = NSRange(line.startIndex..., in: line)
            for m in htmlTag.matches(in: line, range: ns) {
                guard let tr = Range(m.range(at: 1), in: line),
                      let ar = Range(m.range(at: 2), in: line) else { continue }
                let tag = String(line[tr])
                let attrs = String(line[ar])
                var name = tag
                if let im = htmlId.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)),
                   let ir = Range(im.range(at: 1), in: attrs)
                {
                    name += "#" + attrs[ir]
                } else if tag.hasPrefix("h"), let end = Range(m.range(at: 0), in: line)?.upperBound,
                          let close = line.range(of: "</\(tag)>", range: end ..< line.endIndex)
                {
                    let inner = line[end ..< close.lowerBound].trimmingCharacters(in: .whitespaces)
                    if !inner.isEmpty {
                        name = inner
                    }
                }
                let level = tag.hasPrefix("h") && tag.count == 2 ? (Int(String(tag.last!)) ?? 1) - 1 : 0
                out.append(OutlineItem(
                    name: name,
                    kind: tag.hasPrefix("h") && tag.count == 2 ? .heading : .selector,
                    line: i + 1,
                    level: level
                ))
            }
        }
        return out
    }

    // MARK: - YAML

    private static let yamlKey = re(#"^([A-Za-z_][\w.-]*)\s*:"#)

    private static func yaml(_ lines: [String]) -> [OutlineItem] {
        var out: [OutlineItem] = []
        for (i, line) in lines.enumerated() {
            if let m = yamlKey.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let r = Range(m.range(at: 1), in: line)
            {
                out.append(OutlineItem(name: String(line[r]), kind: .key, line: i + 1))
            }
        }
        return out
    }

    private static func re(_ p: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p)
    }
}

/// Um símbolo com o arquivo onde mora: é isto que permite "ir para a definição" sem
/// abrir os arquivos um a um.
public struct ProjectSymbol: Sendable, Hashable, Identifiable {
    public var name: String
    public var kind: OutlineItem.Kind
    public var path: String
    public var line: Int
    public var id: String {
        "\(path):\(line):\(name)"
    }

    public init(name: String, kind: OutlineItem.Kind, path: String, line: Int) {
        self.name = name
        self.kind = kind
        self.path = path
        self.line = line
    }
}

public extension ProjectSymbol {
    /// Onde `nome` é declarado. Exato primeiro: buscar por `App` não pode devolver
    /// `AppShell` antes de `App`.
    static func procurar(_ nome: String, em indice: [ProjectSymbol]) -> [ProjectSymbol] {
        let exatos = indice.filter { $0.name == nome }
        return exatos.isEmpty ? indice.filter { $0.name.hasPrefix(nome) } : exatos
    }

    /// A palavra em volta de uma posição do texto, que é o que "ir para a definição"
    /// tem em mãos: só o cursor.
    static func palavra(em texto: String, offset: Int) -> String? {
        let chars = Array(texto)
        guard offset >= 0, offset <= chars.count else { return nil }
        func parte(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || c == "$"
        }
        var de = min(offset, max(chars.count - 1, 0))
        // Cursor logo depois da palavra conta como dentro dela: é onde ele fica ao
        // terminar de digitar um nome.
        if de >= chars.count || !parte(chars[de]), de > 0, parte(chars[de - 1]) {
            de -= 1
        }
        guard de < chars.count, parte(chars[de]) else { return nil }
        var ate = de
        while de > 0, parte(chars[de - 1]) {
            de -= 1
        }
        while ate + 1 < chars.count, parte(chars[ate + 1]) {
            ate += 1
        }
        return String(chars[de ... ate])
    }
}
