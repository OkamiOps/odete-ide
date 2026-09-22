import Foundation

/// O Markdown do agente lido aos poucos, enquanto a resposta chega.
///
/// A cada lote de fichas o `MarkdownText` refazia tudo: quebrava a mensagem inteira em
/// linhas, remontava os blocos e rodava `AttributedString(markdown:)` para cada parágrafo
/// e cada item de lista — numa resposta longa, centenas de interpretações por lote para
/// mudar uma palavra no fim.
///
/// O leitor guarda o que já não muda mais. Um bloco fechado — parágrafo seguido de linha
/// em branco, título, régua, bloco de código com a cerca fechada — não muda com o que vier
/// depois, e o texto antes dele não precisa ser lido de novo. Só a cauda, do último ponto
/// seguro em diante, é relida. O resultado é o mesmo da leitura inteira: o ponto seguro é
/// um lugar onde a leitura inteira também estaria com tudo vazio, e retomar dali com o
/// estado limpo dá exatamente os mesmos blocos, com os mesmos ids.
final class LeitorDoChat {
    private var ultimo = ""
    /// Blocos que não mudam mais.
    private var prontos: [MarkdownText.Block] = []
    /// Bytes UTF-8 do texto já transformados em `prontos`.
    private var fimPronto = 0
    private var proximoId = 0
    /// O texto de cada trecho já interpretado. Com teto: a cauda muda a cada lote, e cada
    /// versão dela entraria aqui para nunca mais ser lida.
    private var inlines: [String: AttributedString] = [:]

    func blocos(_ texto: String) -> [MarkdownText.Block] {
        if fimPronto > 0, !Self.comeca(texto, com: ultimo, bytes: fimPronto) {
            prontos = []
            fimPronto = 0
            proximoId = 0
        }
        let bytes = texto.utf8
        let inicio = bytes.index(bytes.startIndex, offsetBy: fimPronto)
        let leitura = MarkdownText.ler(texto[inicio...], primeiroId: proximoId)
        var cauda = leitura.blocos
        if let seguro = leitura.seguro {
            prontos += leitura.blocos.prefix(seguro.blocos)
            cauda = Array(leitura.blocos.dropFirst(seguro.blocos))
            fimPronto = bytes.distance(from: bytes.startIndex, to: seguro.fim)
            proximoId = seguro.proximoId
        }
        ultimo = texto
        return prontos + cauda
    }

    /// `AttributedString(markdown:)` uma vez por trecho, e não uma por redesenho.
    func inline(_ t: String, _ interpretar: (String) -> AttributedString) -> AttributedString {
        if let pronto = inlines[t] {
            return pronto
        }
        if inlines.count > 400 {
            inlines.removeAll(keepingCapacity: true)
        }
        let a = interpretar(t)
        inlines[t] = a
        return a
    }

    /// Os primeiros `bytes` bytes de `a` e `b` são iguais? Comparação de memória, sem
    /// andar caractere por caractere.
    static func comeca(_ a: String, com b: String, bytes: Int) -> Bool {
        guard bytes > 0 else { return true }
        guard a.utf8.count >= bytes, b.utf8.count >= bytes else { return false }
        var a = a, b = b
        return a.withUTF8 { pa in
            b.withUTF8 { pb in
                memcmp(pa.baseAddress!, pb.baseAddress!, bytes) == 0
            }
        }
    }
}

extension MarkdownText {
    /// O resultado de uma leitura: os blocos e, quando houver, o último ponto seguro.
    struct Leitura {
        var blocos: [Block]
        /// Onde o texto já virou bloco que não muda mais: a posição logo depois da linha,
        /// quantos dos `blocos` estão antes dela e o id do próximo bloco.
        var seguro: (fim: String.Index, blocos: Int, proximoId: Int)?
    }

    /// Lê `text` com os ids começando em `primeiroId`. É a leitura de sempre — além de
    /// parágrafo e bloco de código, entende título, lista com marcador, lista numerada,
    /// citação e régua —, agora anotando onde dá para retomar.
    nonisolated static func ler(_ text: Substring, primeiroId: Int = 0) -> Leitura {
        var out: [Block] = []
        var i = primeiroId
        var inCode = false
        var lang = ""
        var code: [String] = []
        var para: [String] = []
        var list: [String] = []
        var ordered = false
        var quote: [String] = []
        var seguro: (fim: String.Index, blocos: Int, proximoId: Int)?

        func flushPara() {
            if !para.isEmpty {
                out.append(.para(i, para.joined(separator: "\n"))); i += 1; para = []
            }
        }
        func flushList() {
            if !list.isEmpty {
                out.append(.list(i, ordered, list)); i += 1; list = []
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                out.append(.quote(i, quote.joined(separator: " "))); i += 1; quote = []
            }
        }
        func flushAll() {
            flushPara(); flushList(); flushQuote()
        }

        /// Uma linha, com as mesmas regras de antes.
        func linha(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    out.append(.code(i, lang, code.joined(separator: "\n"))); i += 1; code = []; inCode = false
                } else {
                    flushAll(); inCode = true
                    lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                return
            }
            if inCode {
                code.append(line); return
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll(); out.append(.rule(i)); i += 1; return
            }
            if trimmed.hasPrefix("#") {
                flushAll()
                let level = trimmed.prefix { $0 == "#" }.count
                out.append(.heading(i, level, trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                i += 1
                return
            }
            if trimmed.hasPrefix("> ") {
                flushPara(); flushList()
                quote.append(String(trimmed.dropFirst(2)))
                return
            }
            if let item = bullet(trimmed) {
                flushPara(); flushQuote()
                if !ordered, !list.isEmpty, item.ordered {
                    flushList()
                }
                if ordered, !list.isEmpty, !item.ordered {
                    flushList()
                }
                ordered = item.ordered
                list.append(item.text)
                return
            }
            if trimmed.isEmpty {
                flushAll(); return
            }
            flushList(); flushQuote()
            para.append(line)
        }

        var comeco = text.startIndex
        while true {
            let fim = text[comeco...].firstIndex(of: "\n") ?? text.endIndex
            linha(String(text[comeco ..< fim]))
            guard fim < text.endIndex else { break }
            comeco = text.index(after: fim)
            // Linha inteira (com a quebra) e nada em aberto: daqui para trás não muda mais.
            // A última linha, sem quebra, nunca conta — ela ainda pode crescer.
            if !inCode, para.isEmpty, list.isEmpty, quote.isEmpty {
                seguro = (comeco, out.count, i)
            }
        }
        if inCode {
            out.append(.code(i, lang, code.joined(separator: "\n"))); i += 1
        }
        flushAll()
        return Leitura(blocos: out, seguro: seguro)
    }

    /// Reconhece "- item", "* item" e "1. item".
    nonisolated static func bullet(_ line: String) -> (text: String, ordered: Bool)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return (String(line.dropFirst(2)), false)
        }
        guard let dot = line.firstIndex(of: "."), line[line.startIndex ..< dot].allSatisfy(\.isNumber),
              line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " "
        else { return nil }
        return (String(line[line.index(dot, offsetBy: 2)...]), true)
    }
}
