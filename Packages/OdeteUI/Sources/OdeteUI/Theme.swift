import OdeteCore
import SwiftUI
import Synchronization

/// Cores já convertidas, por texto hex.
///
/// Converter "#rrggbb" é recortar texto e ler número; o tema fazia isso a cada acesso a
/// uma cor, dezenas de vezes por linha de lista, em todo corpo refeito. As paletas têm
/// algumas dezenas de cores, então guardar todas custa nada.
private let coresConvertidas = Mutex<[String: Color]>([:])

public extension Color {
    /// "#rrggbb" → Color. Inválido vira magenta para ficar visível.
    ///
    /// O mesmo texto devolve sempre a mesma cor já pronta (ver `coresConvertidas`).
    init(hex: String) {
        if let pronta = coresConvertidas.withLock({ $0[hex] }) {
            self = pronta
            return
        }
        let cor = Color.converter(hex)
        coresConvertidas.withLock { $0[hex] = cor }
        self = cor
    }

    /// A cor com opacidade, guardada como as outras: `opacity(_:)` monta uma cor nova a
    /// cada chamada, e duas instâncias do mesmo tema deixariam de ser iguais byte a byte.
    init(hex: String, opacidade: Double) {
        let chave = "\(hex)@\(opacidade)"
        if let pronta = coresConvertidas.withLock({ $0[chave] }) {
            self = pronta
            return
        }
        let cor = Color(hex: hex).opacity(opacidade)
        coresConvertidas.withLock { $0[chave] = cor }
        self = cor
    }

    private static func converter(_ hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            s.removeFirst()
        }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            return .pink
        }
        return Color(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255,
            opacity: 1
        )
    }

    /// De volta a "#rrggbb", para guardar no estado. Sai pelo espaço sRGB porque é o que
    /// o `init(hex:)` lê de volta; uma cor do seletor pode vir em outro espaço e voltar
    /// diferente da que a pessoa escolheu.
    var hexRGB: String {
        let c = UIColor(self).cgColor
        guard let srgb = c.converted(
            to: CGColorSpace(name: CGColorSpace.sRGB)!,
            intent: .defaultIntent,
            options: nil
        ), let p = srgb.components, p.count >= 3 else { return "#ff00ff" }
        func canal(_ v: CGFloat) -> Int {
            Int((min(max(v, 0), 1) * 255).rounded())
        }
        return String(format: "#%02x%02x%02x", canal(p[0]), canal(p[1]), canal(p[2]))
    }
}

/// Tema pronto para SwiftUI, derivado de `ThemePalette`.
///
/// As cores são convertidas uma vez, quando o tema nasce, e não a cada leitura. A
/// igualdade continua sendo a da paleta: duas instâncias da mesma paleta são o mesmo tema,
/// e como a conversão devolve sempre a mesma cor pronta, são iguais até byte a byte — o
/// ambiente do SwiftUI não enxerga tema novo onde não há.
public struct Theme: Sendable, Hashable {
    public let palette: ThemePalette
    /// Quando o tema acompanha o claro/escuro do iPad, o app não força esquema nenhum:
    /// forçar faria a leitura do esquema do sistema devolver o que o próprio app acabou
    /// de impor, e a escolha nunca mais mudaria sozinha.
    public var seguirSistema = false

    public let bg: Color
    public let bgElevated: Color
    public let bgSubtle: Color
    public let fg: Color
    public let fgMuted: Color
    public let fgSubtle: Color
    public let border: Color
    public let borderStrong: Color
    public let accent: Color
    public let accentFg: Color
    public let danger: Color
    public let ok: Color
    /// Separador discreto (a borda a 60 %).
    public let separator: Color
    /// Tinta do vidro para seleção e destaque.
    public let glassTint: Color

    public init(_ palette: ThemePalette, seguirSistema: Bool = false) {
        self.palette = palette
        self.seguirSistema = seguirSistema
        bg = Color(hex: palette.bg)
        bgElevated = Color(hex: palette.bgElevated)
        bgSubtle = Color(hex: palette.bgSubtle)
        fg = Color(hex: palette.fg)
        fgMuted = Color(hex: palette.fgMuted)
        fgSubtle = Color(hex: palette.fgSubtle)
        border = Color(hex: palette.border)
        borderStrong = Color(hex: palette.borderStrong)
        accent = Color(hex: palette.accent)
        accentFg = Color(hex: palette.accentFg)
        danger = Color(hex: palette.danger)
        ok = Color(hex: palette.ok)
        separator = Color(hex: palette.border, opacidade: 0.6)
        glassTint = Color(hex: palette.accent, opacidade: 0.18)
    }

    public init(_ palette: ThemePalette) {
        self.init(palette, seguirSistema: false)
    }

    public init(id: ThemeId) {
        self.init(ThemePalette.by(id))
    }

    public static func == (a: Theme, b: Theme) -> Bool {
        a.palette == b.palette && a.seguirSistema == b.seguirSistema
    }

    public func hash(into h: inout Hasher) {
        h.combine(palette)
        h.combine(seguirSistema)
    }

    public var id: ThemeId {
        palette.id
    }

    public var dark: Bool {
        palette.dark
    }

    /// Fundo de painel: um degrau acima do `bg`, sem borda.
    public var surface: Color {
        bgElevated
    }

    public var colorScheme: ColorScheme {
        dark ? .dark : .light
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
            .preferredColorScheme(theme.seguirSistema ? nil : theme.colorScheme)
            .tint(theme.accent)
    }
}
