import Foundation

/// Um caminho de import dentro do texto, e onde ele está.
public struct ImportLink: Sendable, Hashable {
    /// O que estava escrito entre aspas: `./Card`, `../lib/api`, `@/ui/Botao`, `react`.
    public var spec: String
    /// Posição do `spec` no texto inteiro, sem as aspas.
    public var range: Range<Int>

    public init(spec: String, range: Range<Int>) {
        self.spec = spec; self.range = range
    }
}

/// Acha os caminhos de import de um arquivo e diz para qual arquivo do projeto cada um
/// aponta.
///
/// Serve para o editor sublinhar o caminho e abrir o arquivo com um toque: hoje, depois
/// de escrito, o `from "./Card"` é texto morto e descobrir onde `Card` mora é busca na
/// mão.
public enum ImportLinks {
    /// Formas que valem a pena reconhecer. Deliberadamente sem tree-sitter: isto roda a
    /// cada análise e precisa ser barato.
    private static let padroes = [
        // import x from "y", export * from "y", import "y"
        #"(?:^|[\s;])(?:import|export)\s[^"'\n]*?["']([^"'\n]+)["']"#,
        #"(?:^|[\s;])import\s*["']([^"'\n]+)["']"#,
        // require("y"), import("y")
        #"\b(?:require|import)\s*\(\s*["']([^"'\n]+)["']\s*\)"#,
        // @import "y" do CSS
        #"@import\s+(?:url\()?\s*["']([^"'\n]+)["']"#,
    ]

    public static func find(text: String, language: Language) -> [ImportLink] {
        switch language {
        case .javascript, .jsx, .typescript, .tsx, .css, .html: break
        default: return []
        }
        var achados: [ImportLink] = []
        let inteiro = NSRange(text.startIndex ..< text.endIndex, in: text)
        for p in padroes {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: text, range: inteiro) {
                guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { continue }
                let inicio = text.distance(from: text.startIndex, to: r.lowerBound)
                let fim = text.distance(from: text.startIndex, to: r.upperBound)
                let link = ImportLink(spec: String(text[r]), range: inicio ..< fim)
                // Os padrões se sobrepõem de propósito; o mesmo caminho não entra duas vezes.
                if !achados.contains(where: { $0.range.lowerBound == inicio }) {
                    achados.append(link)
                }
            }
        }
        return achados.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Extensões tentadas quando o import vem sem extensão, na ordem em que um empacotador
    /// tentaria.
    public static let extensoes = ["", ".tsx", ".ts", ".jsx", ".js", ".mjs", ".css", ".json", ".svg"]

    /// Para qual arquivo do projeto este caminho aponta, se algum.
    ///
    /// - Parameters:
    ///   - spec: o que está entre aspas.
    ///   - de: caminho relativo do arquivo que contém o import.
    ///   - arquivos: todos os caminhos do projeto.
    ///   - aliases: prefixos do `tsconfig` (`"@/" -> "src/"`).
    public static func resolve(
        _ spec: String,
        de origem: String,
        arquivos: Set<String>,
        aliases: [String: String] = [:]
    ) -> String? {
        var alvo = spec
        if spec.hasPrefix("./") || spec.hasPrefix("../") {
            let pasta = origem.split(separator: "/").dropLast().map(String.init)
            alvo = juntar(pasta, spec)
        } else if let (prefixo, destino) = aliases.first(where: { spec.hasPrefix($0.key) }) {
            alvo = destino + spec.dropFirst(prefixo.count)
        } else if spec.hasPrefix("/") {
            alvo = String(spec.dropFirst())
        } else {
            // Pacote instalado: não é arquivo do projeto, e abrir dentro de node_modules
            // não é o que a pessoa quer ao tocar.
            return nil
        }
        for ext in extensoes where arquivos.contains(alvo + ext) {
            return alvo + ext
        }
        for ext in extensoes.dropFirst() where arquivos.contains(alvo + "/index" + ext) {
            return alvo + "/index" + ext
        }
        return nil
    }

    /// Junta a pasta de origem com um caminho relativo, resolvendo `.` e `..`.
    static func juntar(_ pasta: [String], _ spec: String) -> String {
        var partes = pasta
        for pedaco in spec.split(separator: "/") {
            switch pedaco {
            case ".": continue
            case "..": if !partes.isEmpty {
                    partes.removeLast()
                }
            default: partes.append(String(pedaco))
            }
        }
        return partes.joined(separator: "/")
    }

    /// Lê os apelidos de caminho do `tsconfig.json` (`paths`), que é como `@/x` vira
    /// `src/x` em projeto Vite.
    public static func aliases(tsconfig: Data?) -> [String: String] {
        guard let tsconfig,
              let j = try? JSONSerialization.jsonObject(with: tsconfig) as? [String: Any],
              let opts = j["compilerOptions"] as? [String: Any],
              let paths = opts["paths"] as? [String: Any] else { return [:] }
        let base = (opts["baseUrl"] as? String).map { $0 == "." ? "" : $0 + "/" } ?? ""
        var out: [String: String] = [:]
        for (de, para) in paths {
            guard let lista = para as? [String], let primeiro = lista.first else { continue }
            // "@/*": ["./src/*"] vira "@/" -> "src/".
            let chave = de.hasSuffix("*") ? String(de.dropLast()) : de
            var valor = primeiro.hasSuffix("*") ? String(primeiro.dropLast()) : primeiro
            if valor.hasPrefix("./") {
                valor = String(valor.dropFirst(2))
            }
            out[chave] = base + valor
        }
        return out
    }
}
