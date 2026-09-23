import Foundation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteCore
import OdeteFiles
import OdeteI18n
import Testing

/// O que uma janela faz com um projeto que está aberto em outra — e o que não pode
/// sumir no caminho.
@MainActor
@Suite(.serialized) struct VariasJanelasTests {
    init() {
        Texto.escolher(.ptBR)
    }

    struct Mundo {
        let janelas: Janelas
        let store: ProjectStore
        let raiz: URL
    }

    func mundo() throws -> Mundo {
        let raiz = FileManager.default.temporaryDirectory.appending(path: "odete-varias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
        let store = ProjectStore(root: raiz.appending(path: "Projects"))
        let estado = StateStore(url: raiz.appending(path: "state.json"), debounce: .milliseconds(1))
        let registro = ExternalProjects(file: raiz.appending(path: "external.json"))
        return Mundo(janelas: Janelas(store: estado, external: registro), store: store, raiz: raiz)
    }

    /// Uma janela deste mundo: o registro de pastas externas é o do mundo, não o do
    /// simulador, para um teste não ver o que outro deixou.
    func app(_ m: Mundo) -> AppModel {
        AppModel(
            store: m.store,
            accounts: AccountStore(url: m.raiz.appending(path: "contas-teste.json"), keychain: MemorySecrets()),
            aiAccounts: AIAccountStore(url: m.raiz.appending(path: "ia-teste.json"), secrets: MemorySecrets()),
            external: m.janelas.external
        )
    }

    /// Duas janelas, uma com o projeto aberto e a outra no hub.
    func duasJanelas(_ m: Mundo) -> (AppModel, ChromeState, AppModel, ChromeState) {
        let a = app(m), b = app(m)
        let ca = ChromeState(), cb = ChromeState()
        ca.snapshot.editor.autoSave = false
        m.janelas.entrar(UUID(), app: a, chrome: ca) {}
        m.janelas.entrar(UUID(), app: b, chrome: cb) {}
        a.refresh()
        b.refresh()
        return (a, ca, b, cb)
    }

    /// Renomear pelo hub de uma janela o projeto aberto em outra: a outra continuava
    /// gravando no caminho velho, e o salvamento recriava a pasta — um projeto-fantasma.
    @Test func renomearAbertoEmOutraJanelaNaoDeixaFantasma() throws {
        let m = try mundo()
        let p = try m.store.create(name: "Velho", template: .blank)
        let (a, ca, b, _) = duasJanelas(m)
        a.open(p, chrome: ca)
        let ws = try #require(a.workspace)
        ws.openFile("index.html")
        ws.setText("<h1>não salvo</h1>", for: "index.html")

        b.rename(p, to: "Novo")
        #expect(a.workspace == nil, "a outra janela ficou com o projeto aberto no caminho velho")
        a.closeWorkspace()
        #expect(try m.store.list().map(\.name) == ["Novo"])
        #expect(a.projects.map(\.name) == ["Novo"], "o hub da outra janela ficou com o nome velho")
        let texto = try String(contentsOf: m.store.root.appending(path: "Novo/index.html"), encoding: .utf8)
        #expect(texto == "<h1>não salvo</h1>", "o que estava sendo digitado se perdeu")
    }

    @Test func apagarAbertoEmOutraJanelaNaoRessuscita() throws {
        let m = try mundo()
        let p = try m.store.create(name: "Some", template: .blank)
        let (a, ca, b, _) = duasJanelas(m)
        a.open(p, chrome: ca)
        let ws = try #require(a.workspace)
        ws.openFile("index.html")
        ws.setText("<h1>x</h1>", for: "index.html")

        b.delete(p)
        #expect(a.workspace == nil)
        a.closeWorkspace()
        #expect(try m.store.list().isEmpty, "a pasta apagada voltou pelo salvamento da outra janela")
    }

    /// Cada janela tinha o seu `ExternalProjects`, e cada um gravava o `external.json`
    /// inteiro com o que *ele* sabia — a pasta que uma janela abria sumia pela outra.
    @Test func umRegistroDePastasExternasParaTodasAsJanelas() throws {
        let m = try mundo()
        let contas = AccountStore(url: m.raiz.appending(path: "c.json"), keychain: MemorySecrets())
        let ia = AIAccountStore(url: m.raiz.appending(path: "i.json"), secrets: MemorySecrets())
        let a = AppModel(store: m.store, accounts: contas, aiAccounts: ia)
        let b = AppModel(store: m.store, accounts: contas, aiAccounts: ia)
        #expect(a.external === b.external)
    }

    /// O atalho "Rodar comando" falava com a última janela usada. Com o projeto aberto
    /// em outra, `open` trazia a outra para a frente e o comando rodava no projeto
    /// desta — o errado.
    @Test func rodarComandoVaiParaAJanelaDoProjeto() throws {
        let m = try mundo()
        let p = try m.store.create(name: "P", template: .blank)
        let q = try m.store.create(name: "Q", template: .blank)
        let (a, ca, b, cb) = duasJanelas(m)
        a.open(p, chrome: ca)
        b.open(q, chrome: cb)
        let ponte = IntentBridge()
        ponte.bind(app: b, chrome: cb)

        #expect(ponte.runCommand("echo oi", in: p.id))
        #expect(a.workspace?.run.active?.temEntrada == true, "o comando não rodou na janela do projeto")
        #expect(b.workspace?.run.active?.temEntrada != true, "o comando rodou no projeto errado")
        a.closeWorkspace()
        b.closeWorkspace()
    }

    /// A pasta de um projeto do app, escolhida de novo pelo app Arquivos, virava um
    /// segundo projeto — externo, com outro id — apontando para os mesmos arquivos.
    @Test func abrirPelaPastaUmProjetoDoAppNaoDuplica() throws {
        let m = try mundo()
        let p = try m.store.create(name: "Meu", template: .blank)
        let a = app(m)
        let q = a.addExternal(m.store.url(for: p))
        #expect(q?.id == p.id)
        #expect(q?.external == false)
    }
}
