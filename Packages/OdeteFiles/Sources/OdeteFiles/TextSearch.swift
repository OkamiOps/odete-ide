import Foundation
import OdeteCore

public struct SearchHit: Identifiable, Hashable, Sendable {
    public var path: String
    public var line: Int // 1-based
    public var column: Int // 1-based, em UTF-16
    public var text: String // linha inteira
    /// Quantas ocorrências há nesta linha. A lista mostra uma linha por vez, mas a troca
    /// troca todas — e é esta soma que a confirmação anuncia.
    public var ocorrencias = 1
    public var id: String {
        "\(path):\(line):\(column)"
    }
}

/// O que procurar, com as opções da busca. A busca e a troca usam esta mesma consulta —
/// antes cada uma montava a sua, e elas discordavam: `^import` achava toda linha e trocava
/// só a primeira de cada arquivo (a troca olhava o arquivo inteiro sem `^` casar em cada
/// linha), e com "Aa" desligado a busca achava "Button" e a troca por regex não.
public struct ConsultaDeTexto: Sendable, Equatable {
    public var texto: String
    public var regex: Bool
    public var caseSensitive: Bool

    public init(texto: String, regex: Bool = false, caseSensitive: Bool = false) {
        self.texto = texto
        self.regex = regex
        self.caseSensitive = caseSensitive
    }

    /// A expressão: `^` e `$` casam em cada linha (como no localizar do editor), e sem
    /// "Aa" a caixa não importa — nem no texto literal, nem na regex.
    public func expressao() throws -> NSRegularExpression {
        var opcoes: NSRegularExpression.Options = [.anchorsMatchLines]
        if !caseSensitive {
            opcoes.insert(.caseInsensitive)
        }
        return try NSRegularExpression(
            pattern: regex ? texto : NSRegularExpression.escapedPattern(for: texto),
            options: opcoes
        )
    }

    /// As ocorrências em `texto`, em UTF-16. Casamento vazio (`x*`, `^`) não conta: não
    /// há o que trocar nele, e o editor também o ignora.
    public func ocorrencias(em texto: String, _ re: NSRegularExpression? = nil) throws -> [NSTextCheckingResult] {
        let re = try re ?? expressao()
        return re.matches(in: texto, range: NSRange(location: 0, length: (texto as NSString).length))
            .filter { $0.range.length > 0 }
    }

    /// `texto` com as ocorrências trocadas e quantas foram. Em regex, `$1` na troca é o
    /// primeiro grupo, como no substituir do editor; no texto literal, a troca entra como
    /// está.
    public func trocar(em texto: String, por troca: String, _ re: NSRegularExpression? = nil) throws
        -> (texto: String, trocas: Int)
    {
        let re = try re ?? expressao()
        let achados = try ocorrencias(em: texto, re)
        guard !achados.isEmpty else { return (texto, 0) }
        let ns = texto as NSString
        var out = ""
        var cursor = 0
        for m in achados {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += regex ? re.replacementString(for: m, in: texto, offset: 0, template: troca) : troca
            cursor = NSMaxRange(m.range)
        }
        out += ns.substring(from: cursor)
        return (out, achados.count)
    }
}

public enum TextSearch {
    /// Busca literal ou regex em todos os arquivos de texto do projeto. `abertos` são os
    /// textos das abas abertas: é neles que se procura, e não no disco, para a lista
    /// mostrar o que está na tela — com o que ainda não foi salvo.
    public static func search(
        root: URL,
        query: String,
        regex: Bool = false,
        caseSensitive: Bool = false,
        limit: Int = 2000,
        abertos: [String: String] = [:]
    ) throws -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        let consulta = ConsultaDeTexto(texto: query, regex: regex, caseSensitive: caseSensitive)
        let re = try consulta.expressao()
        let tree = try FileTreeBuilder.build(at: root)
        var hits: [SearchHit] = []
        for node in tree.allFiles() {
            guard let text = abertos[node.path] ?? ler(root.appending(path: node.path)) else { continue }
            hits += try linhas(consulta, re, em: text, path: node.path)
            if hits.count >= limit {
                return Array(hits.prefix(limit))
            }
        }
        return hits
    }

    /// Texto de um arquivo que a busca e a troca aceitam: UTF-8, sem cara de binário e
    /// com menos de 2 MB.
    public static func ler(_ u: URL) -> String? {
        guard let data = try? Data(contentsOf: u), data.count < 2_000_000, !looksBinary(data) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Uma entrada por linha com ocorrência. Linhas contadas por `\n`, `\r\n` e `\r`, como
    /// o editor conta — separar por `"\n"` numa `String` não parte linha CRLF nenhuma
    /// (`"\r\n"` é um caractere só em Swift), e o arquivo inteiro virava a linha 1.
    static func linhas(
        _ consulta: ConsultaDeTexto,
        _ re: NSRegularExpression,
        em texto: String,
        path: String
    ) throws -> [SearchHit] {
        let achados = try consulta.ocorrencias(em: texto, re)
        guard !achados.isEmpty else { return [] }
        let ns = texto as NSString
        var out: [SearchHit] = []
        var linha = 1
        var inicioDaLinha = 0
        var pos = 0
        for m in achados {
            while pos < m.range.location {
                let c = ns.character(at: pos)
                if c == 10 || c == 13 {
                    if c == 13, pos + 1 < ns.length, ns.character(at: pos + 1) == 10 {
                        pos += 1
                    }
                    linha += 1
                    inicioDaLinha = pos + 1
                }
                pos += 1
            }
            if let ultimo = out.last, ultimo.line == linha {
                out[out.count - 1].ocorrencias += 1
                continue
            }
            var fim = inicioDaLinha
            while fim < ns.length, ![10, 13].contains(ns.character(at: fim)) {
                fim += 1
            }
            out.append(SearchHit(
                path: path,
                line: linha,
                column: max(m.range.location - inicioDaLinha, 0) + 1,
                text: ns.substring(with: NSRange(location: inicioDaLinha, length: fim - inicioDaLinha))
            ))
        }
        return out
    }

    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(512).contains(0)
    }
}

public extension TextSearch {
    /// Troca o que a busca achou, arquivo por arquivo, direto no disco, e devolve quantas
    /// trocas em quantos arquivos. Buscar sem poder trocar obriga a abrir um por um na mão.
    ///
    /// Usa a mesma `ConsultaDeTexto` da busca. O app não chama isto para arquivo aberto:
    /// ali a troca vai para o texto da aba, que pode ter alteração não salva.
    @discardableResult
    static func replace(
        root: URL,
        query: String,
        with replacement: String,
        regex: Bool = false,
        caseSensitive: Bool = false,
        in paths: [String]
    ) throws -> (arquivos: Int, trocas: Int) {
        guard !query.isEmpty else { return (0, 0) }
        let consulta = ConsultaDeTexto(texto: query, regex: regex, caseSensitive: caseSensitive)
        let re = try consulta.expressao()
        var arquivos = 0
        var trocas = 0
        for path in paths {
            let u = root.appending(path: path)
            guard let texto = ler(u) else { continue }
            let r = try consulta.trocar(em: texto, por: replacement, re)
            guard r.trocas > 0, r.texto != texto else { continue }
            HistoricoDeArquivos.guardar(u, raiz: root, origem: .trocarTudo)
            try r.texto.write(to: u, atomically: true, encoding: .utf8)
            arquivos += 1
            trocas += r.trocas
        }
        return (arquivos, trocas)
    }
}
