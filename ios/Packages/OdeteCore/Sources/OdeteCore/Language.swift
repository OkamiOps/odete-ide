import Foundation

public enum Language: String, CaseIterable, Codable, Sendable {
    case html, css, javascript, jsx, typescript, tsx, json, markdown, swift, yaml, plain

    public var label: String {
        switch self {
        case .html: "HTML"
        case .css: "CSS"
        case .javascript: "JavaScript"
        case .jsx: "JSX"
        case .typescript: "TypeScript"
        case .tsx: "TSX"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .swift: "Swift"
        case .yaml: "YAML"
        case .plain: "Texto"
        }
    }

    public static func detect(path: String) -> Language {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .plain }
        let ext = name[name.index(after: dot)...].lowercased()
        switch ext {
        case "html", "htm": return .html
        case "css", "scss", "less": return .css
        case "js", "mjs", "cjs": return .javascript
        case "jsx": return .jsx
        case "ts", "mts", "cts": return .typescript
        case "tsx": return .tsx
        case "json", "jsonc": return .json
        case "md", "mdx", "markdown": return .markdown
        case "swift": return .swift
        case "yml", "yaml": return .yaml
        default: return .plain
        }
    }
}
