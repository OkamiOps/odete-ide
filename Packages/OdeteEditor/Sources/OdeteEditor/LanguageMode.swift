import OdeteCore
import Runestone
import TreeSitterAstroRunestone
import TreeSitterBashRunestone
import TreeSitterCommentRunestone
import TreeSitterCPPRunestone
import TreeSitterCRunestone
import TreeSitterCSharpRunestone
import TreeSitterCSSRunestone
import TreeSitterElixirRunestone
import TreeSitterElmRunestone
import TreeSitterGoRunestone
import TreeSitterHaskellRunestone
import TreeSitterHTMLRunestone
import TreeSitterJavaRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterJSDocRunestone
import TreeSitterJSONRunestone
import TreeSitterJuliaRunestone
import TreeSitterLaTeXRunestone
import TreeSitterLuaRunestone
import TreeSitterMarkdownInlineRunestone
import TreeSitterMarkdownRunestone
import TreeSitterOCamlRunestone
import TreeSitterPerlRunestone
import TreeSitterPHPRunestone
import TreeSitterPythonRunestone
import TreeSitterRegexRunestone
import TreeSitterRRunestone
import TreeSitterRubyRunestone
import TreeSitterRustRunestone
import TreeSitterSCSSRunestone
import TreeSitterSQLRunestone
import TreeSitterSvelteRunestone
import TreeSitterSwiftRunestone
import TreeSitterTOMLRunestone
import TreeSitterTSXRunestone
import TreeSitterTypeScriptRunestone
import TreeSitterYAMLRunestone

/// Mapeia `Language` para a gramática tree-sitter do Runestone.
@MainActor
enum LanguageMode {
    static func treeSitter(for language: Language) -> TreeSitterLanguage? {
        switch language {
        case .html: .html
        // Não existe gramática de XML nas TreeSitterLanguages. A de HTML entende tag,
        // atributo e comentário, que é o grosso de um .xml, .svg ou .plist — bem melhor
        // que a página inteira branca.
        case .xml: .html
        case .css: .css
        case .scss: .scss
        case .javascript, .jsx: .javaScript
        case .typescript: .typeScript
        case .tsx: .tsx
        case .json: .json
        case .markdown: .markdown
        case .swift: .swift
        case .yaml: .yaml
        case .astro: .astro
        case .svelte: .svelte
        case .rust: .rust
        case .c: .c
        case .cpp: .cpp
        case .csharp: .cSharp
        case .go: .go
        case .java: .java
        case .python: .python
        case .ruby: .ruby
        case .php: .php
        case .bash: .bash
        case .sql: .sql
        case .toml: .toml
        case .lua: .lua
        case .perl: .perl
        case .r: .r
        case .haskell: .haskell
        case .elixir: .elixir
        case .elm: .elm
        case .ocaml: .ocaml
        case .julia: .julia
        case .latex: .latex
        case .plain: nil
        }
    }

    /// Injeções: a gramática de fora pede a de dentro pelo nome. Markdown pede
    /// `markdown_inline`; Astro, Svelte e HTML pedem JS e CSS; quase todas pedem
    /// `comment` para marcar TODO dentro de comentário.
    static let provider = Provider()

    final class Provider: TreeSitterLanguageProvider {
        func treeSitterLanguage(named languageName: String) -> TreeSitterLanguage? {
            switch languageName {
            case "markdown_inline": .markdownInline
            case "javascript", "js": .javaScript
            case "typescript", "ts": .typeScript
            case "tsx", "jsx": .tsx
            case "css": .css
            case "scss": .scss
            case "html": .html
            case "json": .json
            case "yaml": .yaml
            case "toml": .toml
            case "bash", "sh", "shell": .bash
            case "python": .python
            case "sql": .sql
            case "regex": .regex
            case "comment": .comment
            case "jsdoc": .jsDoc
            default: nil
            }
        }
    }
}
