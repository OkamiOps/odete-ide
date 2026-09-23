import Foundation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteCore
import OdeteFiles
import OdeteGit
import OdeteI18n
import Testing

/// O histórico local visto do app: o editor, a aba suja, a mudança por fora, o apagar da
/// árvore e a paleta. Cada teste cria um projeto novo, com id próprio — as versões dele
/// ficam numa pasta só dele dentro do histórico do app.
@MainActor
struct HistoricoLocalAppTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func make() throws -> (WorkspaceModel, ChromeState, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "odete-hist-\(UUID().uuidString)")
        let store = ProjectStore(root: root)
        let p = try store.create(name: "T", template: .blank)
        let chrome = ChromeState()
        chrome.snapshot.editor.autoSave = false
        let accounts = AccountStore(url: root.appending(path: "accounts.json"), keychain: MemorySecrets())
        let ws = WorkspaceModel(
            project: p,
            root: store.url(for: p),
            chrome: chrome,
            accounts: accounts,
            aiAccounts: AIAccountStore(url: root.appending(path: "ai.json"), secrets: MemorySecrets())
        )
        return (ws, chrome, store.url(for: p))
    }

    func conteudos(_ ws: WorkspaceModel, _ caminho: String) -> [String] {
        ws.historico.versoes(de: caminho, raiz: ws.root).map {
            String(decoding: ws.historico.dados($0, de: caminho, raiz: ws.root) ?? Data(), as: UTF8.self)
        }
    }

    @Test func salvarGuardaOQueEstavaNoDisco() throws {
        let (ws, _, root) = try make()
        let original = try String(contentsOf: root.appending(path: "index.html"), encoding: .utf8)
        ws.openFile("index.html")
        ws.setText("<h1>novo</h1>\n", for: "index.html")
        ws.save("index.html")
        let v = ws.historico.versoes(de: "index.html", raiz: ws.root)
        #expect(v.first?.origem == .voce)
        #expect(conteudos(ws, "index.html") == [original])
    }

    /// O agente escreveu com a aba suja: o texto não salvo não some ao recarregar — a aba
    /// fica com ele (em conflito com o disco) e ele também vira versão no histórico.
    @Test func recarregarGuardaOTextoNaoSalvo() throws {
        let (ws, _, root) = try make()
        ws.openFile("index.html")
        ws.setText("digitado e não salvo\n", for: "index.html")
        try "do agente\n".write(to: root.appending(path: "index.html"), atomically: true, encoding: .utf8)
        ws.reloadBuffer("index.html")
        #expect(ws.text(for: "index.html") == "digitado e não salvo\n")
        let v = ws.historico.versoes(de: "index.html", raiz: ws.root)
        #expect(v.first?.origem == .recarregar)
        #expect(conteudos(ws, "index.html").first == "digitado e não salvo\n")
    }

    /// Mudança por fora numa aba limpa: o que a aba mostrava vira versão.
    @Test func mudancaPorForaGuardaOQueAAbaMostrava() throws {
        let (ws, _, root) = try make()
        ws.openFile("index.html")
        let antes = ws.text(for: "index.html")
        let arquivo = root.appending(path: "index.html")
        try "<h1>de fora</h1>\n".write(to: arquivo, atomically: true, encoding: .utf8)
        ws.conferirDisco(arquivo.path)
        #expect(ws.text(for: "index.html") == "<h1>de fora</h1>\n")
        #expect(ws.historico.versoes(de: "index.html", raiz: ws.root).first?.origem == .externo)
        #expect(conteudos(ws, "index.html").first == antes)
    }

    @Test func apagarPelaArvoreApareceNosApagados() throws {
        let (ws, _, _) = try make()
        ws.delete("src/main.js")
        let apagados = ws.historico.apagados(raiz: ws.root)
        #expect(apagados.map(\.caminho) == ["src/main.js"])
        #expect(apagados.first?.ultima.origem == .apagar)
        let item = try #require(apagados.first)
        try ws.historico.restaurar(item.ultima, caminho: item.caminho, raiz: ws.root)
        #expect(ws.ops.exists("src/main.js"))
    }

    @Test func paletaAbreAsFolhas() throws {
        let (ws, _, _) = try make()
        #expect(ComandosDoHistorico.itens.map(\.id) == [ComandosDoHistorico.arquivo, ComandosDoHistorico.apagados])
        ComandosDoHistorico.executar(ComandosDoHistorico.arquivo, ws: ws)
        #expect(ws.historicoLocal.arquivo == nil, "sem arquivo aberto não há o que mostrar")
        ws.openFile("index.html")
        ComandosDoHistorico.executar(ComandosDoHistorico.arquivo, ws: ws)
        #expect(ws.historicoLocal.arquivo == "index.html")
        ComandosDoHistorico.executar(ComandosDoHistorico.apagados, ws: ws)
        #expect(ws.historicoLocal.apagadosEm == "")
    }

    /// A folha compara com o mesmo motor do modo Diff.
    @Test func diffDeDoisTextos() {
        let d = FileDiff.entre(Data("a\nb\nc\n".utf8), Data("a\nB\nc\nd\n".utf8), caminho: "x.txt")
        #expect(!d.isBinary)
        #expect(d.additions == 2)
        #expect(d.deletions == 1)
        #expect(FileDiff.entre(Data("igual\n".utf8), Data("igual\n".utf8), caminho: "x.txt").hunks.isEmpty)
        #expect(FileDiff.entre(Data([0, 1, 2, 0]), Data([0, 9, 0]), caminho: "x.bin").isBinary)
    }
}
