import OdeteCore
import SwiftUI

/// Ícone por extensão, portado de `file-glyph.tsx` para SF Symbols + cor.
public struct FileGlyph: View {
    @Environment(\.theme) private var theme
    public var path: String
    public var isDirectory: Bool
    public var expanded: Bool
    public var size: CGFloat

    public init(path: String, isDirectory: Bool = false, expanded: Bool = false, size: CGFloat = 14) {
        self.path = path
        self.isDirectory = isDirectory
        self.expanded = expanded
        self.size = size
    }

    public var body: some View {
        let g = glyph
        Image(systemName: g.symbol)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(g.color ?? theme.fgMuted)
            .frame(width: size + 4, height: size + 4)
    }

    var glyph: (symbol: String, color: Color?) {
        if isDirectory {
            return (expanded ? "folder.fill" : "folder", theme.fgMuted)
        }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        switch name.lowercased() {
        case "package.json": return ("shippingbox", Color(hex: "#cb3837"))
        case "package.swift": return ("swift", Color(hex: "#f05138"))
        case "readme.md": return ("text.book.closed", Color(hex: "#7eb6ff"))
        case ".gitignore", ".gitattributes": return ("arrow.triangle.branch", Color(hex: "#f14e32"))
        case "makefile": return ("hammer", nil)
        default: break
        }
        switch Language.detect(path: path) {
        case .html: return ("chevron.left.forwardslash.chevron.right", Color(hex: "#e34c26"))
        case .css: return ("paintpalette", Color(hex: "#563d7c").opacity(0.001) == .clear ? nil : Color(hex: "#7c9cff"))
        case .javascript: return ("curlybraces", Color(hex: "#f1e05a"))
        case .jsx, .tsx: return ("atom", Color(hex: "#61dafb"))
        case .typescript: return ("curlybraces", Color(hex: "#3178c6"))
        case .json: return ("curlybraces.square", Color(hex: "#e6c349"))
        case .markdown: return ("text.alignleft", Color(hex: "#7eb6ff"))
        case .swift: return ("swift", Color(hex: "#f05138"))
        case .yaml, .toml: return ("list.bullet.indent", Color(hex: "#cb171e"))
        case .scss: return ("paintpalette", Color(hex: "#cf649a"))
        case .astro: return ("sparkle", Color(hex: "#ff5d01"))
        case .svelte: return ("flame", Color(hex: "#ff3e00"))
        case .xml: return ("chevron.left.forwardslash.chevron.right", Color(hex: "#8a9aa9"))
        case .rust: return ("gearshape.2", Color(hex: "#dea584"))
        case .python: return ("chevron.left.slash.chevron.right", Color(hex: "#3572a5"))
        case .go: return ("hare", Color(hex: "#00add8"))
        case .c, .cpp: return ("c.square", Color(hex: "#659ad2"))
        case .csharp: return ("number.square", Color(hex: "#178600"))
        case .java: return ("cup.and.saucer", Color(hex: "#b07219"))
        case .ruby: return ("diamond", Color(hex: "#cc342d"))
        case .php: return ("chevron.left.forwardslash.chevron.right", Color(hex: "#777bb4"))
        case .bash: return ("terminal", Color(hex: "#89e051"))
        case .sql: return ("cylinder", Color(hex: "#e38c00"))
        case .plain:
            switch (name as NSString).pathExtension.lowercased() {
            case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": return ("photo", Color(hex: "#a3be8c"))
            case "lock": return ("lock", nil)
            case "env": return ("key", Color(hex: "#e6c349"))
            default: return ("doc", nil)
            }
        // Linguagem colorida sem ícone próprio ainda: documento de código, e não o
        // documento em branco de "não sei o que é isto".
        default: return ("doc.text", nil)
        }
    }
}
