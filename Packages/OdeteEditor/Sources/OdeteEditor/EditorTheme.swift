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
        font = UIFont(name: "IBMPlexMono", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        lineNumberFont = UIFont(name: "IBMPlexMono", size: max(fontSize - 1, 10))
            ?? .monospacedSystemFont(ofSize: max(fontSize - 1, 10), weight: .regular)
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
        // A tabela cobre as famílias que as gramáticas embarcadas realmente emitem. Quem
        // não está aqui fica com a cor do texto — que era o caso de metade das capturas
        // e deixava arquivo inteiro parecendo monocromático.
        syntax = [
            "keyword": UIColor(hex: s.keyword),
            "conditional": UIColor(hex: s.keyword),
            "repeat": UIColor(hex: s.keyword),
            "exception": UIColor(hex: s.keyword),
            "include": UIColor(hex: s.keyword),
            "import": UIColor(hex: s.keyword),
            "storage": UIColor(hex: s.keyword),
            "label": UIColor(hex: s.keyword),
            "string": UIColor(hex: s.string),
            // A chave de um objeto não é o valor dela. Sem esta linha,
            // `string.special.key` subia até `string` e um package-lock.json inteiro
            // saía verde, chave e valor na mesma cor.
            "string.special.key": UIColor(hex: s.function),
            "string.escape": UIColor(hex: s.number),
            "string.regex": UIColor(hex: s.type),
            "escape": UIColor(hex: s.number),
            "charset": UIColor(hex: s.string),
            "char": UIColor(hex: s.string),
            "character": UIColor(hex: s.string),
            "comment": UIColor(hex: s.comment),
            "spell": UIColor(hex: s.comment),
            "number": UIColor(hex: s.number),
            "float": UIColor(hex: s.number),
            "boolean": UIColor(hex: s.number),
            "constant": UIColor(hex: s.number),
            "function": UIColor(hex: s.function),
            "method": UIColor(hex: s.function),
            "constructor": UIColor(hex: s.type),
            "type": UIColor(hex: s.type),
            "namespace": UIColor(hex: s.type),
            "module": UIColor(hex: s.type),
            "symbol": UIColor(hex: s.type),
            "union": UIColor(hex: s.type),
            "tag": UIColor(hex: s.type),
            "attribute": UIColor(hex: s.function),
            "property": UIColor(hex: s.function),
            "field": UIColor(hex: s.function),
            "parameter": UIColor(hex: palette.fg),
            "variable.parameter": UIColor(hex: palette.fg),
            "variable.builtin": UIColor(hex: s.keyword),
            "operator": UIColor(hex: palette.fgMuted),
            "punctuation": UIColor(hex: palette.fgMuted),
            "delimiter": UIColor(hex: palette.fgMuted),
            "variable": UIColor(hex: palette.fg),
            "local": UIColor(hex: palette.fg),
            "user": UIColor(hex: palette.fg),
            "none": UIColor(hex: palette.fg),
            "meta": UIColor(hex: palette.fgMuted),
            "embedded": UIColor(hex: palette.fg),
            // CSS: a regra `@media`, `@supports`, `@keyframes` é palavra da linguagem.
            "media": UIColor(hex: s.keyword),
            "supports": UIColor(hex: s.keyword),
            "keyframes": UIColor(hex: s.keyword),
            "error": UIColor(hex: palette.danger),
            "text.title": UIColor(hex: s.keyword),
            "text.emphasis": UIColor(hex: s.string),
            "text.strong": UIColor(hex: s.function),
            "text.literal": UIColor(hex: s.number),
            "text.uri": UIColor(hex: palette.accent),
            "text.reference": UIColor(hex: palette.accent),
            "text.math": UIColor(hex: s.number),
            "text.environment": UIColor(hex: s.type),
            "text.environment.name": UIColor(hex: s.function),
            "text.warning": UIColor(hex: s.number),
            "text.danger": UIColor(hex: palette.danger),
        ]
    }

    func textColor(for highlightName: String) -> UIColor? {
        var name = highlightName
        while true {
            if let c = syntax[name] {
                return c
            }
            guard let dot = name.lastIndex(of: ".") else { return nil }
            name = String(name[..<dot])
        }
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        if highlightName.hasPrefix("text.strong") || highlightName.hasPrefix("text.title") {
            return .bold
        }
        if highlightName.hasPrefix("text.emphasis") || highlightName.hasPrefix("comment") {
            return .italic
        }
        return []
    }
}

extension UIColor {
    convenience init(hex: String) {
        var s = hex
        if s.hasPrefix("#") {
            s.removeFirst()
        }
        let v = UInt32(s, radix: 16) ?? 0xFF00FF
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}
