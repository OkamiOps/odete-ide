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

    /// Símbolos que o conserto de uma ficha tenta encaixar, na ordem em que erram mais.
    static let candidatos = [";", ",", ")", "]", "}", "\"", "'", "end", ":", "then", "do", "*/"]

    /// Arquivo maior que isto não passa pelo conserto: são até doze análises a mais, e
    /// numa pausa de digitação isso vira engasgo.
    static let tetoDoConserto = 200_000

    /// Roda o parser e traduz o que ele marcou.
    public nonisolated static func problemas(text: String, language: Language) -> [LintIssue] {
        guard let lang = gramatica(language) else { return [] }
        let text = semDialeto(text, language)
        guard temErro(text, lang) else { return [] }
        // Antes de descrever o erro, tenta consertá-lo com uma ficha só. Quando um `;`
        // no fim de uma linha faz a árvore inteira ficar limpa, o recado deixa de ser "o
        // analisador não entende este trecho" e passa a ser "falta `;` aqui" — e quem diz
        // isso é o parser, que conferiu, e não um palpite meu.
        if text.utf8.count <= tetoDoConserto, let conserto = consertoDeUmaFicha(text, lang) {
            return [conserto]
        }
        guard let parser = ts_parser_new() else { return [] }
        defer { ts_parser_delete(parser) }
        guard ts_parser_set_language(parser, lang) else { return [] }
        guard let arvore = analisa(text, parser) else { return [] }
        defer { ts_tree_delete(arvore) }
        var achados: [LintIssue] = []
        colhe(ts_tree_root_node(arvore), &achados)
        return Array(achados.prefix(teto))
    }

    // MARK: - o que a gramática embarcada não conhece

    /// Palavras do SQLite que a gramática de SQL embarcada não tem.
    private static let frasesDoSQLite = [["autoincrement"], ["without", "rowid"], ["strict"]]

    /// Comandos que a gramática não tem e que ocupam a instrução inteira.
    private static let comandosDoSQLite = ["pragma", "vacuum", "reindex", "analyze", "attach", "detach"]

    /// O texto que vai ao parser, com o que a gramática não conhece trocado por espaços.
    ///
    /// A gramática de SQL da Odete é de um SQL genérico, e o SQLite tem coisas que ela
    /// nunca viu: `AUTOINCREMENT` na chave primária, `WITHOUT ROWID` no fim da tabela, uma
    /// linha de `PRAGMA`. Cada uma fazia um arquivo **correto** aparecer com erro, que é o
    /// pior defeito que um analisador pode ter. Trocar por espaços do mesmo tamanho em
    /// bytes deixa todas as posições onde estavam, então o resto do arquivo continua sendo
    /// conferido e o recado, quando existir, cai na coluna certa.
    private nonisolated static func semDialeto(_ texto: String, _ language: Language) -> String {
        guard language == .sql else { return texto }
        var b = Array(texto.utf8)
        var i = 0
        while i < b.count {
            guard inicioDePalavra(b, i) else { i += 1; continue }
            if let fim = casaFrase(b, i, frasesDoSQLite) {
                for k in i ..< fim { b[k] = 0x20 }
                i = fim
                continue
            }
            if inicioDeLinha(b, i), let fim = casaComando(b, i) {
                for k in i ..< fim where b[k] != 0x0A { b[k] = 0x20 }
                i = fim
                continue
            }
            while i < b.count, ehLetra(b[i]) { i += 1 }
        }
        return String(decoding: b, as: UTF8.self)
    }

    private nonisolated static func ehLetra(_ c: UInt8) -> Bool {
        (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A || (c >= 0x30 && c <= 0x39) || c == 0x5F
    }

    private nonisolated static func inicioDePalavra(_ b: [UInt8], _ i: Int) -> Bool {
        ehLetra(b[i]) && (i == 0 || !ehLetra(b[i - 1]))
    }

    private nonisolated static func inicioDeLinha(_ b: [UInt8], _ i: Int) -> Bool {
        var k = i - 1
        while k >= 0, b[k] == 0x20 || b[k] == 0x09 { k -= 1 }
        return k < 0 || b[k] == 0x0A
    }

    /// Casa uma palavra a partir de `i`, sem diferenciar maiúscula.
    private nonisolated static func casaPalavra(_ b: [UInt8], _ i: Int, _ palavra: String) -> Int? {
        let alvo = Array(palavra.utf8)
        guard i + alvo.count <= b.count else { return nil }
        for (k, c) in alvo.enumerated() where (b[i + k] | 0x20) != c { return nil }
        let fim = i + alvo.count
        guard fim == b.count || !ehLetra(b[fim]) else { return nil }
        return fim
    }

    /// Casa uma das frases (palavras separadas por espaço) e devolve onde ela termina.
    private nonisolated static func casaFrase(_ b: [UInt8], _ i: Int, _ frases: [[String]]) -> Int? {
        for frase in frases {
            var pos = i
            var casou = true
            for (n, palavra) in frase.enumerated() {
                if n > 0 {
                    let antes = pos
                    while pos < b.count, b[pos] == 0x20 || b[pos] == 0x09 || b[pos] == 0x0A { pos += 1 }
                    if pos == antes { casou = false; break }
                }
                guard let fim = casaPalavra(b, pos, palavra) else { casou = false; break }
                pos = fim
            }
            if casou { return pos }
        }
        return nil
    }

    /// Um comando que ocupa a instrução inteira: apaga até o `;`, ou até o fim da linha.
    private nonisolated static func casaComando(_ b: [UInt8], _ i: Int) -> Int? {
        guard comandosDoSQLite.contains(where: { casaPalavra(b, i, $0) != nil }) else { return nil }
        var pos = i
        while pos < b.count, b[pos] != 0x0A {
            if b[pos] == 0x3B { return pos + 1 }
            pos += 1
        }
        return pos
    }

    private nonisolated static func analisa(_ texto: String, _ parser: OpaquePointer) -> OpaquePointer? {
        let bytes = Array(texto.utf8)
        guard !bytes.isEmpty else { return nil }
        return bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress.flatMap { base in
                base.withMemoryRebound(to: CChar.self, capacity: buf.count) { c in
                    ts_parser_parse_string(parser, nil, c, UInt32(buf.count))
                }
            }
        }
    }

    private nonisolated static func temErro(_ texto: String, _ lang: UnsafePointer<TSLanguage>) -> Bool {
        guard let parser = ts_parser_new() else { return false }
        defer { ts_parser_delete(parser) }
        guard ts_parser_set_language(parser, lang), let arvore = analisa(texto, parser) else { return false }
        defer { ts_tree_delete(arvore) }
        return ts_node_has_error(ts_tree_root_node(arvore))
    }

    /// De onde até onde vai o primeiro erro.
    ///
    /// Não basta a linha onde ele começa: em Rust um `;` que falta no meio de uma função
    /// faz a gramática marcar a **função inteira** como erro, começando na linha do `fn`.
    /// O símbolo que falta está em algum lugar dentro desse trecho.
    private nonisolated static func extensaoDoErro(
        _ texto: String,
        _ lang: UnsafePointer<TSLanguage>
    ) -> ClosedRange<Int>? {
        guard let parser = ts_parser_new() else { return nil }
        defer { ts_parser_delete(parser) }
        guard ts_parser_set_language(parser, lang), let arvore = analisa(texto, parser) else { return nil }
        defer { ts_tree_delete(arvore) }
        guard let node = nodeComErro(ts_tree_root_node(arvore)) else { return nil }
        let ini = Int(ts_node_start_point(node).row) + 1
        let fim = Int(ts_node_end_point(node).row) + 1
        return ini ... max(ini, fim)
    }

    /// O nó de erro mais fundo: quanto mais fundo, menor o trecho a vasculhar.
    private nonisolated static func nodeComErro(_ node: TSNode) -> TSNode? {
        guard ts_node_has_error(node) else { return nil }
        let n = ts_node_child_count(node)
        for i in 0 ..< n {
            let filho = ts_node_child(node, i)
            if ts_node_has_error(filho) || ts_node_is_missing(filho) {
                if let fundo = nodeComErro(filho) {
                    return fundo
                }
            }
        }
        return node
    }

    /// Insere uma ficha e vê se a árvore fica limpa.
    ///
    /// O símbolo que falta quase nunca está na linha do erro: ele falta no **fim da linha
    /// anterior**, que é onde a instrução deveria ter terminado. Por isso as duas posições.
    private nonisolated static func consertoDeUmaFicha(
        _ texto: String,
        _ lang: UnsafePointer<TSLanguage>
    ) -> LintIssue? {
        guard let faixa = extensaoDoErro(texto, lang) else { return nil }
        var linhas = texto.components(separatedBy: "\n")
        // A linha de cima entra porque o símbolo costuma faltar no fim dela, e o erro só
        // aparece na linha seguinte, quando o parser tropeça.
        let deLinha = max(1, faixa.lowerBound - 1)
        // Um teto de tentativas: o conserto roda a cada pausa na digitação.
        let ateLinha = min(faixa.upperBound, deLinha + 11)
        // De baixo para cima: `def f(x)` mais `end` na mesma linha é Ruby válido, então
        // procurando de cima o conserto acharia a linha da abertura e diria "falta `end`"
        // onde o bloco começa. O que ajuda é o ponto mais tarde possível — onde a pessoa
        // parou de escrever.
        // Primeiro: o símbolo numa linha nova depois do corpo. É onde vai um `end` ou um
        // `}` que fecha bloco, e é onde a pessoa digitaria.
        // Linha em branco no fim não conta: o arquivo quase sempre termina com quebra, e
        // o `end` vai logo depois do corpo, não depois do vazio.
        var ultima = min(ateLinha, linhas.count) - 1
        while ultima > 0, linhas[ultima].trimmingCharacters(in: .whitespaces).isEmpty {
            ultima -= 1
        }
        if linhas.indices.contains(ultima) {
            for ficha in candidatos where ficha.count > 1 || "}])".contains(ficha) {
                var tentativa = linhas
                tentativa.insert(ficha, at: ultima + 1)
                guard !temErro(tentativa.joined(separator: "\n"), lang) else { continue }
                return LintIssue(
                    rule: "falta-simbolo",
                    message: tr("falta `%1$@` aqui", ficha),
                    severity: .error,
                    line: ultima + 2,
                    column: 1,
                    length: 1
                )
            }
        }
        let alvos = (deLinha ... ateLinha).reversed().map { $0 - 1 }.filter { linhas.indices.contains($0) }
        for alvo in alvos {
            let original = linhas[alvo]
            guard !original.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            for ficha in candidatos {
                linhas[alvo] = original + ficha
                let tentativa = linhas.joined(separator: "\n")
                linhas[alvo] = original
                guard !temErro(tentativa, lang) else { continue }
                return LintIssue(
                    rule: "falta-simbolo",
                    message: tr("falta `%1$@` aqui", ficha),
                    severity: .error,
                    line: alvo + 1,
                    column: max(1, original.count + 1),
                    length: 1
                )
            }
        }
        return nil
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
