import Foundation
import OdeteI18n

/// Erros de sintaxe que dá para achar sem ter o compilador da linguagem no aparelho.
///
/// A Odete não tem rustc, gcc nem python. O que ela pode fazer honestamente é o que
/// pega a maior parte dos erros de digitação em qualquer linguagem de chaves: delimitador
/// que não fecha, delimitador que fecha o errado, e texto que abre e não termina.
///
/// Para isso é preciso saber onde é código e onde não é — um `}` dentro de uma string ou
/// de um comentário não é erro nenhum. Daí o `Dialeto`: cada linguagem diz como marca
/// comentário e texto, e o resto do percurso é o mesmo para todas.
public enum Sintaxe {
    /// Como uma linguagem marca comentário, texto e delimitador.
    public struct Dialeto: Sendable {
        /// Começo de comentário até o fim da linha.
        public var linha: [String]
        /// Comentário de bloco, com abertura e fechamento.
        public var bloco: [Par]
        /// Aspas que abrem texto de uma linha só.
        public var aspas: [Character]
        /// Texto que pode atravessar linhas (`"""` do Python, crase do JS).
        public var multilinha: [String]
        /// Caractere que escapa o próximo dentro de um texto.
        public var escape: Character?
        /// Pares de delimitador a conferir.
        public var pares: [Par]

        public struct Par: Sendable {
            public var abre: String
            public var fecha: String
            public init(_ abre: String, _ fecha: String) {
                self.abre = abre
                self.fecha = fecha
            }
        }

        public init(
            linha: [String] = [],
            bloco: [Par] = [],
            aspas: [Character] = ["\"", "'"],
            multilinha: [String] = [],
            escape: Character? = "\\",
            pares: [Par] = [Par("(", ")"), Par("[", "]"), Par("{", "}")]
        ) {
            self.linha = linha
            self.bloco = bloco
            self.aspas = aspas
            self.multilinha = multilinha
            self.escape = escape
            self.pares = pares
        }
    }

    /// As chaves em `{ }` e os comentários em `/* */` e `//` cobrem a família inteira do
    /// C: C, C++, C#, Java, Go, Rust, PHP, Swift, JS, CSS, SCSS.
    static let chaves = Dialeto(linha: ["//"], bloco: [.init("/*", "*/")])

    public static func dialeto(_ language: Language) -> Dialeto? {
        switch language {
        case .c, .cpp, .csharp, .java, .go, .rust, .swift, .scss, .css:
            chaves
        case .javascript, .jsx, .typescript, .tsx:
            Dialeto(linha: ["//"], bloco: [.init("/*", "*/")], aspas: ["\"", "'"], multilinha: ["`"])
        case .php:
            Dialeto(linha: ["//", "#"], bloco: [.init("/*", "*/")])
        case .json:
            // O JSON de verdade é conferido pelo `JSONSerialization`, que dá a posição
            // exata. Aqui não entra para não dar dois recados do mesmo erro.
            nil
        case .python:
            Dialeto(linha: ["#"], aspas: ["\"", "'"], multilinha: ["\"\"\"", "'''"])
        case .ruby:
            Dialeto(linha: ["#"], bloco: [.init("=begin", "=end")])
        case .bash:
            // `$(...)` e `${...}` são comuns; aspas simples no shell não escapam nada.
            Dialeto(linha: ["#"], escape: "\\")
        case .lua:
            Dialeto(linha: ["--"], bloco: [.init("--[[", "]]")], multilinha: ["[["])
        case .sql:
            Dialeto(linha: ["--"], bloco: [.init("/*", "*/")], aspas: ["'", "\""])
        case .toml:
            Dialeto(linha: ["#"], multilinha: ["\"\"\"", "'''"], pares: [.init("[", "]"), .init("{", "}")])
        case .perl:
            Dialeto(linha: ["#"])
        case .r:
            Dialeto(linha: ["#"])
        case .haskell:
            Dialeto(linha: ["--"], bloco: [.init("{-", "-}")], aspas: ["\""])
        case .elixir:
            Dialeto(linha: ["#"], aspas: ["\""], multilinha: ["\"\"\""])
        case .elm:
            Dialeto(linha: ["--"], bloco: [.init("{-", "-}")], aspas: ["\""])
        case .ocaml:
            Dialeto(linha: [], bloco: [.init("(*", "*)")], aspas: ["\""])
        case .julia:
            Dialeto(linha: ["#"], bloco: [.init("#=", "=#")], aspas: ["\""], multilinha: ["\"\"\""])
        case .latex:
            Dialeto(linha: ["%"], aspas: [], pares: [.init("{", "}"), .init("[", "]")])
        case .html, .xml, .astro, .svelte, .markdown, .yaml, .plain:
            // Marcação não se confere por chaves: tag é outro assunto, e YAML e Markdown
            // não têm delimitador para casar.
            nil
        }
    }

    /// Confere delimitadores e textos que não terminam.
    public static func problemas(text: String, language: Language) -> [LintIssue] {
        guard let d = dialeto(language) else { return [] }
        var out: [LintIssue] = []
        var pilha: [(abre: String, linha: Int, coluna: Int)] = []
        let fechaDe = Dictionary(uniqueKeysWithValues: d.pares.map { ($0.abre, $0.fecha) })
        let abreDe = Dictionary(uniqueKeysWithValues: d.pares.map { ($0.fecha, $0.abre) })

        let chars = Array(text)
        var i = 0, linha = 1, coluna = 1

        func casa(_ token: String, em j: Int) -> Bool {
            let t = Array(token)
            guard j + t.count <= chars.count else { return false }
            for k in 0 ..< t.count where chars[j + k] != t[k] {
                return false
            }
            return true
        }

        func anda(_ n: Int) {
            for k in 0 ..< n where i + k < chars.count {
                if chars[i + k] == "\n" {
                    linha += 1
                    coluna = 1
                } else {
                    coluna += 1
                }
            }
            i += n
        }

        laco: while i < chars.count {
            // comentário de linha
            for marca in d.linha where casa(marca, em: i) {
                while i < chars.count, chars[i] != "\n" {
                    anda(1)
                }
                continue laco
            }
            // comentário de bloco
            for par in d.bloco where casa(par.abre, em: i) {
                anda(par.abre.count)
                while i < chars.count, !casa(par.fecha, em: i) {
                    anda(1)
                }
                if i < chars.count {
                    anda(par.fecha.count)
                }
                continue laco
            }
            // texto de várias linhas
            for marca in d.multilinha where casa(marca, em: i) {
                let inicio = (linha, coluna)
                anda(marca.count)
                while i < chars.count, !casa(marca, em: i) {
                    if let esc = d.escape, chars[i] == esc {
                        anda(1)
                    }
                    anda(1)
                }
                if i >= chars.count {
                    out.append(aviso(
                        "texto-aberto",
                        tr("texto aberto com %1$@ e não fechado", marca),
                        inicio.0,
                        inicio.1,
                        marca.count
                    ))
                } else {
                    anda(marca.count)
                }
                continue laco
            }
            // texto de uma linha
            if d.aspas.contains(chars[i]) {
                let aspa = chars[i], inicio = (linha, coluna)
                anda(1)
                var fechou = false
                while i < chars.count, chars[i] != "\n" {
                    if let esc = d.escape, chars[i] == esc, i + 1 < chars.count {
                        anda(2); continue
                    }
                    if chars[i] == aspa {
                        anda(1)
                        fechou = true
                        break
                    }
                    anda(1)
                }
                if !fechou {
                    out.append(aviso(
                        "texto-aberto",
                        tr("texto aberto com %1$@ e não fechado nesta linha", String(aspa)),
                        inicio.0,
                        inicio.1,
                        1
                    ))
                }
                continue laco
            }
            let c = String(chars[i])
            if fechaDe[c] != nil {
                pilha.append((c, linha, coluna))
                anda(1)
                continue
            }
            if let esperado = abreDe[c] {
                if let topo = pilha.last {
                    if topo.abre == esperado {
                        pilha.removeLast()
                    } else {
                        out.append(aviso(
                            "par-trocado",
                            tr("`%1$@` fecha o `%2$@` da linha %3$@", c, topo.abre, "\(topo.linha)"),
                            linha,
                            coluna,
                            1
                        ))
                        pilha.removeLast()
                    }
                } else {
                    out.append(aviso("sem-abertura", tr("`%1$@` sem abertura", c), linha, coluna, 1))
                }
                anda(1)
                continue
            }
            anda(1)
        }

        // O que sobrou aberto: o recado aponta para onde abriu, que é onde se conserta.
        for aberto in pilha {
            out.append(aviso(
                "sem-fechamento",
                tr("`%1$@` aberto aqui e nunca fechado", aberto.abre),
                aberto.linha,
                aberto.coluna,
                1
            ))
        }
        return out.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    private static func aviso(_ regra: String, _ msg: String, _ l: Int, _ c: Int, _ n: Int) -> LintIssue {
        LintIssue(rule: regra, message: msg, severity: .error, line: l, column: c, length: n)
    }

    // MARK: - marcação

    /// Tags de HTML e XML que abrem e não fecham, e o contrário.
    ///
    /// O HTML tem tags que fecham sozinhas e é tolerante com `<li>` solto — então só se
    /// reclama do que é erro em qualquer leitura: fechar uma tag que não estava aberta,
    /// e fechar a tag errada.
    public static func marcacao(text: String, language: Language) -> [LintIssue] {
        guard [.html, .xml, .astro, .svelte].contains(language) else { return [] }
        let vazias: Set = [
            "area", "base", "br", "col", "embed", "hr", "img", "input",
            "link", "meta", "param", "source", "track", "wbr", "!doctype", "?xml",
        ]
        var out: [LintIssue] = []
        var pilha: [(nome: String, linha: Int)] = []
        let rx = try? NSRegularExpression(
            pattern: #"<(/?)([a-zA-Z!?][\w:.-]*)([^<>]*?)(/?)>"#,
            options: [.dotMatchesLineSeparators]
        )
        let ns = text as NSString
        guard let rx else { return [] }
        // Comentário e CDATA saem antes: `<!-- <div> -->` não abre nada.
        let limpo = text
            .replacingOccurrences(of: #"<!--.*?-->"#, with: "", options: [.regularExpression])
            .replacingOccurrences(of: #"(?s)<script\b.*?</script>"#, with: "", options: [.regularExpression])
            .replacingOccurrences(of: #"(?s)<style\b.*?</style>"#, with: "", options: [.regularExpression])
        let alvo = limpo as NSString
        _ = ns
        for m in rx.matches(in: limpo, range: NSRange(location: 0, length: alvo.length)) {
            let fechando = alvo.substring(with: m.range(at: 1)) == "/"
            let nome = alvo.substring(with: m.range(at: 2)).lowercased()
            let autoFecha = alvo.substring(with: m.range(at: 4)) == "/"
            let linha = 1 + limpo.prefix(m.range.location).filter { $0 == "\n" }.count
            if vazias.contains(nome) || autoFecha {
                continue
            }
            if fechando {
                if let topo = pilha.last, topo.nome == nome {
                    pilha.removeLast()
                } else if let idx = pilha.lastIndex(where: { $0.nome == nome }) {
                    let faltou = pilha[(idx + 1)...].map(\.nome).joined(separator: ", ")
                    out.append(aviso(
                        "tag-trocada",
                        tr("`</%1$@>` fecha antes de `%2$@`", nome, faltou),
                        linha,
                        1,
                        nome.count + 3
                    ))
                    pilha.removeSubrange(idx...)
                } else {
                    out.append(aviso("tag-sem-abertura", tr("`</%1$@>` sem abertura", nome), linha, 1, nome.count + 3))
                }
            } else {
                pilha.append((nome, linha))
            }
        }
        for aberta in pilha {
            out.append(aviso(
                "tag-sem-fechamento",
                tr("`<%1$@>` aberta aqui e nunca fechada", aberta.nome),
                aberta.linha,
                1,
                aberta.nome.count + 2
            ))
        }
        return out.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    // MARK: - Python

    /// O que dá para conferir em Python sem interpretador: a linha que pede bloco e não
    /// termina em `:`, e tabulação misturada com espaço na indentação — que é erro de
    /// sintaxe de verdade em Python, e invisível na tela.
    public static func python(text texto: String) -> [LintIssue] {
        var out: [LintIssue] = []
        let pedemBloco = [
            "def ",
            "class ",
            "if ",
            "elif ",
            "else",
            "for ",
            "while ",
            "try",
            "except",
            "finally",
            "with ",
        ]
        for (i, bruta) in texto.components(separatedBy: "\n").enumerated() {
            guard let corte = bruta.range(of: "#")?.lowerBound else {
                conferePython(bruta, i, pedemBloco, &out)
                continue
            }
            conferePython(String(bruta[..<corte]), i, pedemBloco, &out)
        }
        return out
    }

    private static func conferePython(_ linha: String, _ i: Int, _ pedemBloco: [String], _ out: inout [LintIssue]) {
        let recuo = linha.prefix { $0 == " " || $0 == "\t" }
        if recuo.contains("\t"), recuo.contains(" ") {
            out.append(aviso(
                "py-recuo",
                tr("espaço e tabulação misturados no recuo"),
                i + 1,
                1,
                recuo.count
            ))
        }
        let corpo = linha.trimmingCharacters(in: .whitespaces)
        guard !corpo.isEmpty, pedemBloco.contains(where: { corpo.hasPrefix($0) || corpo == String($0.dropLast()) }),
              !corpo.hasSuffix(":"), !corpo.hasSuffix("\\"), !corpo.contains("#")
        else { return }
        // Linha que continua (parêntese aberto) é caso normal; só reclama do que fecha.
        guard corpo.filter({ $0 == "(" }).count == corpo.filter({ $0 == ")" }).count else { return }
        out.append(aviso("py-dois-pontos", tr("falta `:` no fim desta linha"), i + 1, linha.count, 1))
    }

    private static func chaveTr(_ frase: String) -> String {
        tr(frase)
    }
}
