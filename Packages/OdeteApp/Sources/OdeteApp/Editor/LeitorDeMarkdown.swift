import Foundation

/// Um bloco de Markdown: o que ocupa linhas inteiras.
enum BlocoMarkdown: Equatable, Sendable {
    case titulo(nivel: Int, texto: String)
    case paragrafo(String)
    case lista(ordenada: Bool, inicio: Int, itens: [ItemDeLista])
    case citacao(String)
    case codigo(linguagem: String, texto: String)
    case regua
    /// Imagem sozinha na linha: `![alt](caminho)`.
    case imagem(alt: String, fonte: String)
    case tabela(cabecalho: [String], linhas: [[String]])
    /// HTML cru, que a prévia mostra como está em vez de fingir que interpreta.
    case html(String)
}

struct ItemDeLista: Equatable, Sendable {
    var texto: String
    /// Quantos níveis de recuo (dois espaços cada) o item tem.
    var nivel: Int
    /// `- [ ]` e `- [x]`; nulo em item comum.
    var marcado: Bool?
}

/// Lê Markdown em blocos.
///
/// Começou como cópia do leitor do chat (`MarkdownText`, em `ChatList.swift`), que já
/// entendia título, lista, citação, régua e bloco de código. Um arquivo `.md` de
/// projeto pede mais que uma resposta do agente: tabela, imagem, título sublinhado
/// (`===`/`---`), lista numerada que não começa em 1, lista dentro de lista, caixa de
/// tarefa e o cabeçalho `---` de Jekyll e Astro. O inline (ênfase, código, link) fica
/// com `AttributedString(markdown:)`, que só sabe o inline.
enum LeitorDeMarkdown {
    static func blocos(_ texto: String) -> [BlocoMarkdown] {
        var linhas = texto.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Cabeçalho YAML no topo (Jekyll, Astro, Hugo): não é conteúdo.
        if linhas.first?.trimmingCharacters(in: .whitespaces) == "---",
           let fim = linhas.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        {
            linhas.removeSubrange(0 ... fim)
        }
        var out: [BlocoMarkdown] = []
        var paragrafo: [String] = []
        var itens: [ItemDeLista] = []
        var ordenada = false
        var inicio = 1
        var citacao: [String] = []
        var html: [String] = []

        func fecharParagrafo() {
            guard !paragrafo.isEmpty else { return }
            // Quebra de linha dentro do parágrafo é espaço; só dois espaços ou `\` no fim
            // quebram de verdade.
            var t = ""
            for (i, l) in paragrafo.enumerated() {
                let dura = l.hasSuffix("  ") || l.hasSuffix("\\")
                let limpa = dura ? String(l.dropLast(l.hasSuffix("\\") ? 1 : 0)).trimmingCharacters(in: .whitespaces)
                    : l.trimmingCharacters(in: .whitespaces)
                t += limpa
                if i < paragrafo.count - 1 {
                    t += dura ? "\n" : " "
                }
            }
            out.append(.paragrafo(t))
            paragrafo = []
        }
        func fecharLista() {
            guard !itens.isEmpty else { return }
            out.append(.lista(ordenada: ordenada, inicio: inicio, itens: itens))
            itens = []
        }
        func fecharCitacao() {
            guard !citacao.isEmpty else { return }
            out.append(.citacao(citacao.joined(separator: " ")))
            citacao = []
        }
        func fecharHTML() {
            guard !html.isEmpty else { return }
            out.append(.html(html.joined(separator: "\n")))
            html = []
        }
        func fecharTudo() {
            fecharParagrafo()
            fecharLista()
            fecharCitacao()
            fecharHTML()
        }

        var i = 0
        while i < linhas.count {
            let linha = linhas[i]
            let aparada = linha.trimmingCharacters(in: .whitespaces)
            i += 1

            // Bloco cercado: ``` ou ~~~, até a mesma cerca.
            if aparada.hasPrefix("```") || aparada.hasPrefix("~~~") {
                fecharTudo()
                let cerca = String(aparada.prefix(3))
                let linguagem = String(aparada.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codigo: [String] = []
                while i < linhas.count, !linhas[i].trimmingCharacters(in: .whitespaces).hasPrefix(cerca) {
                    codigo.append(linhas[i])
                    i += 1
                }
                i += 1
                out.append(.codigo(linguagem: linguagem, texto: codigo.joined(separator: "\n")))
                continue
            }
            if !html.isEmpty {
                if aparada.isEmpty {
                    fecharHTML()
                } else {
                    html.append(linha)
                }
                continue
            }
            if aparada.isEmpty {
                fecharTudo()
                continue
            }
            // Título sublinhado: a linha de `===` ou `---` logo abaixo de um parágrafo.
            if !paragrafo.isEmpty,
               aparada.allSatisfy({ $0 == "=" }) || (aparada.count >= 2 && aparada.allSatisfy { $0 == "-" })
            {
                let titulo = paragrafo.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                paragrafo = []
                out.append(.titulo(nivel: aparada.first == "=" ? 1 : 2, texto: titulo))
                continue
            }
            if regua(aparada) {
                fecharTudo()
                out.append(.regua)
                continue
            }
            if let (nivel, t) = titulo(aparada) {
                fecharTudo()
                out.append(.titulo(nivel: nivel, texto: t))
                continue
            }
            if aparada.hasPrefix(">") {
                fecharParagrafo()
                fecharLista()
                citacao.append(String(aparada.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = item(linha) {
                fecharParagrafo()
                fecharCitacao()
                if !itens.isEmpty, item.ordenada != ordenada, item.nivel == 0 {
                    fecharLista()
                }
                if itens.isEmpty {
                    ordenada = item.ordenada
                    inicio = item.numero
                }
                itens.append(ItemDeLista(texto: item.texto, nivel: item.nivel, marcado: item.marcado))
                continue
            }
            // Linha recuada logo depois de um item: continuação dele.
            if !itens.isEmpty, linha.hasPrefix("  ") || linha.hasPrefix("\t") {
                itens[itens.count - 1].texto += " " + aparada
                continue
            }
            if !citacao.isEmpty {
                citacao.append(aparada)
                continue
            }
            if paragrafo.isEmpty, let (alt, fonte) = imagem(aparada) {
                fecharTudo()
                out.append(.imagem(alt: alt, fonte: fonte))
                continue
            }
            if paragrafo.isEmpty, aparada.contains("|"), i < linhas.count, separadorDeTabela(linhas[i]),
               let cabecalho = celulas(aparada)
            {
                fecharTudo()
                i += 1
                var corpo: [[String]] = []
                while i < linhas.count, let c = celulas(linhas[i].trimmingCharacters(in: .whitespaces)),
                      !linhas[i].trimmingCharacters(in: .whitespaces).isEmpty
                {
                    // Linha com menos células ganha vazias; com mais, perde as sobras.
                    corpo.append(Array((c + Array(repeating: "", count: cabecalho.count)).prefix(cabecalho.count)))
                    i += 1
                }
                out.append(.tabela(cabecalho: cabecalho, linhas: corpo))
                continue
            }
            if paragrafo.isEmpty, aparada.hasPrefix("<") {
                fecharTudo()
                // Comentário HTML (`<!-- TOC -->`) não aparece em prévia nenhuma.
                if aparada.hasPrefix("<!--") {
                    var fim = aparada
                    while !fim.contains("-->"), i < linhas.count {
                        fim = linhas[i]
                        i += 1
                    }
                    continue
                }
                html.append(linha)
                continue
            }
            fecharLista()
            fecharCitacao()
            paragrafo.append(linha)
        }
        fecharTudo()
        return out
    }

    static func regua(_ aparada: String) -> Bool {
        let semEspaco = aparada.filter { $0 != " " }
        guard semEspaco.count >= 3, let c = semEspaco.first, "-*_".contains(c) else { return false }
        return semEspaco.allSatisfy { $0 == c }
    }

    /// `# Título` até `###### Título`; os `#` do fim são enfeite e saem.
    static func titulo(_ aparada: String) -> (Int, String)? {
        let nivel = aparada.prefix { $0 == "#" }.count
        guard (1 ... 6).contains(nivel) else { return nil }
        let resto = aparada.dropFirst(nivel)
        guard resto.isEmpty || resto.first == " " || resto.first == "\t" else { return nil }
        var t = resto.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("#") {
            t.removeLast()
        }
        return (nivel, t.trimmingCharacters(in: .whitespaces))
    }

    /// `- item`, `* item`, `+ item`, `1. item`, `1) item`, com recuo e caixa de tarefa.
    static func item(_ linha: String) -> (texto: String, ordenada: Bool, numero: Int, nivel: Int, marcado: Bool?)? {
        let recuo = linha.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let corpo = linha.drop { $0 == " " || $0 == "\t" }
        var texto: Substring
        var ordenada = false
        var numero = 1
        if let c = corpo.first, "-*+".contains(c), corpo.dropFirst().first == " " {
            texto = corpo.dropFirst(2)
        } else {
            let digitos = corpo.prefix { $0.isNumber }
            guard !digitos.isEmpty, digitos.count <= 9 else { return nil }
            let depois = corpo.dropFirst(digitos.count)
            guard let marca = depois.first, marca == "." || marca == ")", depois.dropFirst().first == " "
            else { return nil }
            texto = depois.dropFirst(2)
            ordenada = true
            numero = Int(digitos) ?? 1
        }
        var marcado: Bool?
        if texto.hasPrefix("[ ] ") || texto.hasPrefix("[x] ") || texto.hasPrefix("[X] ") {
            marcado = texto.dropFirst().first != " "
            texto = texto.dropFirst(4)
        }
        return (texto.trimmingCharacters(in: .whitespaces), ordenada, numero, min(recuo / 2, 6), marcado)
    }

    /// `![alt](caminho "título")` ocupando a linha inteira.
    static func imagem(_ aparada: String) -> (String, String)? {
        guard aparada.hasPrefix("!["), aparada.hasSuffix(")"),
              let fechaAlt = aparada.range(of: "]("),
              !aparada[fechaAlt.upperBound...].contains("](")
        else { return nil }
        let alt = String(aparada[aparada.index(aparada.startIndex, offsetBy: 2) ..< fechaAlt.lowerBound])
        var fonte = String(aparada[fechaAlt.upperBound ..< aparada.index(before: aparada.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        // O título opcional vem depois de um espaço, entre aspas.
        if let espaco = fonte.firstIndex(of: " ") {
            fonte = String(fonte[..<espaco])
        }
        if fonte.hasPrefix("<"), fonte.hasSuffix(">") {
            fonte = String(fonte.dropFirst().dropLast())
        }
        return fonte.isEmpty ? nil : (alt, fonte)
    }

    /// As células de uma linha de tabela (`| a | b |` ou `a | b`).
    static func celulas(_ aparada: String) -> [String]? {
        guard aparada.contains("|") else { return nil }
        var t = Substring(aparada)
        if t.hasPrefix("|") {
            t = t.dropFirst()
        }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") {
            t = t.dropLast()
        }
        var out: [String] = []
        var atual = ""
        var escapado = false
        for c in t {
            if escapado {
                atual.append(c)
                escapado = false
            } else if c == "\\" {
                escapado = true
            } else if c == "|" {
                out.append(atual.trimmingCharacters(in: .whitespaces))
                atual = ""
            } else {
                atual.append(c)
            }
        }
        out.append(atual.trimmingCharacters(in: .whitespaces))
        return out
    }

    /// `|---|:---:|` — a linha que diz que a de cima é cabeçalho de tabela.
    static func separadorDeTabela(_ linha: String) -> Bool {
        guard let partes = celulas(linha.trimmingCharacters(in: .whitespaces)), !partes.isEmpty else { return false }
        return partes.allSatisfy { p in
            let miolo = p.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return miolo.count >= 1 && miolo.allSatisfy { $0 == "-" }
        }
    }
}

/// Os blocos já com o inline convertido — o trabalho que sai do ator principal.
struct BlocoPronto: Identifiable, Sendable {
    struct Item: Sendable {
        let texto: AttributedString
        let nivel: Int
        let marcado: Bool?
    }

    enum Tipo: Sendable {
        case titulo(Int, AttributedString)
        case paragrafo(AttributedString)
        case lista(ordenada: Bool, inicio: Int, [Item])
        case citacao(AttributedString)
        case codigo(String, String)
        case regua
        case imagem(alt: String, fonte: String)
        case tabela([AttributedString], [[AttributedString]])
        case html(String)
    }

    let id: Int
    let tipo: Tipo

    static func montar(_ texto: String) -> [BlocoPronto] {
        LeitorDeMarkdown.blocos(texto).enumerated().map { i, b in
            let tipo: Tipo = switch b {
            case let .titulo(n, t): .titulo(n, inline(t))
            case let .paragrafo(t): .paragrafo(inline(t))
            case let .lista(o, inicio, itens):
                .lista(
                    ordenada: o,
                    inicio: inicio,
                    itens.map { Item(texto: inline($0.texto), nivel: $0.nivel, marcado: $0.marcado) }
                )
            case let .citacao(t): .citacao(inline(t))
            case let .codigo(l, t): .codigo(l, t)
            case .regua: .regua
            case let .imagem(alt, fonte): .imagem(alt: alt, fonte: fonte)
            case let .tabela(c, l): .tabela(c.map(inline), l.map { $0.map(inline) })
            case let .html(t): .html(t)
            }
            return BlocoPronto(id: i, tipo: tipo)
        }
    }

    static func inline(_ t: String) -> AttributedString {
        (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(t)
    }
}
