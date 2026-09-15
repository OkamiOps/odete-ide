import Foundation

/// Os idiomas que a Odete fala. `sistema` é o padrão: segue o aparelho, e é o que
/// a pessoa nunca precisa escolher.
public enum Idioma: String, CaseIterable, Sendable, Identifiable, Codable {
    case sistema
    case ptBR = "pt-BR"
    case en
    case de
    case fr
    case es

    public var id: String {
        rawValue
    }

    /// Os que têm tabela de tradução, na ordem em que aparecem nos Ajustes.
    public static let traduzidos: [Idioma] = [.ptBR, .en, .de, .fr, .es]

    /// O nome escrito no próprio idioma: quem abriu os Ajustes num idioma que não lê
    /// precisa reconhecer o dele na lista sem entender o resto da tela.
    public var nome: String {
        switch self {
        case .sistema: tr(tr("Idioma do aparelho"))
        case .ptBR: "Português (Brasil)"
        case .en: "English"
        case .de: "Deutsch"
        case .fr: "Français"
        case .es: "Español"
        }
    }

    public var bandeira: String {
        switch self {
        case .sistema: "🌐"
        case .ptBR: "🇧🇷"
        case .en: "🇺🇸"
        case .de: "🇩🇪"
        case .fr: "🇫🇷"
        case .es: "🇪🇸"
        }
    }

    /// O código de `.lproj` dentro do bundle. `sistema` resolve pela lista de idiomas
    /// preferidos do aparelho, na ordem; se nenhum bate, cai no português.
    public var codigo: String {
        if self != .sistema {
            return rawValue
        }
        return Self.doAparelho.rawValue
    }

    /// O primeiro idioma preferido do aparelho que a Odete fala. `pt-PT` também cai em
    /// `pt-BR`: é mais perto do que o inglês, e a alternativa era não entender `pt` nenhum.
    public static var doAparelho: Idioma {
        for tag in Locale.preferredLanguages {
            let base = tag.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
            switch base {
            case "pt": return .ptBR
            case "en": return .en
            case "de": return .de
            case "fr": return .fr
            case "es": return .es
            default: continue
            }
        }
        return .ptBR
    }

    /// Como o idioma se chama dentro de um prompt. Em inglês de propósito: é assim
    /// que o modelo reconhece o pedido sem ambiguidade, mesmo quando o resto do
    /// prompt está em português.
    public var paraOModelo: String {
        switch self {
        case .sistema: Self.doAparelho.paraOModelo
        case .ptBR: "Brazilian Portuguese"
        case .en: "English"
        case .de: "German"
        case .fr: "French"
        case .es: "Spanish"
        }
    }

    /// `Locale` para formatar data, número e ordenação — não só para traduzir texto.
    public var locale: Locale {
        Locale(identifier: codigo.replacingOccurrences(of: "-", with: "_"))
    }
}
