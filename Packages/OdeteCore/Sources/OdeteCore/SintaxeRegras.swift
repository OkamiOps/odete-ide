import Foundation
import OdeteI18n

/// Erros que um compilador daria e que dá para achar lendo o texto com cuidado.
///
/// Todas as regras aqui trabalham sobre a **máscara** do `Sintaxe`: o arquivo com
/// comentário e miolo de string trocados por espaço. Sem isso, um `;` num comentário
/// contaria como fim de linha e uma chave dentro de uma string abriria bloco.
///
/// A escolha é por precisão e não por cobertura: regra que dispara em código correto é
/// pior que regra que não existe — ela ensina a pessoa a ignorar o painel de problemas.
/// Por isso cada uma tem, no teste, um arquivo válido que não pode acusar nada.
extension Sintaxe {
    /// Linguagens onde toda instrução termina em `;`.
    ///
    /// Rust entra com uma ressalva própria: lá a última expressão de um bloco é o valor
    /// de retorno e não leva `;`. Mas essa expressão está sempre **colada no `}`** — e é
    /// isso que dá para checar sem parser: falta `;` quando a linha seguinte não é o
    /// fecho do bloco.
    static let pedemPontoEVirgula: Set<Language> = [.c, .cpp, .csharp, .java, .php, .rust]

    /// Começos de linha que, em Rust, nunca pedem `;`.
    private static let aberturasRust = [
        "fn", "impl", "trait", "mod", "pub", "struct", "enum", "match", "loop", "unsafe",
        "where", "use", "extern", "type", "const", "static", "async", "macro_rules",
    ]

    /// Começo de linha que nunca precisa de `;`.
    private static let aberturas = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "try", "catch",
        "finally", "foreach", "using", "namespace", "class", "struct", "enum", "interface",
        "record", "public", "private", "protected", "internal", "static", "abstract", "final",
        "synchronized", "lock", "unsafe", "template", "typedef", "union", "extern", "get", "set",
    ]

    /// Fim de linha que já diz que a instrução continua ou acabou.
    private static let fimQueDispensa: Set<Character> = [
        ";", "{", "}", ",", "(", "[", ":", "\\", "+", "-", "*", "/", "%",
        "=", ".", "?", ">", "<", "|", "&", "^", "!", "~", "#", "@",
    ]

    /// Começo da linha seguinte que mostra que a anterior continua.
    private static let continuacoes = [
        ".", "?", ":", ")", "]", "}", "+", "-", "*", "/", "&&", "||", "==", "!=",
        "=", ",", "=>", "->", "::", "<", ">", "|", "&",
    ]

    /// Começos de comando em SQL. Ali o `;` separa comandos: o do último é opcional, e
    /// o que falta é sempre entre um comando e o seguinte.
    private static let comandosSQL = [
        "select", "insert", "update", "delete", "create", "alter", "drop", "with",
        "truncate", "grant", "revoke", "begin", "commit", "rollback", "explain", "merge",
    ]

    public static func pontoEVirgulaSQL(text: String) -> [LintIssue] {
        let linhas = mascara(text: text, language: .sql).components(separatedBy: "\n")
        var out: [LintIssue] = []
        var anterior: (texto: String, indice: Int)?
        for (i, bruta) in linhas.enumerated() {
            let linha = bruta.trimmingCharacters(in: .whitespaces)
            if linha.isEmpty {
                continue
            }
            let primeira = linha.prefix { $0.isLetter }.lowercased()
            defer { anterior = (linha, i) }
            guard comandosSQL.contains(primeira), let ant = anterior else { continue }
            // O comando anterior fechou? Então este começa limpo.
            if ant.texto.hasSuffix(";") {
                continue
            }
            // `with ... select`, `insert ... select` e `union select` continuam o mesmo
            // comando: ali o `select` não é começo de nada.
            let antPrimeira = ant.texto.prefix { $0.isLetter }.lowercased()
            if ["with", "union", "intersect", "except"].contains(antPrimeira) {
                continue
            }
            if ant.texto.lowercased().hasSuffix("union") || ant.texto.lowercased().hasSuffix("as") {
                continue
            }
            if ant.texto.hasSuffix(",") || ant.texto.hasSuffix("(") {
                continue
            }
            if primeira == "select", ant.texto.hasSuffix(")") {
                continue
            }
            out.append(aviso(
                "falta-ponto-e-virgula",
                tr("falta `;` fechando o comando anterior"),
                ant.indice + 1,
                linhas[ant.indice].count,
                1
            ))
        }
        return out
    }

    public static func pontoEVirgula(text: String, language: Language) -> [LintIssue] {
        if language == .sql {
            return pontoEVirgulaSQL(text: text)
        }
        guard pedemPontoEVirgula.contains(language) else { return [] }
        let linhas = mascara(text: text, language: language).components(separatedBy: "\n")
        let listas = dentroDeLista(linhas)
        var out: [LintIssue] = []
        for (i, bruta) in linhas.enumerated() {
            let linha = bruta.trimmingCharacters(in: .whitespaces)
            guard let ultimo = linha.last, !fimQueDispensa.contains(ultimo) else { continue }
            // `}` ou `{` sozinhos, rótulo (`fim:`), diretiva (`#include`) e anotação (`@Override`).
            if linha.hasPrefix("#") || linha.hasPrefix("@") || linha.hasPrefix("<?") {
                continue
            }
            let primeira = linha.split(separator: " ").first.map(String.init) ?? linha
            let palavra = String(primeira.prefix { $0.isLetter || $0 == "_" })
            if aberturas.contains(palavra) {
                continue
            }
            if language == .rust {
                if aberturasRust.contains(palavra) {
                    continue
                }
                // Atributo (`#[derive(...)]`) e braço de `match` (`A => b`).
                if linha.hasPrefix("#[") || linha.contains("=>") {
                    continue
                }
                // A expressão de retorno está sempre colada no `}` que fecha o bloco. Se
                // a próxima linha não é esse fecho, então era instrução e faltou o `;`.
                if proximaComeca(linhas, depoisDe: i, com: ["}"]) {
                    continue
                }
            }
            // Cabeçalho de bloco: `if (x)`, `while (y)` e o `for` de três partes terminam
            // em `)` e a instrução vem na linha de baixo.
            if ultimo == ")" {
                continue
            }
            // Assinatura de método ou declaração que abre bloco na linha seguinte.
            if proximaComeca(linhas, depoisDe: i, com: ["{"]) {
                continue
            }
            if proximaComeca(linhas, depoisDe: i, com: continuacoes) {
                continue
            }
            // Inicializador de vetor e corpo de `enum`: lá a separação é vírgula, e a
            // falta dela é outra regra.
            if listas[i] {
                continue
            }
            out.append(aviso(
                "falta-ponto-e-virgula",
                tr("falta `;` no fim desta linha"),
                i + 1,
                bruta.count,
                1
            ))
        }
        return out
    }

    private static func proximaComeca(_ linhas: [String], depoisDe i: Int, com inicios: [String]) -> Bool {
        var j = i + 1
        while j < linhas.count {
            let l = linhas[j].trimmingCharacters(in: .whitespaces)
            if l.isEmpty {
                j += 1; continue
            }
            return inicios.contains { l.hasPrefix($0) }
        }
        return false
    }

    /// Para cada linha: ela está dentro de uma lista de valores?
    ///
    /// Numa linguagem de chaves, `{` é quase sempre bloco de instruções — mas não quando
    /// vem depois de `=` ou de `]`, que é o inicializador de vetor (`int[] n = { 1, 2 }`,
    /// `new String[] { "a", "b" }`). Ali dentro a separação é vírgula e não `;`, e as
    /// duas regras precisam saber disso: uma para não cobrar, a outra para cobrar.
    static func dentroDeLista(_ linhas: [String]) -> [Bool] {
        var out: [Bool] = []
        // Cada elemento diz se aquele nível aberto é lista de valores.
        var pilha: [Bool] = []
        for bruta in linhas {
            out.append(pilha.contains(true))
            var antes = ""
            for c in bruta {
                switch c {
                case "[":
                    pilha.append(true)
                case "{":
                    let cauda = antes.trimmingCharacters(in: .whitespaces)
                    pilha.append(cauda.hasSuffix("=") || cauda.hasSuffix("]") || cauda.hasSuffix(","))
                case "(":
                    pilha.append(false)
                case "]", "}", ")":
                    if !pilha.isEmpty {
                        pilha.removeLast()
                    }
                default:
                    break
                }
                antes.append(c)
            }
            // A linha que abre a lista já conta como dentro, para o item da linha de
            // baixo ser medido certo.
            out[out.count - 1] = out[out.count - 1] || pilha.contains(true)
        }
        return out
    }

    // MARK: - vírgula

    /// Vírgula que falta entre itens, dentro de `[`, `{` ou `(`.
    ///
    /// Vale para Python porque lá dentro de colchete só existe dado e argumento — nunca
    /// instrução. Numa linguagem de chaves, `{` é bloco e a mesma regra acusaria tudo.
    /// Palavras que, no começo da linha, dizem que a expressão de cima continua.
    private static let continuamEmPython = [
        "for ", "if ", "else", "elif ", "in ", "and ", "or ", "not ", "as ", "async ", "await ",
    ]

    /// Onde `[` e `{` são sempre lista de valores, e nunca bloco de instruções.
    ///
    /// Em Lua o bloco é `do … end`, então `{` só pode ser tabela; em TOML e Python, o
    /// mesmo. Nas linguagens de chaves só o `[` é seguro, porque ali `{` é bloco.
    private static func gruposDeDados(_ language: Language) -> Set<Character>? {
        switch language {
        case .python, .lua, .toml: ["(", "[", "{"]
        case .c, .cpp, .csharp, .java, .rust: ["["]
        default: nil
        }
    }

    public static func virgula(text: String, language: Language) -> [LintIssue] {
        guard let grupos = gruposDeDados(language) else { return [] }
        let fechas: Set<Character> = [")", "]", "}"]
        let linhas = mascara(text: text, language: language).components(separatedBy: "\n")
        // Nas linguagens de chaves, quem diz se aqui é lista é a leitura de contexto: o
        // `{` de `new String[] {` é dado, o `{` de `void f() {` é bloco.
        let porContexto = pedemPontoEVirgula.contains(language) ? dentroDeLista(linhas) : []
        var out: [LintIssue] = []
        var profundidade = 0
        for (i, bruta) in linhas.enumerated() {
            let linha = bruta.trimmingCharacters(in: .whitespaces)
            let dentro = porContexto.isEmpty ? profundidade > 0 : porContexto[i]
            profundidade += bruta.filter { grupos.contains($0) }.count
            profundidade -= bruta.filter { fechas.contains($0) }.count
            profundidade = max(0, profundidade)
            guard dentro, let ultimo = linha.last else { continue }
            // Item que já termina em vírgula, ou linha que abre ou fecha o grupo.
            if ",([{".contains(ultimo) || ":".contains(ultimo) {
                continue
            }
            if ")]}".contains(linha.first ?? " ") {
                continue
            }
            if ultimo == "\\" {
                continue
            }
            // Última linha antes de fechar: vírgula final é opcional em Python.
            if proximaComeca(linhas, depoisDe: i, com: [")", "]", "}"]) {
                continue
            }
            // Operador no fim ou no começo da próxima: a expressão continua.
            if "+-*/%=<>&|^~".contains(ultimo) {
                continue
            }
            if proximaComeca(linhas, depoisDe: i, com: continuacoes) {
                continue
            }
            // Compreensão e gerador: `v` / `for v in xs` / `if cond` são uma expressão só,
            // quebrada em linhas, e não itens de uma lista.
            if language == .python {
                if proximaComeca(linhas, depoisDe: i, com: Self.continuamEmPython) {
                    continue
                }
                if Self.continuamEmPython.contains(where: { linha.hasPrefix($0) }) {
                    continue
                }
            }
            // Numa linguagem de chaves o `[` pode ser índice no meio de uma instrução que
            // termina em `;`: ali a separação não é vírgula.
            if ultimo == ";" {
                continue
            }
            out.append(aviso("falta-virgula", tr("falta `,` entre os itens"), i + 1, bruta.count, 1))
        }
        return out
    }

    // MARK: - fim de bloco

    /// `end` que falta, que é a chave que falta das linguagens que não usam chave.
    public static func fimDeBloco(text: String, language: Language) -> [LintIssue] {
        let abre: [String]
        switch language {
        case .ruby: abre = ["def", "class", "module", "do", "begin", "case", "unless", "while", "until", "if", "for"]
        case .lua: abre = ["function", "do", "if", "for", "while"]
        case .elixir: abre = ["def", "defp", "defmodule", "do", "case", "cond", "if", "unless", "receive", "try"]
        default: return []
        }
        let linhas = mascara(text: text, language: language).components(separatedBy: "\n")
        var pilha: [(String, Int)] = []
        var out: [LintIssue] = []
        for (i, bruta) in linhas.enumerated() {
            let linha = bruta.trimmingCharacters(in: .whitespaces)
            if linha.isEmpty {
                continue
            }
            var palavras = linha.split(whereSeparator: { !$0.isLetter && $0 != "_" }).map(String.init)
            // `local function f()` abre bloco igual a `function f()`.
            if language == .lua, palavras.first == "local" {
                palavras.removeFirst()
            }
            guard let primeira = palavras.first else { continue }
            if primeira == "end" || linha == "end" {
                if pilha.isEmpty {
                    out.append(aviso("end-sem-abertura", tr("`end` sem bloco aberto"), i + 1, 1, 3))
                } else {
                    pilha.removeLast()
                }
                continue
            }
            // `if x then y end` e `def f(x), do: x` cabem numa linha só: abrem e fecham.
            if palavras.contains("end") {
                continue
            }
            if language == .elixir, linha.contains(", do:") {
                continue
            }
            // Modificador de linha do Ruby: `faz if cond` não abre bloco.
            if language == .ruby, ["if", "unless", "while", "until"].contains(primeira) == false,
               palavras.contains(where: { ["if", "unless", "while", "until"].contains($0) })
            {
                continue
            }
            // `lista.each do |x|` abre bloco como qualquer `do`, e é a forma mais comum
            // de bloco em Ruby — sem isto o `end` dele fechava o `def` de cima.
            let comBloco = linha.hasSuffix(" do") || linha.range(
                of: #"\bdo\s*\|[^|]*\|\s*$"#,
                options: .regularExpression
            ) != nil
            if abre.contains(primeira) || ((language == .ruby || language == .elixir) && comBloco) {
                pilha.append((primeira, i + 1))
            }
        }
        for (palavra, linha) in pilha {
            out.append(aviso(
                "falta-end",
                tr("`%1$@` aberto aqui e sem `end`", palavra),
                linha,
                1,
                palavra.count
            ))
        }
        return out.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    // MARK: - JSON

    /// Chave repetida no mesmo objeto. O `JSONSerialization` aceita calado e fica com a
    /// última — o valor que a pessoa escreveu primeiro some sem aviso nenhum.
    public static func chavesRepetidas(text: String) -> [LintIssue] {
        var out: [LintIssue] = []
        var pilha: [Set<String>] = []
        var linha = 1
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\n" {
                linha += 1
            }
            if c == "{" {
                pilha.append([])
            }
            if c == "}", !pilha.isEmpty {
                pilha.removeLast()
            }
            if c == "\"" {
                var j = text.index(after: i)
                var nome = ""
                while j < text.endIndex, text[j] != "\"" {
                    if text[j] == "\\", text.index(after: j) < text.endIndex {
                        j = text.index(after: j)
                    }
                    nome.append(text[j])
                    j = text.index(after: j)
                }
                guard j < text.endIndex else { break }
                // É chave se o próximo caractere que não é espaço for `:`.
                var k = text.index(after: j)
                while k < text.endIndex, text[k] == " " || text[k] == "\t" {
                    k = text.index(after: k)
                }
                if k < text.endIndex, text[k] == ":", !pilha.isEmpty {
                    if pilha[pilha.count - 1].contains(nome) {
                        out.append(aviso(
                            "chave-repetida",
                            tr("`%1$@` aparece duas vezes neste objeto", nome),
                            linha,
                            1,
                            nome.count + 2
                        ))
                    } else {
                        pilha[pilha.count - 1].insert(nome)
                    }
                }
                i = text.index(after: j)
                continue
            }
            i = text.index(after: i)
        }
        return out
    }

    // MARK: - nome do arquivo

    /// Em Java o tipo público tem que se chamar como o arquivo. É erro de compilação, e
    /// dos que mais pegam quem renomeia arquivo pelo gerenciador.
    public static func nomeDoTipo(text: String, language: Language, path: String) -> [LintIssue] {
        guard language == .java else { return [] }
        let arquivo = (path as NSString).lastPathComponent
        let esperado = (arquivo as NSString).deletingPathExtension
        guard !esperado.isEmpty else { return [] }
        let corpo = mascara(text: text, language: language)
        let rx = try? NSRegularExpression(
            pattern: #"^\s*public\s+(?:final\s+|abstract\s+)?(class|interface|enum|record)\s+([A-Za-z_$][\w$]*)"#,
            options: [.anchorsMatchLines]
        )
        guard let rx else { return [] }
        let ns = corpo as NSString
        for m in rx.matches(in: corpo, range: NSRange(location: 0, length: ns.length)) {
            let nome = ns.substring(with: m.range(at: 2))
            guard nome != esperado else { continue }
            let linha = 1 + corpo.prefix(m.range.location).filter { $0 == "\n" }.count
            return [aviso(
                "nome-do-arquivo",
                tr("o tipo público `%1$@` precisa estar em %2$@.java", nome, nome),
                linha,
                1,
                nome.count
            )]
        }
        return []
    }
}
