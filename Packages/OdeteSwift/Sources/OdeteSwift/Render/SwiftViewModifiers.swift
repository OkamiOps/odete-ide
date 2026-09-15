import Foundation
import OdeteI18n
import SwiftUI

/// Os modificadores aplicados a cada view do subconjunto.
extension SwiftView {
    func applyModifiers(_ v: AnyView, _ mods: [Modifier]) -> AnyView {
        var out = v
        for m in mods {
            out = apply(out, m)
        }
        return out
    }

    func apply(_ v: AnyView, _ m: Modifier) -> AnyView {
        let a0 = m.first?.deref
        switch m.name {
        case "padding":
            if let n = Builtins.cgFloat(a0), m.args.count == 1, m.args[0].label == nil {
                return AnyView(v.padding(n))
            }
            if m.args.isEmpty {
                return AnyView(v.padding())
            }
            return AnyView(v.padding(Builtins.edges(a0), Builtins.cgFloat(m.args.count > 1 ? m.args[1].value : nil)))
        case "font":
            if case let .font(f)? = a0 {
                return AnyView(v.font(f))
            }
            if case let .token(t)? = a0, let f = Builtins.font(t) {
                return AnyView(v.font(f))
            }
            return v
        case "bold": return AnyView(v.bold())
        case "italic": return AnyView(v.italic())
        case "fontWeight": return AnyView(v.fontWeight(Builtins.weight(a0 ?? .none)))
        case "fontDesign": return AnyView(v.fontDesign(Builtins.design(a0)))
        case "foregroundStyle", "foregroundColor",
             "tint": return m
            .name == "tint" ? AnyView(v.tint(colorOf(a0))) : AnyView(v.foregroundStyle(Builtins.shapeStyle(a0)))
        case "background":
            if !m.trailing.isEmpty {
                return AnyView(v.background { kids(m.trailing) })
            }
            if let a0 {
                return AnyView(v.background(Builtins.shapeStyle(a0), in: shapeIn(m.arg("in"))))
            }
            return AnyView(v.background(Color.gray.opacity(0.15)))
        case "overlay":
            if !m.trailing
                .isEmpty
            {
                return AnyView(v.overlay(alignment: Builtins.alignment(m.arg("alignment"))) { kids(m.trailing) })
            }
            if case let .view(n)? = a0 {
                return AnyView(v.overlay { SwiftView(node: n, instance: owner) })
            }
            return v
        case "frame":
            if let mw = m.arg("maxWidth") ?? m.arg("maxHeight") {
                _ = mw; return AnyView(v.frame(
                    minWidth: Builtins.cgFloat(m.arg("minWidth")),
                    maxWidth: maxDim(m.arg("maxWidth")),
                    minHeight: Builtins.cgFloat(m.arg("minHeight")),
                    maxHeight: maxDim(m.arg("maxHeight")),
                    alignment: Builtins.alignment(m.arg("alignment"))
                ))
            }
            return AnyView(v.frame(
                width: Builtins.cgFloat(m.arg("width")),
                height: Builtins.cgFloat(m.arg("height")),
                alignment: Builtins.alignment(m.arg("alignment"))
            ))
        case "cornerRadius", "clipShape":
            if m.name == "clipShape", case let .view(n)? = a0 {
                return AnyView(v.clipShape(shapeOf(n)))
            }
            if m.name == "clipShape",
               case let .token(t)? = a0
            {
                return AnyView(v.clipShape(shapeOf(ViewNode(kind: t))))
            }
            return AnyView(v.clipShape(RoundedRectangle(cornerRadius: Builtins.cgFloat(a0) ?? 8)))
        case "opacity": return AnyView(v.opacity(a0?.asDouble ?? 1))
        case "buttonStyle":
            guard case let .token(t)? = a0 else { return v }
            switch t {
            case "bordered": return AnyView(v.buttonStyle(.bordered)); case "borderedProminent": return AnyView(v
                    .buttonStyle(.borderedProminent)); case "plain": return AnyView(v
                    .buttonStyle(.plain)); case "glass": return AnyView(v
                    .buttonStyle(.glass)); case "glassProminent": return AnyView(v
                    .buttonStyle(.glassProminent)); default: return v
            }
        case "controlSize": if case let .token(t)? = a0 {
                return AnyView(v
                    .controlSize(t == "large" ? .large : t == "small" ? .small : t == "mini" ? .mini : .regular))
            }; return v
        case "multilineTextAlignment": return AnyView(v.multilineTextAlignment(Builtins.textAlignment(a0)))
        case "lineLimit": return AnyView(v.lineLimit(a0?.asInt))
        case "disabled": return AnyView(v.disabled(a0?.asBool ?? true))
        case "hidden": return AnyView(v.hidden())
        case "shadow": return AnyView(v.shadow(
                color: colorOf(m.arg("color")?.deref ?? .none, default: .black.opacity(0.25)),
                radius: Builtins.cgFloat(m.arg("radius")) ?? 4,
                x: Builtins.cgFloat(m.arg("x")) ?? 0,
                y: Builtins.cgFloat(m.arg("y")) ?? 2
            ))
        case "navigationTitle": return AnyView(v.navigationTitle(a0?.asString ?? ""))
        case "listStyle": if case let .token(t)? = a0 {
                switch t {
                case "plain": return AnyView(v.listStyle(.plain)); case "insetGrouped": return AnyView(v
                        .listStyle(.insetGrouped)); case "grouped": return AnyView(v
                        .listStyle(.grouped)); default: return v
                }
            }; return v
        case "textFieldStyle": if case .token("roundedBorder")? = a0 {
                return AnyView(v.textFieldStyle(.roundedBorder))
            }; return v
        case "toggleStyle", "animation", "transition", "onAppear", "onChange", "toolbar", "task", "onTapGesture",
             "accessibilityLabel",
             "id", "tag", "keyboardType", "autocorrectionDisabled", "textInputAutocapitalization", "submitLabel",
             "scrollContentBackground",
             "ignoresSafeArea", "symbolRenderingMode", "labelStyle", "pickerStyle", "presentationDetents", "sheet",
             "alert",
             "focused", "onSubmit":
            if m.name == "ignoresSafeArea" {
                return AnyView(v.ignoresSafeArea())
            }
            return v
        case "imageScale": if case let .token(t)? = a0 {
                return AnyView(v.imageScale(t == "large" ? .large : t == "small" ? .small : .medium))
            }; return v
        case "symbolVariant": return v
        case "offset": return AnyView(v.offset(
                x: Builtins.cgFloat(m.arg("x")) ?? 0,
                y: Builtins.cgFloat(m.arg("y")) ?? 0
            ))
        case "rotationEffect": return AnyView(v.rotationEffect(.degrees(m.first?.asDouble ?? 0)))
        case "scaleEffect": return AnyView(v.scaleEffect(a0?.asDouble ?? 1))
        case "blur": return AnyView(v.blur(radius: Builtins.cgFloat(m.arg("radius")) ?? 4))
        case "border": return AnyView(v.border(colorOf(a0), width: Builtins.cgFloat(m.arg("width")) ?? 1))
        case "fill": return AnyView(v.foregroundStyle(Builtins.shapeStyle(a0)))
        case "stroke": return AnyView(v.overlay(RoundedRectangle(cornerRadius: 0).stroke(
                Builtins.shapeStyle(a0),
                lineWidth: Builtins.cgFloat(m.arg("lineWidth")) ?? 1
            )))
        case "strokeBorder": return v
        case "resizable", "scaledToFit", "scaledToFill", "aspectRatio", "fixedSize", "textSelection", "monospacedDigit",
             "truncationMode", "minimumScaleFactor", "kerning", "tracking", "underline", "strikethrough",
             "baselineOffset",
             "interactiveDismissDisabled", "navigationBarTitleDisplayMode", "listRowBackground", "listRowSeparator",
             "safeAreaInset",
             "contentShape", "help", "allowsHitTesting", "zIndex", "compositingGroup", "drawingGroup", "clipped",
             "mask",
             "environment", "preferredColorScheme", "colorScheme", "statusBarHidden", "badge", "contextMenu",
             "swipeActions",
             "refreshable", "searchable", "navigationDestination", "toolbarBackground", "tabItem", "gridCellColumns",
             "gridCellAnchor",
             "layoutPriority", "lineSpacing", "textCase", "sensoryFeedback", "matchedGeometryEffect", "glassEffect",
             "backgroundStyle",
             "containerRelativeFrame":
            if m.name == "clipped" {
                return AnyView(v.clipped())
            }
            if m.name == "fixedSize" {
                return AnyView(v.fixedSize())
            }
            if m.name == "lineSpacing" {
                return AnyView(v.lineSpacing(Builtins.cgFloat(a0) ?? 0))
            }
            if m.name == "underline" {
                return AnyView(v.underline())
            }
            if m.name == "strikethrough" {
                return AnyView(v.strikethrough())
            }
            if m.name == "glassEffect" {
                return AnyView(v.glassEffect())
            }
            if m
                .name ==
                "textCase"
            {
                if case .token("uppercase")? = a0 {
                    return AnyView(v.textCase(.uppercase))
                }; return AnyView(v.textCase(.lowercase))
            }
            return v
        default:
            owner.report(tr("modificador fora do subconjunto: .%1$@", "\(m.name)"), m.line)
            return v
        }
    }

    func maxDim(_ v: Value?) -> CGFloat? {
        if case .token("infinity")? = v?.deref {
            return .infinity
        }; return Builtins
            .cgFloat(v)
    }

    func colorOf(
        _ v: Value?,
        default d: Color = .primary
    )
        -> Color
    {
        if case let .color(c)? = v {
            return c
        }; if case let .token(t)? = v {
            return Builtins.color(t) ?? d
        }; return d
    }

    func shapeIn(_ v: Value?) -> AnyShape {
        if case let .view(n)? = v {
            return shapeOf(n)
        }
        if case let .token(t)? = v {
            return shapeOf(ViewNode(kind: t))
        }
        return AnyShape(Rectangle())
    }

    func shapeOf(_ n: ViewNode) -> AnyShape {
        switch n.kind {
        case "Circle", "circle": AnyShape(Circle())
        case "Capsule", "capsule": AnyShape(Capsule())
        case "RoundedRectangle",
             "rect": AnyShape(RoundedRectangle(cornerRadius: Builtins.cgFloat(n.arg("cornerRadius")) ?? 8))
        case "Ellipse": AnyShape(Ellipse())
        default: AnyShape(Rectangle())
        }
    }
}

/// Raiz do preview: uma instância e o seu body reavaliado quando o estado muda.
public struct SwiftRootView: View {
    @Bindable var instance: ViewInstance
    public init(instance: ViewInstance) {
        self.instance = instance
    }

    public var body: some View {
        let nodes = instance.evalBody()
        VStack(spacing: 0) { ForEach(Array(nodes.enumerated()), id: \.offset) { _, n in SwiftView(
            node: n,
            instance: instance
        ) } }
    }
}
