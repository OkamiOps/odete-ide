import Foundation
import OdeteI18n

public enum ThemeId: String, CaseIterable, Codable, Sendable {
    case odete, catppuccin, latte, darcula, cursor, claude, linear, github, okami, volt, colo
}

/// Cores de sintaxe (hex "#rrggbb").
public struct SyntaxColors: Hashable, Codable, Sendable {
    public var keyword, string, comment, number, function, type: String

    public init(keyword: String, string: String, comment: String, number: String, function: String, type: String) {
        self.keyword = keyword
        self.string = string
        self.comment = comment
        self.number = number
        self.function = function
        self.type = type
    }

    /// Nomes na ordem em que aparecem na tela de ajustes.
    public static let nomes = ["keyword", "type", "function", "string", "number", "comment"]

    public func cor(_ nome: String) -> String {
        switch nome {
        case "keyword": keyword
        case "string": string
        case "comment": comment
        case "number": number
        case "function": function
        default: type
        }
    }

    /// As mesmas cores com o que a pessoa trocou por cima. O que ela não tocou continua
    /// sendo o do tema, então trocar de tema depois continua valendo para o resto.
    public func com(_ trocas: [String: String]) -> SyntaxColors {
        guard !trocas.isEmpty else { return self }
        var c = self
        for (nome, hex) in trocas where !hex.isEmpty {
            switch nome {
            case "keyword": c.keyword = hex
            case "string": c.string = hex
            case "comment": c.comment = hex
            case "number": c.number = hex
            case "function": c.function = hex
            case "type": c.type = hex
            default: break
            }
        }
        return c
    }

    /// Padrão de `src/styles.css` para temas sem cores próprias.
    public static let base = SyntaxColors(
        keyword: "#c3a6ff", string: "#9dcf8a", comment: "#6f6d68",
        number: "#e0a36a", function: "#7eb6ff", type: "#e6c349"
    )
}

/// Tokens de um tema, portados de `src/styles.css` e `src/lib/workspace/themes.ts`.
public struct ThemePalette: Hashable, Sendable, Identifiable {
    public var id: ThemeId
    public var label: String
    public var blurb: String
    public var dark: Bool
    public var bg, bgElevated, bgSubtle: String
    public var fg, fgMuted, fgSubtle: String
    public var border, borderStrong: String
    public var accent, accentFg: String
    public var danger: String = "#e25d5d"
    public var ok: String = "#7dce9a"
    public var syntax: SyntaxColors

    public static let all: [ThemePalette] = [
        ThemePalette(
            id: .odete, label: "Odete", blurb: chave("Noite da marca."), dark: true,
            bg: "#08080a", bgElevated: "#101014", bgSubtle: "#18181e",
            fg: "#eeeef2", fgMuted: "#9a9aa4", fgSubtle: "#6e6e78",
            border: "#2a2a32", borderStrong: "#3c3c46", accent: "#4fd4ea", accentFg: "#071014", syntax: .base
        ),
        ThemePalette(
            id: .catppuccin, label: "Catppuccin", blurb: chave("Mocha."), dark: true,
            bg: "#1e1e2e", bgElevated: "#181825", bgSubtle: "#313244",
            fg: "#cdd6f4", fgMuted: "#a6adc8", fgSubtle: "#6c7086",
            border: "#313244", borderStrong: "#45475a", accent: "#cba6f7", accentFg: "#1e1e2e",
            syntax: SyntaxColors(
                keyword: "#cba6f7",
                string: "#a6e3a1",
                comment: "#6c7086",
                number: "#fab387",
                function: "#89b4fa",
                type: "#f9e2af"
            )
        ),
        ThemePalette(
            id: .latte, label: "Latte", blurb: chave("Catppuccin claro."), dark: false,
            bg: "#eff1f5", bgElevated: "#e6e9ef", bgSubtle: "#dce0e8",
            fg: "#4c4f69", fgMuted: "#6c6f85", fgSubtle: "#9ca0b0",
            border: "#ccd0da", borderStrong: "#bcc0cc", accent: "#8839ef", accentFg: "#eff1f5",
            syntax: SyntaxColors(
                keyword: "#8839ef",
                string: "#40a02b",
                comment: "#9ca0b0",
                number: "#fe640b",
                function: "#1e66f5",
                type: "#df8e1d"
            )
        ),
        ThemePalette(
            id: .darcula, label: "Darcula", blurb: chave("JetBrains."), dark: true,
            bg: "#2b2b2b", bgElevated: "#3c3f41", bgSubtle: "#313335",
            fg: "#a9b7c6", fgMuted: "#808080", fgSubtle: "#606366",
            border: "#323232", borderStrong: "#4b4f51", accent: "#cc7832", accentFg: "#2b2b2b",
            syntax: SyntaxColors(
                keyword: "#cc7832",
                string: "#6a8759",
                comment: "#808080",
                number: "#6897bb",
                function: "#ffc66d",
                type: "#bbb529"
            )
        ),
        ThemePalette(
            id: .cursor, label: "Cursor", blurb: chave("Laranja."), dark: true,
            bg: "#181818", bgElevated: "#1f1f1f", bgSubtle: "#262626",
            fg: "#e4e4e4", fgMuted: "#a1a1a1", fgSubtle: "#737373",
            border: "#2a2a2a", borderStrong: "#3f3f3f", accent: "#f54e00", accentFg: "#ffffff",
            syntax: SyntaxColors(
                keyword: "#c792ea",
                string: "#c3e88d",
                comment: "#546e7a",
                number: "#f78c6c",
                function: "#82aaff",
                type: "#ffcb6b"
            )
        ),
        ThemePalette(
            id: .claude, label: "Claude", blurb: chave("Terracota."), dark: false,
            bg: "#faf9f5", bgElevated: "#f5f0e8", bgSubtle: "#efe8dc",
            fg: "#3d3929", fgMuted: "#6b6456", fgSubtle: "#9a9284",
            border: "#e6dcc8", borderStrong: "#d4c7ae", accent: "#cc785c", accentFg: "#ffffff",
            syntax: SyntaxColors(
                keyword: "#9b4d32",
                string: "#3b6d11",
                comment: "#9a9284",
                number: "#b35900",
                function: "#325d88",
                type: "#8a5a00"
            )
        ),
        ThemePalette(
            id: .linear, label: "Linear", blurb: chave("Índigo."), dark: true,
            bg: "#010102", bgElevated: "#141516", bgSubtle: "#1c1d1f",
            fg: "#f1f2f4", fgMuted: "#8a8f98", fgSubtle: "#62666d",
            border: "#23252a", borderStrong: "#33363d", accent: "#5e6ad2", accentFg: "#ffffff", syntax: .base
        ),
        ThemePalette(
            id: .github, label: "GitHub", blurb: chave("Dark dimmed."), dark: true,
            bg: "#0d1117", bgElevated: "#161b22", bgSubtle: "#21262d",
            fg: "#e6edf3", fgMuted: "#8b949e", fgSubtle: "#6e7681",
            border: "#30363d", borderStrong: "#484f58", accent: "#2f81f7", accentFg: "#ffffff", syntax: .base
        ),
        ThemePalette(
            id: .okami, label: "Okami", blurb: chave("Brasa."), dark: true,
            bg: "#060609", bgElevated: "#0b0b12", bgSubtle: "#14141f",
            fg: "#f4efe8", fgMuted: "#a39b92", fgSubtle: "#6f6a64",
            border: "#1c1c28", borderStrong: "#2c2c3c", accent: "#ff7a3d", accentFg: "#160800", syntax: .base
        ),
        ThemePalette(
            id: .volt, label: "Volt", blurb: chave("Verde elétrico."), dark: true,
            bg: "#101010", bgElevated: "#1a1a1a", bgSubtle: "#222222",
            fg: "#ececec", fgMuted: "#9a9a9a", fgSubtle: "#6a6a6a",
            border: "#2a2a2a", borderStrong: "#3a3a3a", accent: "#00d992", accentFg: "#052016", syntax: .base
        ),
        ThemePalette(
            id: .colo, label: "Colo", blurb: chave("Nome antigo, mesma noite."), dark: true,
            bg: "#08080a", bgElevated: "#101014", bgSubtle: "#18181e",
            fg: "#eeeef2", fgMuted: "#9a9aa4", fgSubtle: "#6e6e78",
            border: "#2a2a32", borderStrong: "#3c3c46", accent: "#4fd4ea", accentFg: "#071014", syntax: .base
        ),
    ]

    public static func by(_ id: ThemeId) -> ThemePalette {
        all.first { $0.id == id } ?? all[0]
    }
}
