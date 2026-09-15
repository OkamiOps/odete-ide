import Foundation
import OdeteCore

public struct SearchHit: Identifiable, Hashable, Sendable {
    public var path: String
    public var line: Int // 1-based
    public var column: Int // 1-based
    public var text: String // linha inteira
    public var id: String {
        "\(path):\(line):\(column)"
    }
}

public enum TextSearch {
    /// Busca literal (sem distinguir caixa) ou regex em todos os arquivos de texto do projeto.
    public static func search(
        root: URL,
        query: String,
        regex: Bool = false,
        caseSensitive: Bool = false,
        limit: Int = 2000
    ) throws -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        let tree = try FileTreeBuilder.build(at: root)
        var hits: [SearchHit] = []
        let pattern: Regex<AnyRegexOutput>? = regex ? try Regex(query) : nil
        for node in tree.allFiles() {
            let u = root.appending(path: node.path)
            guard let data = try? Data(contentsOf: u), data.count < 2_000_000, !looksBinary(data) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            var lineNo = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                lineNo += 1
                let s = String(line)
                if let pattern {
                    let p = caseSensitive ? pattern : pattern.ignoresCase()
                    if let m = s.firstMatch(of: p) {
                        hits.append(SearchHit(
                            path: node.path,
                            line: lineNo,
                            column: s.distance(from: s.startIndex, to: m.range.lowerBound) + 1,
                            text: s
                        ))
                    }
                } else {
                    let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
                    if let r = s.range(of: query, options: opts) {
                        hits.append(SearchHit(
                            path: node.path,
                            line: lineNo,
                            column: s.distance(from: s.startIndex, to: r.lowerBound) + 1,
                            text: s
                        ))
                    }
                }
                if hits.count >= limit {
                    return hits
                }
            }
        }
        return hits
    }

    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(512).contains(0)
    }
}

public extension TextSearch {
    /// Troca o que a busca achou, arquivo por arquivo, e devolve quantas trocas em
    /// quantos arquivos. Buscar sem poder trocar obriga a abrir um por um na mão.
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
        let pattern: Regex<AnyRegexOutput>? = regex ? try Regex(query) : nil
        var arquivos = 0
        var trocas = 0
        for path in paths {
            let u = root.appending(path: path)
            guard let data = try? Data(contentsOf: u), data.count < 2_000_000, !looksBinary(data) else { continue }
            let texto = String(decoding: data, as: UTF8.self)
            var novo = texto
            var noArquivo = 0
            if let pattern {
                noArquivo = texto.ranges(of: pattern).count
                guard noArquivo > 0 else { continue }
                novo = texto.replacing(pattern, with: replacement)
            } else {
                let opcoes: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
                noArquivo = texto.components(separatedBy: query).count - 1
                if !caseSensitive {
                    noArquivo = contar(texto, query)
                }
                guard noArquivo > 0 else { continue }
                novo = texto.replacingOccurrences(of: query, with: replacement, options: opcoes)
            }
            guard novo != texto else { continue }
            try novo.write(to: u, atomically: true, encoding: .utf8)
            arquivos += 1
            trocas += noArquivo
        }
        return (arquivos, trocas)
    }

    private static func contar(_ texto: String, _ alvo: String) -> Int {
        var n = 0
        var i = texto.startIndex
        while let r = texto.range(of: alvo, options: [.caseInsensitive], range: i ..< texto.endIndex) {
            n += 1
            i = r.upperBound
        }
        return n
    }
}
