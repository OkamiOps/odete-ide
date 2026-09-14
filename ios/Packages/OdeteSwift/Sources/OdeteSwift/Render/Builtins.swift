import SwiftUI

/// Mapas de nomes do SwiftUI para valores reais.
@MainActor
enum Builtins {
    static let views: Set<String> = [
        "Text",
        "Button",
        "Toggle",
        "TextField",
        "SecureField",
        "Slider",
        "Stepper",
        "Image",
        "Label",
        "Divider",
        "Spacer",
        "VStack",
        "HStack",
        "ZStack",
        "List",
        "Form",
        "Section",
        "ScrollView",
        "NavigationStack",
        "NavigationView",
        "NavigationLink",
        "ForEach",
        "Group",
        "Rectangle",
        "Circle",
        "RoundedRectangle",
        "Capsule",
        "Ellipse",
        "Color",
        "ProgressView",
        "Link",
        "EmptyView",
        "LazyVStack",
        "LazyHStack",
        "GroupBox",
        "DisclosureGroup",
        "Picker",
        "DatePicker",
        "TabView",
        "Grid",
        "GridRow",
        "LazyVGrid",
        "LazyHGrid",
        "Menu",
        "ContentUnavailableView",
    ]

    static func color(_ name: String) -> Color? {
        switch name {
        case "red": .red; case "green": .green; case "blue": .blue; case "orange": .orange; case "yellow": .yellow; case "pink": .pink; case "purple": .purple
        case "primary": .primary; case "secondary": .secondary; case "gray": .gray; case "black": .black; case "white": .white; case "clear": .clear
        case "mint": .mint; case "teal": .teal; case "cyan": .cyan; case "indigo": .indigo; case "brown": .brown; case "accentColor",
             "accent", "tint": .accentColor
        default: nil
        }
    }

    static func colorInit(_ args: [(String?, Value)]) -> Color {
        func d(_ l: String) -> Double {
            args.first { $0.0 == l }?.1.asDouble ?? 0
        }
        if args.contains(where: { $0.0 == "red" }) {
            return Color(
                red: d("red"),
                green: d("green"),
                blue: d("blue"),
                opacity: args.contains { $0.0 == "opacity" } ? d("opacity") : 1
            )
        }
        if args.contains(where: { $0.0 == "hue" }) {
            return Color(
                hue: d("hue"),
                saturation: d("saturation"),
                brightness: d("brightness")
            )
        }
        if args.contains(where: { $0.0 == "white" }) {
            return Color(white: d("white"))
        }
        if let first = args.first?.1 {
            if case let .color(c) = first {
                return c
            }
            if case let .token(t) = first {
                return color(t.replacingOccurrences(of: "system", with: "").lowercased()) ?? .gray
            }
            if case let .string(s) = first, s.hasPrefix("#") {
                return Color(hexString: s)
            }
        }
        return .gray
    }

    static func font(_ name: String) -> Font? {
        switch name {
        case "largeTitle": .largeTitle; case "title": .title; case "title2": .title2; case "title3": .title3; case "headline": .headline; case "subheadline": .subheadline
        case "body": .body; case "callout": .callout; case "footnote": .footnote; case "caption": .caption; case "caption2": .caption2
        default: nil
        }
    }

    static func weight(_ v: Value) -> Font.Weight {
        guard case let .token(t) = v else { return .regular }
        switch t {
        case "bold": return .bold; case "semibold": return .semibold; case "medium": return .medium; case "light": return .light; case "thin": return .thin; case "heavy": return .heavy; case "black": return .black; case "ultraLight": return .ultraLight; default: return .regular
        }
    }

    static func systemFont(_ args: [(String?, Value)]) -> Font {
        if let s = args.first(where: { $0.0 == "size" })?.1.asDouble {
            var f = Font.system(
                size: s,
                weight: weight(args.first { $0.0 == "weight" }?.1 ?? .none),
                design: design(args.first { $0.0 == "design" }?.1)
            )
            if case .token = args.first(where: { $0.0 == "weight" })?
                .1
            {
                f = f.weight(weight(args.first { $0.0 == "weight" }!.1))
            }
            return f
        }
        if case let .token(t)? = args.first?.1, let f = font(t) {
            return Font.system(
                style(t),
                design: design(args.first { $0.0 == "design" }?.1),
                weight: weight(args.first { $0.0 == "weight" }?.1 ?? .none)
            )
        }
        return .body
    }

    static func style(_ t: String) -> Font.TextStyle {
        switch t {
        case "largeTitle": .largeTitle; case "title": .title; case "title2": .title2; case "title3": .title3; case "headline": .headline; case "subheadline": .subheadline; case "callout": .callout; case "footnote": .footnote; case "caption": .caption; case "caption2": .caption2; default: .body
        }
    }

    static func design(_ v: Value?) -> Font.Design {
        guard case let .token(t)? = v else { return .default }
        switch t {
        case "rounded": return .rounded; case "monospaced": return .monospaced; case "serif": return .serif; default: return .default
        }
    }

    static func alignment(_ v: Value?) -> Alignment {
        guard case let .token(t)? = v else { return .center }
        switch t {
            switch t {
            case "leading": return .leading
            case "trailing": return .trailing
            case "top": return .top
            case "bottom": return .bottom
            case "topLeading": return .topLeading
            case "topTrailing": return .topTrailing
            case "bottomLeading": return .bottomLeading
            case "bottomTrailing": return .bottomTrailing
            default: return .center
            }
        }
    }

    static func hAlignment(_ v: Value?) -> HorizontalAlignment {
        guard case let .token(t)? = v
        else { return .center }; return t == "leading" ? .leading : t == "trailing" ? .trailing : .center
    }

    static func vAlignment(_ v: Value?) -> VerticalAlignment {
        guard case let .token(t)? = v
        else { return .center }; return t == "top" ? .top : t == "bottom" ? .bottom : t == "firstTextBaseline" ?
            .firstTextBaseline : .center
    }

    static func edges(_ v: Value?) -> Edge.Set {
        guard let v else { return .all }
        if case let .array(a) = v {
            return a.reduce(Edge.Set()) { $0.union(edges($1)) }
        }
        guard case let .token(t) = v else { return .all }
        switch t {
        case "horizontal": return .horizontal; case "vertical": return .vertical; case "top": return .top; case "bottom": return .bottom; case "leading": return .leading; case "trailing": return .trailing; default: return .all
        }
    }

    static func textAlignment(_ v: Value?) -> TextAlignment {
        guard case let .token(t)? = v
        else { return .center }; return t == "leading" ? .leading : t == "trailing" ? .trailing : .center
    }

    static func shapeStyle(_ v: Value?) -> AnyShapeStyle {
        switch v {
        case let .color(c)?: AnyShapeStyle(c)
        case let .token(t)?: AnyShapeStyle(color(t) ??
                (t == "ultraThinMaterial" || t == "thinMaterial" || t == "regularMaterial" ? Color.gray
                    .opacity(0.2) : .primary))
        default: AnyShapeStyle(.primary)
        }
    }

    static func cgFloat(_ v: Value?) -> CGFloat? {
        v?.asDouble.map { CGFloat($0) }
    }
}

extension Color {
    init(hexString: String) {
        var h = hexString.trimmingCharacters(in: .whitespaces); if h.hasPrefix("#") {
            h.removeFirst()
        }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        let r, g, b: Double
        if h
            .count ==
            6
        {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
        } else {
            r = 0.5; g = 0.5; b = 0.5
        }
        self.init(red: r, green: g, blue: b)
    }
}
