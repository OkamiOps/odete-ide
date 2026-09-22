import Foundation
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

    /// Como cada linguagem comenta uma linha, para o ⌘/.
    ///
    /// Quem não tem comentário de linha (HTML, CSS, XML, Markdown) cai no de bloco,
    /// aplicado linha a linha. Texto puro não tem comentário nenhum.
    nonisolated static func comentario(para language: Language) -> EstiloDeComentario? {
        switch language {
        case .javascript, .jsx, .typescript, .tsx, .swift, .rust, .c, .cpp, .csharp, .go, .java, .php,
             .scss:
            .linha("//")
        // JSON puro não tem comentário, mas quase todo JSON editado à mão (tsconfig,
        // settings do VS Code) é JSONC, que aceita `//`.
        case .json: .linha("//")
        case .python, .ruby, .bash, .yaml, .toml, .perl, .r, .elixir, .julia: .linha("#")
        case .sql, .lua, .haskell, .elm: .linha("--")
        case .latex: .linha("%")
        case .css: .bloco("/*", "*/")
        case .ocaml: .bloco("(*", "*)")
        case .html, .xml, .markdown, .svelte, .astro: .bloco("<!--", "-->")
        case .plain: nil
        }
    }

    /// O comentário que vale no ponto `local` do texto.
    ///
    /// HTML, Svelte, Vue e Astro misturam linguagens no mesmo arquivo: dentro de
    /// `<script>` o comentário é `//`, dentro de `<style>` é `/* */`, e no cabeçalho
    /// `---` do Astro é JavaScript. Olhar a última tag aberta antes do cursor resolve o
    /// caso comum sem pedir nada à árvore de sintaxe.
    nonisolated static func comentario(para language: Language, em ns: NSString, local: Int) -> EstiloDeComentario? {
        let base = comentario(para: language)
        guard [.html, .svelte, .astro].contains(language) else { return base }
        let antes = ns.substring(to: min(max(local, 0), ns.length)).lowercased() as NSString
        if language == .astro, antes.hasPrefix("---") {
            // Cabeçalho do Astro: do primeiro `---` até o segundo.
            let depoisDoPrimeiro = antes.substring(from: 3) as NSString
            if depoisDoPrimeiro.range(of: "\n---").location == NSNotFound {
                return .linha("//")
            }
        }
        func dentro(_ abre: String, _ fecha: String) -> Bool {
            let a = antes.range(of: abre, options: .backwards).location
            guard a != NSNotFound else { return false }
            let f = antes.range(of: fecha, options: .backwards).location
            return f == NSNotFound || f < a
        }
        if dentro("<script", "</script") {
            return .linha("//")
        }
        if dentro("<style", "</style") {
            return .bloco("/*", "*/")
        }
        return base
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
