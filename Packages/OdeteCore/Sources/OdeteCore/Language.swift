import Foundation

/// A linguagem de um arquivo, para colorir, completar e dar o contorno.
///
/// A lista acompanha as gramáticas tree-sitter que a Odete embarca: quem está aqui é
/// colorido de verdade. Arquivo sem gramática cai em `plain` e fica branco, que é o
/// sintoma de quem escreve num formato que ninguém ensinou ao editor.
public enum Language: String, CaseIterable, Codable, Sendable {
    case html, css, scss, javascript, jsx, typescript, tsx, json, markdown, swift, yaml
    case astro, svelte, xml
    case rust, c, cpp, csharp, go, java, python, ruby, php, bash, sql, toml, lua, perl, r
    case haskell, elixir, elm, ocaml, julia, latex
    case plain

    public var label: String {
        switch self {
        case .html: "HTML"
        case .css: "CSS"
        case .scss: "SCSS"
        case .javascript: "JavaScript"
        case .jsx: "JSX"
        case .typescript: "TypeScript"
        case .tsx: "TSX"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .swift: "Swift"
        case .yaml: "YAML"
        case .astro: "Astro"
        case .svelte: "Svelte"
        case .xml: "XML"
        case .rust: "Rust"
        case .c: "C"
        case .cpp: "C++"
        case .csharp: "C#"
        case .go: "Go"
        case .java: "Java"
        case .python: "Python"
        case .ruby: "Ruby"
        case .php: "PHP"
        case .bash: "Shell"
        case .sql: "SQL"
        case .toml: "TOML"
        case .lua: "Lua"
        case .perl: "Perl"
        case .r: "R"
        case .haskell: "Haskell"
        case .elixir: "Elixir"
        case .elm: "Elm"
        case .ocaml: "OCaml"
        case .julia: "Julia"
        case .latex: "LaTeX"
        case .plain: "Texto"
        }
    }

    /// Extensões por linguagem. É a mesma tabela usada para detectar e para dizer, num
    /// teste, que toda linguagem tem pelo menos um jeito de chegar até ela.
    public static let extensoes: [Language: [String]] = [
        .html: ["html", "htm"],
        .css: ["css", "less"],
        .scss: ["scss", "sass"],
        .javascript: ["js", "mjs", "cjs"],
        .jsx: ["jsx"],
        .typescript: ["ts", "mts", "cts"],
        .tsx: ["tsx"],
        .json: ["json", "jsonc", "json5", "webmanifest"],
        .markdown: ["md", "mdx", "markdown"],
        .swift: ["swift"],
        .yaml: ["yml", "yaml"],
        .astro: ["astro"],
        .svelte: ["svelte", "vue"],
        .xml: ["xml", "svg", "plist", "xsd", "xsl", "storyboard", "xib", "resx"],
        .rust: ["rs"],
        .c: ["c", "h"],
        .cpp: ["cpp", "cc", "cxx", "hpp", "hh", "hxx", "ino"],
        .csharp: ["cs"],
        .go: ["go"],
        .java: ["java"],
        .python: ["py", "pyw", "pyi"],
        .ruby: ["rb", "rake", "gemspec"],
        .php: ["php", "phtml"],
        .bash: ["sh", "bash", "zsh", "ksh", "command"],
        .sql: ["sql"],
        .toml: ["toml"],
        .lua: ["lua"],
        .perl: ["pl", "pm"],
        .r: ["r"],
        .haskell: ["hs"],
        .elixir: ["ex", "exs"],
        .elm: ["elm"],
        .ocaml: ["ml", "mli"],
        .julia: ["jl"],
        .latex: ["tex", "sty", "cls"],
    ]

    /// Arquivos que não têm extensão mas têm dono conhecido.
    static let porNome: [String: Language] = [
        "dockerfile": .bash, "makefile": .bash, "procfile": .bash,
        "gemfile": .ruby, "rakefile": .ruby, "podfile": .ruby,
        "package.json": .json, "cargo.toml": .toml, "pipfile": .toml,
        ".bashrc": .bash, ".zshrc": .bash, ".profile": .bash, ".bash_profile": .bash,
        // `.gitignore` e parentes ficam de fora de propósito: só o `#` de comentário se
        // parece com shell, e um padrão como `foo{1,2}` viraria erro de chave que não
        // fecha. Texto sem cor é melhor que erro inventado.
    ]

    private static let porExtensao: [String: Language] = {
        var out: [String: Language] = [:]
        for (lang, exts) in extensoes {
            for e in exts {
                out[e] = lang
            }
        }
        return out
    }()

    public static func detect(path: String) -> Language {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let minusculo = name.lowercased()
        if let porNomeExato = porNome[minusculo] {
            return porNomeExato
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .plain }
        let ext = name[name.index(after: dot)...].lowercased()
        // `.env.local`, `.babelrc.json` e afins: o sufixo é que manda.
        return porExtensao[ext] ?? .plain
    }
}
