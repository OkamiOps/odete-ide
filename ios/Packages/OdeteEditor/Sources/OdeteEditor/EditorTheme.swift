import OdeteCore
import Runestone
import UIKit

/// Tema do Runestone derivado dos tokens de `ThemePalette`.
final class EditorTheme: Runestone.Theme, @unchecked Sendable {
    let font: UIFont
    let lineNumberFont: UIFont
    let textColor: UIColor
    let gutterBackgroundColor: UIColor
    let gutterHairlineColor: UIColor
    let lineNumberColor: UIColor
    let selectedLineBackgroundColor: UIColor
    let selectedLinesLineNumberColor: UIColor
    let selectedLinesGutterBackgroundColor: UIColor
    let invisibleCharactersColor: UIColor
    let pageGuideHairlineColor: UIColor
    let pageGuideBackgroundColor: UIColor
    let markedTextBackgroundColor: UIColor
    private let syntax: [String: UIColor]

    init(palette: ThemePalette, fontSize: CGFloat) {
        font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        lineNumberFont = .monospacedSystemFont(ofSize: max(fontSize - 1, 10), weight: .regular)
        textColor = UIColor(hex: palette.fg)
        gutterBackgroundColor = UIColor(hex: palette.bg)
        gutterHairlineColor = UIColor(hex: palette.border)
        lineNumberColor = UIColor(hex: palette.fgSubtle)
        selectedLineBackgroundColor = UIColor(hex: palette.bgSubtle).withAlphaComponent(0.55)
        selectedLinesLineNumberColor = UIColor(hex: palette.fgMuted)
        selectedLinesGutterBackgroundColor = UIColor(hex: palette.bg)
        invisibleCharactersColor = UIColor(hex: palette.fgSubtle).withAlphaComponent(0.5)
        pageGuideHairlineColor = UIColor(hex: palette.border)
        pageGuideBackgroundColor = UIColor(hex: palette.bgElevated)
        markedTextBackgroundColor = UIColor(hex: palette.accent).withAlphaComponent(0.25)
        let s = palette.syntax
        syntax = [
            "keyword": UIColor(hex: s.keyword),
            "string": UIColor(hex: s.string),
            "comment": UIColor(hex: s.comment),
            "number": UIColor(hex: s.number),
            "function": UIColor(hex: s.function),
            "type": UIColor(hex: s.type),
            "tag": UIColor(hex: s.type),
            "attribute": UIColor(hex: s.function),
            "property": UIColor(hex: s.function),
            "constant": UIColor(hex: s.number),
            "operator": UIColor(hex: palette.fgMuted),
            "punctuation": UIColor(hex: palette.fgMuted),
            "variable": UIColor(hex: palette.fg),
            "text.title": UIColor(hex: s.keyword),
            "text.emphasis": UIColor(hex: s.string),
            "text.strong": UIColor(hex: s.function),
            "text.literal": UIColor(hex: s.number),
            "text.uri": UIColor(hex: palette.accent),
            "text.reference": UIColor(hex: palette.accent),
        ]
    }

    func textColor(for highlightName: String) -> UIColor? {
        var name = highlightName
        while true {
            if let c = syntax[name] { return c }
            guard let dot = name.lastIndex(of: ".") else { return nil }
            name = String(name[..<dot])
        }
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        if highlightName.hasPrefix("text.strong") || highlightName.hasPrefix("text.title") { return .bold }
        if highlightName.hasPrefix("text.emphasis") || highlightName.hasPrefix("comment") { return .italic }
        return []
    }
}

extension UIColor {
    convenience init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0xFF00FF
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}
