import OdeteCore
import Runestone
import TreeSitterCSSRunestone
import TreeSitterHTMLRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterJSONRunestone
import TreeSitterMarkdownInlineRunestone
import TreeSitterMarkdownRunestone
import TreeSitterSwiftRunestone
import TreeSitterTSXRunestone
import TreeSitterTypeScriptRunestone
import TreeSitterYAMLRunestone

/// Mapeia `Language` para a gramática tree-sitter do Runestone.
@MainActor
enum LanguageMode {
    static func treeSitter(for language: Language) -> TreeSitterLanguage? {
        switch language {
        case .html: .html
        case .css: .css
        case .javascript, .jsx: .javaScript
        case .typescript: .typeScript
        case .tsx: .tsx
        case .json: .json
        case .markdown: .markdown
        case .swift: .swift
        case .yaml: .yaml
        case .plain: nil
        }
    }

    /// Injeções (Markdown inline, JS/CSS dentro de HTML).
    static let provider = Provider()

    final class Provider: TreeSitterLanguageProvider {
        func treeSitterLanguage(named languageName: String) -> TreeSitterLanguage? {
            switch languageName {
            case "markdown_inline": .markdownInline
            case "javascript": .javaScript
            case "css": .css
            case "html": .html
            default: nil
            }
        }
    }
}
