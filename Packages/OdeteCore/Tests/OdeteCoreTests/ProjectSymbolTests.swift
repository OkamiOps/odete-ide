@testable import OdeteCore
import Testing

struct ProjectSymbolTests {
    let indice = [
        ProjectSymbol(name: "App", kind: .function, path: "src/App.tsx", line: 30),
        ProjectSymbol(name: "AppShell", kind: .function, path: "src/Shell.tsx", line: 4),
        ProjectSymbol(name: "ROLLS", kind: .variable, path: "src/App.tsx", line: 3),
    ]

    @Test func oNomeExatoVemAntesDoQueSoComeçaIgual() {
        #expect(ProjectSymbol.procurar("App", em: indice).map(\.path) == ["src/App.tsx"])
    }

    @Test func semExatoCaiNoPrefixo() {
        #expect(ProjectSymbol.procurar("AppS", em: indice).map(\.name) == ["AppShell"])
    }

    @Test func palavraNoMeio() {
        let t = "const roll = ROLLS[active];"
        #expect(ProjectSymbol.palavra(em: t, offset: 15) == "ROLLS")
    }

    @Test func cursorLogoDepoisDaPalavraContaComoDentro() {
        let t = "const roll"
        #expect(ProjectSymbol.palavra(em: t, offset: 10) == "roll")
    }

    @Test func noEspacoNaoHaPalavra() {
        #expect(ProjectSymbol.palavra(em: "a  b", offset: 1) == "a")
        #expect(ProjectSymbol.palavra(em: "a  b", offset: 2) == nil)
        #expect(ProjectSymbol.palavra(em: "  ", offset: 1) == nil)
    }
}
