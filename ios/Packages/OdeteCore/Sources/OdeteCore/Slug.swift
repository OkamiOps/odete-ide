import Foundation

/// Nome de repositório do jeito que o GitHub aceita.
///
/// Espaço, acento e pontuação solta fazem a API recusar a criação. Arrumar antes é
/// melhor do que devolver um erro depois de a pessoa apertar o botão.
public enum Slug {
    public static func repo(_ bruto: String) -> String {
        let base = bruto.folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
        let trocado = base.map { c -> Character in
            c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." ? c : "-"
        }
        return String(trocado).lowercased()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}
