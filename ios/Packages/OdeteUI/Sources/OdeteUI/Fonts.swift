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

    public static func ui(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        if UIFont(name: sansName(weight), size: size) != nil {
            return .custom(sansName(weight), size: size)
        }
        return .system(size: size, weight: weight, design: .default)
    }

    public static func mono(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        if UIFont(name: monoName(weight), size: size) != nil {
            return .custom(monoName(weight), size: size)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    /// Rótulo de painel: 11 pt, caixa alta, espaçado.
    public static var label: Font {
        ui(11, weight: .medium)
    }
}

public enum Metrics {
    public static let railWidth: CGFloat = 52
    public static let touch: CGFloat = 44
    public static let row: CGFloat = 40
    public static let paneHeader: CGFloat = 36
    public static let tab: CGFloat = 44
    public static let minSide: CGFloat = 200
    public static let maxSide: CGFloat = 520
    public static let minAgent: CGFloat = 300
    public static let maxAgent: CGFloat = 640
    public static let minTerm: CGFloat = 120
    public static let maxTerm: CGFloat = 600
}
