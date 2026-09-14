import OdeteCore
import SwiftUI

public extension Color {
    /// "#rrggbb" → Color. Inválido vira magenta para ficar visível.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            s.removeFirst()
        }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = .pink
            return
        }
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Tema pronto para SwiftUI, derivado de `ThemePalette`.
public struct Theme: Sendable, Hashable {
    public let palette: ThemePalette
    public var id: ThemeId {
        palette.id
    }

    public var dark: Bool {
        palette.dark
    }

    public var bg: Color {
        Color(hex: palette.bg)
    }

    public var bgElevated: Color {
        Color(hex: palette.bgElevated)
    }

    public var bgSubtle: Color {
        Color(hex: palette.bgSubtle)
    }

    public var fg: Color {
        Color(hex: palette.fg)
    }

    public var fgMuted: Color {
        Color(hex: palette.fgMuted)
    }

    public var fgSubtle: Color {
        Color(hex: palette.fgSubtle)
    }

    public var border: Color {
        Color(hex: palette.border)
    }

    public var borderStrong: Color {
        Color(hex: palette.borderStrong)
    }

    public var accent: Color {
        Color(hex: palette.accent)
    }

    public var accentFg: Color {
        Color(hex: palette.accentFg)
    }

    public var danger: Color {
        Color(hex: palette.danger)
    }

    public var ok: Color {
        Color(hex: palette.ok)
    }

    /// Fundo de painel: um degrau acima do `bg`, sem borda.
    public var surface: Color {
        bgElevated
    }

    /// Separador discreto (a borda a 60 %).
    public var separator: Color {
        border.opacity(0.6)
    }

    /// Tinta do vidro para seleção e destaque.
    public var glassTint: Color {
        accent.opacity(0.18)
    }

    public var colorScheme: ColorScheme {
        dark ? .dark : .light
    }

    public init(_ palette: ThemePalette) {
        self.palette = palette
    }

    public init(id: ThemeId) {
        palette = ThemePalette.by(id)
    }

    public static let odete = Theme(id: .odete)
}

public extension EnvironmentValues {
    @Entry var theme: Theme = .odete
    /// Largura do painel que está desenhando. Os cartões usam isto para virar a versão
    /// compacta em vez de espremer rótulo até virar reticências.
    @Entry var paneWidth: CGFloat = 320
}

public extension View {
    /// Aplica o tema no ambiente e o esquema de cores correspondente.
    func odeteTheme(_ theme: Theme) -> some View {
        environment(\.theme, theme)
            .preferredColorScheme(theme.colorScheme)
            .tint(theme.accent)
    }
}
