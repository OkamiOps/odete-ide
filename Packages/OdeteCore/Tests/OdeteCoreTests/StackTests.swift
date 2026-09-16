import Foundation
@testable import OdeteCore
import Testing

struct StackTests {
    private func pkg(_ deps: [String: String]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["dependencies": deps])
    }

    @Test func detectsFrameworks() {
        #expect(Stack.detect(paths: ["package.json"], packageJSON: pkg(["next": "15"])).id == "next")
        #expect(Stack.detect(paths: ["package.json"], packageJSON: pkg(["astro": "5"])).id == "astro")
        #expect(Stack.detect(paths: ["package.json"], packageJSON: pkg(["@nestjs/core": "11"])).kind == .api)
        #expect(Stack.detect(paths: ["package.json"], packageJSON: pkg(["vite": "8", "react": "19"])).label == "Vite")
        #expect(Stack.detect(paths: ["package.json"], packageJSON: pkg(["react": "19"])).id == "react")
    }

    @Test func swiftAndHtml() {
        #expect(Stack.detect(paths: ["Package.swift", "Sources/App.swift"], packageJSON: nil).kind == .swift)
        #expect(Stack.detect(paths: ["App.swiftpm/Package.swift"], packageJSON: nil).kind == .swift)
        #expect(Stack.detect(paths: ["index.html"], packageJSON: nil) == .html)
        #expect(Stack.detect(paths: ["index.html"], packageJSON: Data("{broken".utf8)) == .html)
    }
}

/// O agente precisa saber a pilha sem ninguém dizer no chat.
///
/// A detecção já existia, mas só a tela usava: num projeto Astro o agente criava
/// `index.html` na raiz, que o Astro ignora, e a pessoa tinha que explicar em que tipo
/// de projeto estava — num projeto que o próprio Hub criou a partir do modelo.
struct RegrasDaPilhaTests {
    func pilha(_ deps: [String: String], paths: [String] = ["package.json"]) -> Stack {
        let json = try! JSONSerialization.data(withJSONObject: ["dependencies": deps])
        return Stack.detect(paths: paths, packageJSON: json)
    }

    @Test func astroMandaUsarSrcPagesENaoIndexNaRaiz() {
        let r = pilha(["astro": "^5.0.0"]).regrasParaOAgente
        #expect(r.contains("src/pages"))
        #expect(r.contains("index.html")) // para dizer que NÃO é para criar
        #expect(r.contains("4321"))
    }

    @Test func viteMandaUsarIndexNaRaiz() {
        let r = pilha(["vite": "^5.0.0"]).regrasParaOAgente
        #expect(r.contains("index.html"))
        #expect(r.contains("src/main"))
        #expect(r.contains("5173"))
    }

    @Test func nextFalaDeAppOuPages() {
        let r = pilha(["next": "^15.0.0"]).regrasParaOAgente
        #expect(r.contains("app/"))
        #expect(r.contains("pages/"))
    }

    @Test func nestAvisaQueNaoTemPreview() {
        #expect(pilha(["@nestjs/core": "^10.0.0"]).regrasParaOAgente.contains("API"))
    }

    @Test func swiftNaoFalaDeNpm() {
        let r = Stack.detect(paths: ["ContentView.swift"], packageJSON: nil).regrasParaOAgente
        #expect(r.contains("SwiftUI"))
        #expect(r.contains("Swift Playgrounds"))
    }

    /// Toda pilha diz o nome dela logo na primeira linha.
    @Test func todaPilhaSeApresenta() {
        for (deps, rotulo) in [(["astro": "1"], "Astro"), (["vite": "1"], "Vite"),
                               (["next": "1"], "Next.js"), (["@nestjs/core": "1"], "Nest")]
        {
            #expect(pilha(deps).regrasParaOAgente.contains(rotulo))
        }
        #expect(Stack.html.regrasParaOAgente.contains("HTML"))
    }
}
