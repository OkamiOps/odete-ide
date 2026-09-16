import OdeteCore
import OdeteI18n
import TreeSitter
import TreeSitterAstro
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSharp
import TreeSitterCSS
import TreeSitterElixir
import TreeSitterElm
import TreeSitterGo
import TreeSitterHaskell
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterJulia
import TreeSitterLaTeX
import TreeSitterLua
import TreeSitterOCaml
import TreeSitterPerl
import TreeSitterPHP
import TreeSitterPython
import TreeSitterR
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSCSS
import TreeSitterSQL
import TreeSitterSvelte
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// Erro de sintaxe vindo do parser da linguagem, e não de regra escrita à mão.
///
/// A Odete já carrega a gramática de cada linguagem para colorir. A mesma gramática sabe
/// **analisar**: ela monta a árvore e, onde o código não fecha, deixa dois tipos de
/// marca. `MISSING` é a gramática dizendo qual símbolo falta — é daí que sai "falta `;`"
/// com a posição exata, para toda linguagem de uma vez, sem eu adivinhar por linguagem.
/// `ERROR` é o trecho que ela não conseguiu encaixar em regra nenhuma.
///
/// É o que dava para fazer no lugar de ter o compilador no aparelho: não é análise de
/// tipo, é a sintaxe conferida por quem define a sintaxe.
public enum ParserErros {
    /// Mais que isto numa tela só não informa: um erro no começo faz o parser errar o
    /// resto, e a lista vira ruído.
    public static let teto = 20

    /// Existe parser para esta linguagem? Quem pergunta é o lint, para saber se pode
    /// aposentar as regras escritas à mão naquele arquivo.
    public nonisolated static func temParser(_ language: Language) -> Bool {
        gramatica(language) != nil
    }

    nonisolated static func gramatica(_ language: Language) -> UnsafePointer<TSLanguage>? {
        switch language {
        case .astro: tree_sitter_astro()
        case .bash: tree_sitter_bash()
        case .c: tree_sitter_c()
        case .cpp: tree_sitter_cpp()
        case .csharp: tree_sitter_c_sharp()
        case .css: tree_sitter_css()
        case .scss: tree_sitter_scss()
        case .elixir: tree_sitter_elixir()
        case .elm: tree_sitter_elm()
        case .go: tree_sitter_go()
        case .haskell: tree_sitter_haskell()
        case .html, .xml: tree_sitter_html()
        case .java: tree_sitter_java()
        case .javascript, .jsx: tree_sitter_javascript()
        case .json: tree_sitter_json()
        case .julia: tree_sitter_julia()
        case .latex: tree_sitter_latex()
        case .lua: tree_sitter_lua()
        case .ocaml: tree_sitter_ocaml()
        case .perl: tree_sitter_perl()
        case .php: tree_sitter_php()
        case .python: tree_sitter_python()
        case .r: tree_sitter_r()
        case .ruby: tree_sitter_ruby()
        case .rust: tree_sitter_rust()
        case .sql: tree_sitter_sql()
        case .svelte: tree_sitter_svelte()
        case .swift: tree_sitter_swift()
        case .toml: tree_sitter_toml()
        case .tsx: tree_sitter_tsx()
        case .typescript: tree_sitter_typescript()
        case .yaml: tree_sitter_yaml()
        // Markdown não tem sintaxe que quebre: qualquer texto é Markdown válido.
        case .markdown, .plain: nil
        }
    }

    /// Roda o parser e traduz o que ele marcou.
    public nonisolated static func problemas(text: String, language: Language) -> [LintIssue] {
        guard let lang = gramatica(language), let parser = ts_parser_new() else { return [] }
        defer { ts_parser_delete(parser) }
        guard ts_parser_set_language(parser, lang) else { return [] }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return [] }
        let arvore = bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress.flatMap { base in
                base.withMemoryRebound(to: CChar.self, capacity: buf.count) { c in
                    ts_parser_parse_string(parser, nil, c, UInt32(buf.count))
                }
            }
        }
        guard let arvore else { return [] }
        defer { ts_tree_delete(arvore) }
        let raiz = ts_tree_root_node(arvore)
        guard ts_node_has_error(raiz) else { return [] }
        var achados: [LintIssue] = []
        colhe(raiz, &achados)
        return Array(achados.prefix(teto))
    }

    /// Desce só pelos ramos que contêm erro: o resto da árvore está certo e não interessa.
    private nonisolated static func colhe(_ node: TSNode, _ out: inout [LintIssue]) {
        guard out.count < teto, ts_node_has_error(node) else { return }
        let n = ts_node_child_count(node)
        // Um `ERROR` ou `MISSING` que tem filhos com erro: o recado bom é o de dentro,
        // mais específico. Só se nenhum filho reclamar é que este nó vira o recado.
        var filhoReclamou = false
        for i in 0 ..< n {
            let filho = ts_node_child(node, i)
            if ts_node_has_error(filho) || ts_node_is_missing(filho) {
                let antes = out.count
                colhe(filho, &out)
                if out.count > antes {
                    filhoReclamou = true
                }
            }
        }
        if filhoReclamou {
            return
        }
        guard let issue = recado(node) else { return }
        // O mesmo ponto pode ser marcado duas vezes pela recuperação do parser.
        if out.contains(where: { $0.line == issue.line && $0.column == issue.column }) {
            return
        }
        out.append(issue)
    }

    private nonisolated static func recado(_ node: TSNode) -> LintIssue? {
        let ponto = ts_node_start_point(node)
        let fim = ts_node_end_point(node)
        let linha = Int(ponto.row) + 1
        let coluna = Int(ponto.column) + 1
        let largura = ponto.row == fim.row ? max(1, Int(fim.column) - Int(ponto.column)) : 1
        guard let tipo = ts_node_type(node).map({ String(cString: $0) }) else { return nil }

        if ts_node_is_missing(node) {
            // `ts_node_type` de um nó ausente é o símbolo que faltou: `;`, `)`, `end`.
            return LintIssue(
                rule: "falta-simbolo",
                message: tr("falta `%1$@` aqui", tipo),
                severity: .error,
                line: linha,
                column: coluna,
                length: 1
            )
        }
        guard tipo == "ERROR" else { return nil }
        return LintIssue(
            rule: "sintaxe",
            message: tr("erro de sintaxe: o analisador não entende este trecho"),
            severity: .error,
            line: linha,
            column: coluna,
            length: largura
        )
    }
}
