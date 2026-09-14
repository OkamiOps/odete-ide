@testable import OdeteSwift
import SwiftUI
import Testing

@MainActor
func program(_ src: String) -> Program {
    Program(files: [Parser.parse(file: "T.swift", source: src)])
}

@MainActor
func root(_ src: String) -> (Program, ViewInstance) {
    let p = program(src); return (p, p.instance(of: p.rootName!)!)
}

@MainActor
func find(_ nodes: [ViewNode], _ kind: String) -> [ViewNode] {
    nodes.flatMap { n in (n.kind == kind ? [n] : []) + find(n.children, kind) }
}

@MainActor
func texts(_ nodes: [ViewNode]) -> [String] {
    find(nodes, "Text").map { $0.firstUnlabeled?.deref.asString ?? "" }
}

@MainActor struct InterpreterTests {
    @Test func counterWithStateAndButtons() throws {
        let (p, inst) = root("""
        struct ContentView: View {
            @State private var count = 0
            var body: some View {
                VStack {
                    Text("Toques: \\(count)")
                    Button("Mais") { count += 1 }
                    Button(action: { count -= 2 }) { Text("Menos") }
                    Button { count = 0 } label: { Label("Zerar", systemImage: "trash") }
                }
            }
        }
        """)
        #expect(p.rootName == "ContentView" && p.diagnostics.isEmpty)
        var nodes = inst.evalBody()
        #expect(texts(nodes) == ["Toques: 0", "Menos"])
        let buttons = find(nodes, "Button")
        #expect(buttons.count == 3 && buttons[1].children.count == 1 && buttons[2].children.first?.kind == "Label")
        try inst.perform(#require(buttons[0].action))
        try inst.perform(#require(buttons[0].action))
        try inst.perform(#require(buttons[1].action))
        #expect(inst.get("count").asInt == 0)
        try inst.perform(#require(buttons[0].action))
        nodes = inst.evalBody()
        #expect(texts(nodes).first == "Toques: 1")
        try inst.perform(#require(find(nodes, "Button")[2].action))
        #expect(inst.get("count").asInt == 0 && inst.diagnostics.isEmpty)
    }

    @Test func toggleTextFieldForEachAndIf() throws {
        let (_, inst) = root("""
        struct ContentView: View {
            @State var on = false
            @State var nome: String = ""
            @State var itens = ["a", "b"]
            var body: some View {
                Toggle("Ligado", isOn: $on)
                TextField("nome", text: $nome)
                if on {
                    Text("ligado \\(nome.uppercased())")
                } else {
                    Text("desligado")
                }
                ForEach(0..<2) { i in Text("linha \\(i + 1)") }
                ForEach(itens, id: \\.self) { s in Text(s) }
                Button("add") { itens.append("c") }
                Button("tog") { on.toggle() }
            }
        }
        """)
        var nodes = inst.evalBody()
        #expect(texts(nodes) == ["desligado", "linha 1", "linha 2", "a", "b"])
        inst.set("nome", .string("zé"))
        try inst.perform(#require(find(nodes, "Button")[1].action))
        try inst.perform(#require(find(nodes, "Button")[0].action))
        nodes = inst.evalBody()
        #expect(texts(nodes) == ["ligado ZÉ", "linha 1", "linha 2", "a", "b", "c"])
        #expect(find(nodes, "Toggle").count == 1 && find(nodes, "TextField").count == 1)
    }

    @Test func modifiersChildStructsAndBindings() throws {
        let (p, inst) = root("""
        @main struct App: App { var body: some Scene { WindowGroup { Home() } } }
        struct Home: View {
            @State private var n = 5
            var body: some View {
                NavigationStack {
                    Painel(valor: $n, titulo: "Painel")
                        .padding(12)
                        .background(Color.blue.opacity(0.2))
                }
                .navigationTitle("Início")
            }
        }
        struct Painel: View {
            @Binding var valor: Int
            let titulo: String
            var dobro: Int { valor * 2 }
            var body: some View {
                Text("\\(titulo): \\(dobro)").font(.title).foregroundStyle(.red)
                Button("+") { valor += 1 }
            }
        }
        """)
        #expect(p.rootName == "Home")
        var nodes = inst.evalBody()
        #expect(texts(nodes) == ["Painel: 10"])
        let painel = find(nodes, "__struct")[0]
        #expect(painel.modifiers.map(\.name) == ["padding", "background"])
        if case let .color = try #require(painel.modifiers[1].first) {} else {
            Issue.record("cor")
        }
        let t = find(nodes, "Text")[0]
        #expect(t.modifiers.map(\.name) == ["font", "foregroundStyle"])
        if case .token("title") = try #require(t.modifiers[0].first) {} else {
            Issue.record("font token")
        }
        // botão do filho muda o estado do pai pelo binding
        let child = try #require(painel.owner)
        try child.perform(#require(find(nodes, "Button")[0].action))
        #expect(inst.get("n").asInt == 6)
        nodes = inst.evalBody()
        #expect(texts(nodes) == ["Painel: 12"] && find(nodes, "__struct")[0].owner === child)
    }

    @Test func errorsAndPlaceholders() {
        let (_, inst) = root("""
        struct ContentView: View {
            @State var x = 1
            var body: some View {
                Text("\\(x / 0)")
                GeometryReader { g in Text("g") }
                Text("ok").blur(radius: 2).foo()
            }
        }
        """)
        let nodes = inst.evalBody()
        #expect(nodes.count == 3 && nodes[0].kind == "__placeholder" && nodes[1].kind == "__placeholder")
        #expect(inst.diagnostics.contains { $0.message.contains("divisão por zero") && $0.kind == .error })
        #expect(inst.diagnostics.contains { $0.message.contains("GeometryReader") && $0.kind == .warning })
        _ = SwiftView(node: nodes[2], instance: inst).body
        #expect(inst.diagnostics.contains { $0.message.contains(".foo") })
    }

    @Test func renderTemplateNotEmpty() {
        let (_, inst) = root("""
        struct ContentView: View {
            @State private var count = 0
            var body: some View {
                VStack(spacing: 16) {
                    Text("Meu App").font(.largeTitle)
                    Text("Swift no iPad.")
                    Button("\\(count) toques") { count += 1 }
                        .buttonStyle(.borderedProminent)
                    HStack { Circle().fill(.red).frame(width: 20, height: 20); Spacer(); Image(systemName: "star") }
                    List { Section("A") { Text("um"); Text("dois") } }
                }
                .padding()
            }
        }
        """)
        let renderer = ImageRenderer(content: SwiftRootView(instance: inst).frame(width: 300, height: 500))
        renderer.scale = 1
        let img = renderer.uiImage
        #expect(img != nil && (img?.size.width ?? 0) >= 300)
        #expect(inst.diagnostics.isEmpty, "\(inst.diagnostics)")
    }
}
