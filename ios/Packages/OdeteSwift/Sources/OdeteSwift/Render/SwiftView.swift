import SwiftUI

/// Renderiza um `ViewNode` como SwiftUI de verdade.
public struct SwiftView: View {
    let node: ViewNode
    @Bindable var instance: ViewInstance
    @State private var pushed = false

    public init(node: ViewNode, instance: ViewInstance) {
        self.node = node; self.instance = instance
    }

    public var body: some View {
        applyModifiers(AnyView(base), node.modifiers)
    }

    var owner: ViewInstance {
        node.owner ?? instance
    }

    func text(_ v: Value?) -> String {
        v?.deref.asString ?? ""
    }

    func binding(_ v: Value?) -> Binding<Value> {
        guard case let .binding(inst, name)? = v else { return .constant(v ?? .none) }
        return Binding(get: { inst.get(name) }, set: { inst.set(name, $0) })
    }

    func kids(_ list: [ViewNode]) -> some View {
        ForEach(Array(list.enumerated()), id: \.offset) { _, c in SwiftView(node: c, instance: owner) }
    }

    @ViewBuilder var base: some View {
        switch node.kind {
        case "__struct": kids(node.children)
        case "__placeholder":
            Text(text(node.arg(at: 0))).font(.caption).foregroundStyle(.secondary).padding(8)
                .frame(maxWidth: .infinity).overlay(RoundedRectangle(cornerRadius: 6).stroke(style: StrokeStyle(
                    lineWidth: 1,
                    dash: [4]
                )).foregroundStyle(.secondary))
        case "Text": Text(text(node.firstUnlabeled ?? node.arg(at: 0)))
        case "Label":
            Label(text(node.arg(at: 0)), systemImage: text(node.arg("systemImage")))
        case "Image":
            if let s = node.arg("systemName") {
                Image(systemName: text(s))
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        case "Button":
            Button {
                if let a = node.action {
                    owner.perform(a)
                }
            } label: {
                if node.children.isEmpty {
                    Text(text(node.firstUnlabeled))
                } else {
                    kids(node.children)
                }
            }
        case "Toggle":
            Toggle(
                text(node.firstUnlabeled),
                isOn: Binding(
                    get: { binding(node.arg("isOn")).wrappedValue.asBool },
                    set: { binding(node.arg("isOn")).wrappedValue = .bool($0) }
                )
            )
        case "TextField", "SecureField":
            let b = Binding(
                get: { binding(node.arg("text")).wrappedValue.asString },
                set: { binding(node.arg("text")).wrappedValue = .string($0) }
            )
            if node.kind == "SecureField" {
                SecureField(text(node.firstUnlabeled), text: b)
            } else {
                TextField(
                    text(node.firstUnlabeled),
                    text: b
                )
            }
        case "Slider":
            let range = sliderRange(node.arg("in"))
            Slider(
                value: Binding(
                    get: { binding(node.arg("value")).wrappedValue.asDouble ?? 0 },
                    set: { binding(node.arg("value")).wrappedValue = .double($0) }
                ),
                in: range
            )
        case "Stepper":
            Stepper(
                text(node.firstUnlabeled),
                value: Binding(
                    get: { binding(node.arg("value")).wrappedValue.asInt ?? 0 },
                    set: { binding(node.arg("value")).wrappedValue = .int($0) }
                ),
                in: stepperRange(node.arg("in"))
            )
        case "Divider": Divider()
        case "Spacer": Spacer(minLength: Builtins.cgFloat(node.arg("minLength")))
        case "VStack", "LazyVStack": VStack(
                alignment: Builtins.hAlignment(node.arg("alignment")),
                spacing: Builtins.cgFloat(node.arg("spacing"))
            ) { kids(node.children) }
        case "HStack", "LazyHStack": HStack(
                alignment: Builtins.vAlignment(node.arg("alignment")),
                spacing: Builtins.cgFloat(node.arg("spacing"))
            ) { kids(node.children) }
        case "ZStack": ZStack(alignment: Builtins.alignment(node.arg("alignment"))) { kids(node.children) }
        case "Group", "GridRow": kids(node.children)
        case "Grid": Grid { kids(node.children) }
        case "LazyVGrid", "LazyHGrid": LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))]) { kids(node.children) }
        case "ScrollView": ScrollView(scrollAxes(node.firstUnlabeled)) { kids(node.children) }
        case "List":
            if let items = node.firstUnlabeled, case let .array(list) = items.deref {
                List(
                    Array(list.enumerated()),
                    id: \.offset
                ) { _, item in Text(item.asString) }
            } else {
                List { kids(node.children) }
            }
        case "Form": Form { kids(node.children) }
        case "Section":
            if let h = node.firstUnlabeled ?? node.arg("header") {
                Section(text(h)) { kids(node.children) }
            } else {
                Section { kids(node.children) }
            }
        case "GroupBox": GroupBox(text(node.firstUnlabeled)) { kids(node.children) }
        case "NavigationStack", "NavigationView": NavigationStack { kids(node.children) }
        case "NavigationLink":
            NavigationLink { destination } label: {
                if node.children.isEmpty {
                    Text(text(node.firstUnlabeled))
                } else {
                    kids(node.children)
                }
            }
        case "Rectangle": Rectangle()
        case "Circle": Circle()
        case "Capsule": Capsule()
        case "Ellipse": Ellipse()
        case "RoundedRectangle": RoundedRectangle(cornerRadius: Builtins.cgFloat(node.arg("cornerRadius")) ?? 8)
        case "Color": Builtins.colorInit(node.args)
        case "ProgressView": if let v = node.arg("value") {
                ProgressView(value: v.asDouble ?? 0)
            } else {
                ProgressView(text(node.firstUnlabeled))
            }
        case "Link": Link(
                text(node.firstUnlabeled),
                destination: URL(string: text(node.arg("destination"))) ?? URL(string: "https://apple.com")!
            )
        case "EmptyView": EmptyView()
        case "ContentUnavailableView": ContentUnavailableView(
                text(node.arg(at: 0)),
                systemImage: text(node.arg("systemImage"))
            )
        case "Menu": Menu(text(node.firstUnlabeled)) { kids(node.children) }
        case "DisclosureGroup": DisclosureGroup(text(node.firstUnlabeled)) { kids(node.children) }
        case "TabView": TabView { kids(node.children) }
        case "Picker":
            let sel = Binding(
                get: { binding(node.arg("selection")).wrappedValue.asString },
                set: { binding(node.arg("selection")).wrappedValue = .string($0) }
            )
            Picker(text(node.firstUnlabeled), selection: sel) { kids(node.children) }.pickerStyle(.menu)
        default:
            Text("fora do subconjunto: \(node.kind)").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var destination: some View {
        if let lazy = node.lazyChildren {
            kids(lazy(owner))
        } else {
            Text("destino")
        }
    }

    func sliderRange(_ v: Value?) -> ClosedRange<Double> {
        if case let .array(a)? = v?.deref,
           a.count >= 2
        {
            let lo = a.first?.asDouble ?? 0, hi = a.last?.asDouble ?? 1; return lo ... max(
                hi,
                lo + 0.001
            )
        }
        return 0 ... 1
    }

    func stepperRange(_ v: Value?) -> ClosedRange<Int> {
        if case let .array(a)? = v?.deref,
           a.count >= 2
        {
            let lo = a.first?.asInt ?? 0, hi = a.last?.asInt ?? 100; return lo ... max(
                hi,
                lo
            )
        }
        return Int.min / 2 ... Int.max / 2
    }

    func scrollAxes(_ v: Value?) -> Axis
        .Set
    {
        if case let .token(t)? = v {
            return t == "horizontal" ? .horizontal : .vertical
        }; return .vertical
    }

    // MARK: modificadores

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
            owner.report("modificador fora do subconjunto: .\(m.name)", m.line)
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
