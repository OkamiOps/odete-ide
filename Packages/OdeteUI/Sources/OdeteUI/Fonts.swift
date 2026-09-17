import SwiftUI

/// Tipografia: IBM Plex Sans e Mono (empacotadas no app), com SF como reserva.
public enum OdeteFont {
    static func sansName(_ weight: Font.Weight) -> String {
        switch weight {
        case .semibold, .bold, .heavy, .black: "IBMPlexSans-SemiBold"
        case .medium: "IBMPlexSans-Medium"
        default: "IBMPlexSans"
        }
    }

    static func monoName(_ weight: Font.Weight) -> String {
        switch weight {
        case .medium, .semibold, .bold, .heavy, .black: "IBMPlexMono-Medium"
        default: "IBMPlexMono"
        }
    }

    /// Tamanho ajustado ao que a pessoa escolheu nos Ajustes do iPad, com teto.
    ///
    /// Sem isto nada no app respeitava o tamanho de texto do sistema: tudo era ponto
    /// fixo. O teto existe porque isto aqui é um editor de código com colunas estreitas —
    /// acompanhar os tamanhos de acessibilidade inteiros quebraria a grade. Quem precisa
    /// de código maior tem o ajuste de fonte do editor, que é separado.
    /// Multiplicador escolhido nos Ajustes, por cima do tamanho do sistema. Vive numa
    /// estática porque as fontes são pedidas de dentro de dezenas de views que não têm
    /// como receber o estado, e ele muda uma vez a cada vez que alguém mexe no ajuste.
    public nonisolated(unsafe) static var escala: CGFloat = 1

    public static func escalado(_ size: CGFloat) -> CGFloat {
        let ajustado = UIFontMetrics(forTextStyle: .body).scaledValue(for: size)
        return min(max(ajustado, size * 0.9), size * 1.3) * escala
    }

    public static func ui(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        let s = escalado(size)
        if UIFont(name: sansName(weight), size: s) != nil {
            // `fixedSize` porque a conta do tamanho já foi feita acima, com teto; o
            // `relativeTo` escalaria de novo e sem limite.
            return .custom(sansName(weight), fixedSize: s)
        }
        return .system(size: s, weight: weight, design: .default)
    }

    public static func mono(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        let s = escalado(size)
        if UIFont(name: monoName(weight), size: s) != nil {
            return .custom(monoName(weight), fixedSize: s)
        }
        return .system(size: s, weight: weight, design: .monospaced)
    }

    /// Rótulo de painel: 11 pt, caixa alta, espaçado.
    public static var label: Font {
        ui(11, weight: .medium)
    }
}

public enum Metrics {
    /// Escala de espaçamento.
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 24
    public static let s6: CGFloat = 32
    /// Raios: controles, cards, painéis flutuantes.
    public static let rControl: CGFloat = 8
    public static let rCard: CGFloat = 14
    public static let rFloat: CGFloat = 20
    public static let railWidth: CGFloat = 56
    public static let touch: CGFloat = 44
    public static let row: CGFloat = 40
    public static let paneHeader: CGFloat = 40
    public static let tab: CGFloat = 44
    /// Mínimos por painel. Os máximos não são constantes: dependem do que sobra na
    /// tela e são calculados no layout, senão a alça continua andando depois que o
    /// painel já parou de crescer.
    public static let minSide: CGFloat = 200
    public static let minAgent: CGFloat = 260
    public static let minCenter: CGFloat = 320
    public static let minTerm: CGFloat = 80
}
