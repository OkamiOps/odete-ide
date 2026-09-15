import Foundation

/// Uma sugestão do autocompletar.
public struct Completion: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case word, path, snippet
        public var symbol: String {
            switch self {
            case .word: "textformat.abc"
            case .path: "folder"
            case .snippet: "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    public var label: String
    /// Texto inserido no lugar do prefixo. `$0` marca onde o cursor fica.
    public var insert: String
    public var kind: Kind
    public var detail: String?
    public var id: String {
        "\(kind.rawValue):\(label)"
    }

    public init(label: String, insert: String, kind: Kind, detail: String? = nil) {
        self.label = label
        self.insert = insert
        self.kind = kind
        self.detail = detail
    }
}

/// O que o usuário está digitando: o prefixo antes do cursor e o contexto (palavra ou caminho).
public struct CompletionContext: Sendable, Hashable {
    public enum Mode: Sendable, Hashable { case word, path(String) }
    public var prefix: String
    /// Offset (em `Character`s) onde o prefixo começa.
    public var start: Int
    public var mode: Mode
    /// Verdadeiro quando o trecho é um import de módulo (`from "…"`), e não um `src=`.
    public var modulo = false
}

public enum Complete {
    public struct Snippet: Sendable, Hashable {
        public var trigger: String
        public var detail: String
        public var body: String
    }

    static let jsSnippets: [Snippet] = [
        Snippet(trigger: "log", detail: "console.log(…)", body: "console.log($0)"),
        Snippet(trigger: "fn", detail: "function", body: "function $0() {\n  \n}"),
        Snippet(trigger: "afn", detail: "arrow function", body: "const $0 = () => {\n  \n}"),
        Snippet(trigger: "imp", detail: "import", body: "import $0 from \"\""),
        Snippet(trigger: "exp", detail: "export default", body: "export default $0"),
        Snippet(trigger: "useState", detail: "React state", body: "const [$0, set] = useState()"),
        Snippet(trigger: "useEffect", detail: "React effect", body: "useEffect(() => {\n  $0\n}, [])"),
        Snippet(trigger: "try", detail: "try/catch", body: "try {\n  $0\n} catch (e) {\n  console.error(e)\n}"),
        Snippet(trigger: "for", detail: "for…of", body: "for (const $0 of ) {\n  \n}"),
        Snippet(
            trigger: "fetch",
            detail: "fetch JSON",
            body: "const res = await fetch($0)\nconst data = await res.json()"
        ),
    ]

    static let swiftSnippets: [Snippet] = [
        Snippet(
            trigger: "struct",
            detail: "View",
            body: "struct $0: View {\n    var body: some View {\n        Text(\"\")\n    }\n}"
        ),
        Snippet(trigger: "state", detail: "@State", body: "@State private var $0 = "),
        Snippet(trigger: "vstack", detail: "VStack", body: "VStack {\n    $0\n}"),
        Snippet(trigger: "hstack", detail: "HStack", body: "HStack {\n    $0\n}"),
        Snippet(trigger: "button", detail: "Button", body: "Button(\"$0\") {\n    \n}"),
        Snippet(trigger: "foreach", detail: "ForEach", body: "ForEach($0) { item in\n    \n}"),
        Snippet(trigger: "func", detail: "func", body: "func $0() {\n    \n}"),
    ]

    static let htmlSnippets: [Snippet] = [
        Snippet(
            trigger: "html",
            detail: "documento",
            body: "<!doctype html>\n<html lang=\"pt-BR\">\n<head>\n  <meta charset=\"utf-8\">\n  <title>$0</title>\n</head>\n<body>\n</body>\n</html>"
        ),
        Snippet(trigger: "div", detail: "<div>", body: "<div>$0</div>"),
        Snippet(trigger: "a", detail: "<a href>", body: "<a href=\"$0\"></a>"),
        Snippet(trigger: "script", detail: "<script>", body: "<script type=\"module\" src=\"$0\"></script>"),
    ]

    static let cssSnippets: [Snippet] = [
        Snippet(
            trigger: "flex",
            detail: "flex center",
            body: "display: flex;\nalign-items: center;\njustify-content: center;$0"
        ),
        Snippet(trigger: "media", detail: "@media", body: "@media (max-width: $0px) {\n  \n}"),
    ]

    public static func snippets(for language: Language) -> [Snippet] {
        switch language {
        case .javascript, .jsx, .typescript, .tsx: jsSnippets
        case .swift: swiftSnippets
        case .html: htmlSnippets
        case .css: cssSnippets
        default: []
        }
    }

    /// Descobre o prefixo antes do cursor (offset em Characters).
    public static func context(text: String, cursor: Int) -> CompletionContext? {
        let chars = Array(text)
        let end = min(max(cursor, 0), chars.count)
        // Caminho: dentro de aspas depois de from / import( / require( / src= / href=, ou começando com ./ ../ @/
        var q = end - 1
        var pathStart: Int?
        var moduloAqui = false
        while q >= 0, chars[q] != "\n" {
            if chars[q] == "\"" || chars[q] == "'" || chars[q] == "`" {
                let inside = String(chars[(q + 1) ..< end])
                let before = String(chars[max(0, q - 12) ..< q])
                let ehModulo = before.contains("from ") || before.contains("import(") || before
                    .contains("require(") || before.contains("import ")
                let looksImport = ehModulo || before.contains("src=") || before.contains("href=")
                moduloAqui = ehModulo
                if looksImport || inside.hasPrefix("./") || inside.hasPrefix("../") || inside.hasPrefix("@/") || inside
                    .hasPrefix("/")
                {
                    pathStart = q + 1
                }
                break
            }
            q -= 1
        }
        if let ps = pathStart {
            let inside = String(chars[ps ..< end])
            guard !inside.contains(" ") else { return nil }
            let slash = inside.lastIndex(of: "/").map { inside.distance(from: inside.startIndex, to: $0) + 1 } ?? 0
            let prefix = String(inside.dropFirst(slash))
            return CompletionContext(
                prefix: prefix,
                start: ps + slash,
                mode: .path(String(inside.prefix(slash))),
                modulo: moduloAqui
            )
        }
        var s = end
        while s > 0, isWord(chars[s - 1]) {
            s -= 1
        }
        guard s < end else { return nil }
        return CompletionContext(prefix: String(chars[s ..< end]), start: s, mode: .word)
    }

    static func isWord(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "$"
    }

    /// Sugestões para o texto e o cursor dados.
    /// - `files`: caminhos relativos ao projeto (para completar caminhos).
    /// - `currentPath`: caminho do arquivo aberto (para resolver `./`).
    public static func suggestions(
        text: String,
        cursor: Int,
        language: Language,
        files: [String] = [],
        currentPath: String = "",
        packages: [String] = [],
        limit: Int = 8
    ) -> [Completion] {
        guard let ctx = context(text: text, cursor: cursor) else { return [] }
        switch ctx.mode {
        case let .path(dir):
            return paths(
                dir: dir,
                prefix: ctx.prefix,
                files: files,
                currentPath: currentPath,
                // Pacote instalado só faz sentido num import sem caminho: `from "re…"`.
                // Com `./`, `/` ou `@/` a pessoa está apontando para dentro do projeto.
                packages: ctx.modulo && !dir.hasPrefix(".") && !dir.hasPrefix("/") && !dir.hasPrefix("@/")
                    ? packages : [],
                dir: dir,
                limit: limit
            )
        case .word:
            guard ctx.prefix.count >= 2 else { return [] }
            return words(text: text, cursor: cursor, prefix: ctx.prefix, language: language, limit: limit)
        }
    }

    static func paths(
        dir: String,
        prefix: String,
        files: [String],
        currentPath: String,
        packages: [String] = [],
        dir base0: String = "",
        limit: Int
    ) -> [Completion] {
        let base: String
        if dir.hasPrefix("@/") {
            base = "src/" + dir.dropFirst(2)
        } else if dir.hasPrefix("/") {
            base = String(dir.dropFirst())
        } else {
            var parts = currentPath.split(separator: "/").dropLast().map(String.init)
            for seg in dir.split(separator: "/") {
                if seg == ".." {
                    _ = parts.popLast()
                } else if seg != "." {
                    parts.append(String(seg))
                }
            }
            base = parts.joined(separator: "/")
        }
        var seen = Set<String>()
        var out: [Completion] = []
        // Pacotes instalados primeiro: é o que se procura quando se escreve `from "`.
        // Sem isto, ver node_modules na árvore não ajudava a escrever o import.
        for nome in packages {
            let alvo = base0.isEmpty ? nome : String(nome.dropFirst(min(base0.count, nome.count)))
            guard nome.hasPrefix(base0), !alvo.isEmpty,
                  prefix.isEmpty || alvo.lowercased().hasPrefix(prefix.lowercased()),
                  seen.insert(alvo).inserted else { continue }
            out.append(Completion(label: alvo, insert: alvo, kind: .path, detail: "pacote"))
        }
        for f in files where f != currentPath {
            let rel: Substring
            if base.isEmpty {
                rel = f[...]
            } else if f.hasPrefix(base + "/") {
                rel = f.dropFirst(base.count + 1)
            } else {
                continue
            }
            let first = rel.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard let head = first.first.map(String.init), !head.isEmpty else { continue }
            let isDir = first.count > 1
            let name = isDir ? head + "/" : head
            guard prefix.isEmpty || name.lowercased().hasPrefix(prefix.lowercased()),
                  seen.insert(name).inserted else { continue }
            let insert = isDir ? name : stripExt(name)
            out.append(Completion(label: name, insert: insert, kind: .path, detail: isDir ? "pasta" : nil))
        }
        return Array(out.sorted { ($0.detail == nil) == ($1.detail == nil) ? $0.label < $1.label : $0.detail != nil }
            .prefix(limit))
    }

    static func stripExt(_ name: String) -> String {
        for ext in [".ts", ".tsx", ".js", ".jsx"] where name.hasSuffix(ext) && !name.hasSuffix(".d.ts") {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    static func words(text: String, cursor: Int, prefix: String, language: Language, limit: Int) -> [Completion] {
        let lower = prefix.lowercased()
        var out: [Completion] = []
        for s in snippets(for: language) where s.trigger.lowercased().hasPrefix(lower) && s.trigger != prefix {
            out.append(Completion(label: s.trigger, insert: s.body, kind: .snippet, detail: s.detail))
        }
        // Palavras do documento, mais próximas do cursor primeiro; a própria palavra sendo digitada fica de fora.
        var counts: [String: Int] = [:] // palavra → ocorrências
        var word = ""
        var idx = 0
        var wordStart = 0
        func flush() {
            if word.count >= 3, word.lowercased().hasPrefix(lower), word != prefix,
               !(wordStart < cursor && cursor <= wordStart + word.count)
            {
                counts[word, default: 0] += 1
            }
            word = ""
        }
        for c in text {
            if isWord(c) {
                if word.isEmpty {
                    wordStart = idx
                }
                word.append(c)
            } else {
                flush()
            }
            idx += 1
        }
        flush()
        let ranked = counts.sorted { a, b in
            if a.value != b.value {
                return a.value > b.value
            }
            return a.key.count != b.key.count ? a.key.count < b.key.count : a.key < b.key
        }
        for (w, _) in ranked where !out.contains(where: { $0.label == w }) {
            out.append(Completion(label: w, insert: w, kind: .word))
        }
        return Array(out.prefix(limit))
    }
}
