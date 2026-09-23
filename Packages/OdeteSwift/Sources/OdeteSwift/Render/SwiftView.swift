import OdeteI18n
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
            Text(tr("fora do subconjunto: %1$@", "\(node.kind)")).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var destination: some View {
        if let lazy = node.lazyChildren {
            kids(lazy(owner))
        } else {
            Text(tr("destino"))
        }
    }

    func sliderRange(_ v: Value?) -> ClosedRange<Double> {
        if case let .array(a)? = v?.deref,
           a.count >= 2
        {
            let lo = a.first?.asDouble ?? 0, hi = a.last?.asDouble ?? 1
            // NaN ou infinito montariam um `ClosedRange` inválido, e isso para o app.
            guard lo.isFinite, hi.isFinite else { return 0 ... 1 }
            return lo ... max(hi, lo + 0.001)
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
}
