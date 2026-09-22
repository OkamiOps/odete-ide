import Foundation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteCore
import OdeteFiles
import OdeteI18n
import Testing

/// Um projeto, uma janela — a parte que não precisa de cena de verdade.
@MainActor
@Suite(.serialized) struct JanelasTests {
    init() {
        Texto.escolher(.ptBR)
    }

    struct Mundo {
        let janelas: Janelas
        let store: ProjectStore
        let raiz: URL
    }

    func mundo() throws -> Mundo {
        let raiz = FileManager.default.temporaryDirectory.appending(path: "odete-janelas-\(UUID().uuidString)")
        let store = ProjectStore(root: raiz.appending(path: "Projects"))
        let estado = StateStore(url: raiz.appending(path: "state.json"), debounce: .milliseconds(1))
        return Mundo(janelas: Janelas(store: estado), store: store, raiz: raiz)
    }

    func app(_ m: Mundo) -> AppModel {
        AppModel(
            store: m.store,
            accounts: AccountStore(url: m.raiz.appending(path: "contas-teste.json"), keychain: MemorySecrets()),
            aiAccounts: AIAccountStore(url: m.raiz.appending(path: "ia-teste.json"), secrets: MemorySecrets())
        )
    }

    @Test func oProjetoAbertoNumaJanelaChamaEssaJanela() throws {
        let m = try mundo()
        let p = try m.store.create(name: "Um", template: .blank)
        let q = try m.store.create(name: "Dois", template: .blank)
        let a = app(m), b = app(m)
        let ca = ChromeState(), cb = ChromeState()
        var chamadas: [String] = []
        m.janelas.entrar(UUID(), app: a, chrome: ca) { chamadas.append("a") }
        m.janelas.entrar(UUID(), app: b, chrome: cb) { chamadas.append("b") }
        a.refresh()
        b.refresh()

        a.open(p, chrome: ca)
        let aberto = try #require(a.workspace)
        b.open(p, chrome: cb)
        #expect(b.workspace == nil, "a segunda janela montou uma segunda cópia viva do projeto")
        #expect(chamadas == ["a"], "a janela dona do projeto não foi chamada")

        // Reabrir na mesma janela não monta outro workspace por cima.
        a.open(p, chrome: ca)
        #expect(a.workspace === aberto)

        // Outro projeto na outra janela abre normalmente.
        b.open(q, chrome: cb)
        #expect(b.workspace?.project.id == q.id)

        // Fechado na primeira, o projeto fica livre.
        a.closeWorkspace()
        b.open(p, chrome: cb)
        #expect(b.workspace?.project.id == p.id)
        #expect(chamadas == ["a"])
        b.closeWorkspace()
    }

    @Test func janelaQueSaiNaoSeguraProjeto() throws {
        let m = try mundo()
        let p = try m.store.create(name: "Solto", template: .blank)
        let a = app(m), b = app(m)
        let ca = ChromeState(), cb = ChromeState()
        let idA = UUID()
        m.janelas.entrar(idA, app: a, chrome: ca) {}
        m.janelas.entrar(UUID(), app: b, chrome: cb) {}
        a.open(p, chrome: ca)
        #expect(m.janelas.haOutras(alem: idA))
        m.janelas.sair(idA)
        b.open(p, chrome: cb)
        #expect(b.workspace?.project.id == p.id)
        a.closeWorkspace()
        b.closeWorkspace()
    }

    /// Os ajustes são um só; o layout é de cada janela.
    @Test func ajustesChegamAsOutrasSemLevarOLayout() async throws {
        let m = try mundo()
        let a = app(m), b = app(m)
        let ca = ChromeState(), cb = ChromeState()
        m.janelas.entrar(UUID(), app: a, chrome: ca) {}
        m.janelas.entrar(UUID(), app: b, chrome: cb) {}

        ca.snapshot.theme = .latte
        ca.snapshot.editor.fontSize = 19
        #expect(cb.snapshot.theme == .latte, "o tema não chegou à outra janela")
        #expect(cb.snapshot.editor.fontSize == 19)

        ca.snapshot.agentVisible = false
        ca.snapshot.sideWidth = 400
        #expect(cb.snapshot.agentVisible, "esconder o agente numa janela escondeu na outra")
        #expect(cb.snapshot.sideWidth != 400)

        // A outra janela muda outro ajuste e não desfaz o primeiro — era o "último a
        // gravar ganha".
        cb.snapshot.uiScale = 1.2
        #expect(ca.snapshot.uiScale == 1.2 && ca.snapshot.theme == .latte)
        await m.janelas.store.flush()
        let gravado = m.janelas.store.load()
        #expect(gravado.theme == .latte && gravado.uiScale == 1.2 && gravado.editor.fontSize == 19)
        #expect(m.janelas.snapshotInicial().theme == .latte, "a janela nova nasceria com o estado velho")
    }

    @Test func queProjetoCadaJanelaAbre() {
        let x = UUID(), ultimo = UUID()
        // O que a janela lembra vale sempre.
        #expect(Janelas.projetoParaAbrir(guardado: x.uuidString, sessoes: 3, ultimo: ultimo) == x)
        // Uma janela só: como sempre foi, volta o último projeto.
        #expect(Janelas.projetoParaAbrir(guardado: "", sessoes: 1, ultimo: ultimo) == ultimo)
        #expect(Janelas.projetoParaAbrir(guardado: "hub", sessoes: 1, ultimo: ultimo) == ultimo)
        // Janela nova, com outras abertas: começa na lista.
        #expect(Janelas.projetoParaAbrir(guardado: "", sessoes: 2, ultimo: ultimo) == nil)
        #expect(Janelas.projetoParaAbrir(guardado: "hub", sessoes: 2, ultimo: ultimo) == nil)
    }
}
