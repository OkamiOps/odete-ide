import Foundation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteCore
import OdeteFiles
import Testing

@MainActor
struct WorkspaceModelTests {
    func make() throws -> (WorkspaceModel, ChromeState, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "odete-ws-\(UUID().uuidString)")
        let store = ProjectStore(root: root)
        let p = try store.create(name: "T", template: .blank)
        let chrome = ChromeState()
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

    @Test func opensClosesAndPersistsTabs() throws {
        let (ws, chrome, _) = try make()
        #expect(ws.tree.allFiles().map(\.path).contains("index.html"))
        ws.openFile("index.html")
        ws.openFile("src/main.js")
        #expect(ws.tabs.map(\.path) == ["index.html", "src/main.js"])
        #expect(ws.active == "src/main.js")
        #expect(chrome.tabs(for: ws.project.id).count == 2)
        ws.closeTab("src/main.js")
        #expect(ws.active == "index.html")
        ws.closeTab("index.html")
        #expect(ws.active == nil && ws.tabs.isEmpty)
    }

    /// Arquivo aberto reescrito por fora (git, terminal, agente) volta para a tela; com
    /// alteração não salva na aba, o que a pessoa digitou fica.
    @Test func mudancaPorForaVoltaParaOBuffer() throws {
        let (ws, chrome, root) = try make()
        chrome.snapshot.editor.autoSave = false
        ws.openFile("index.html")
        let arquivo = root.appending(path: "index.html")

        try "<h1>de fora</h1>\n".write(to: arquivo, atomically: true, encoding: .utf8)
        ws.conferirDisco()
        #expect(ws.text(for: "index.html") == "<h1>de fora</h1>\n")
        #expect(ws.activeTab?.isDirty == false)

        ws.setText("<h1>meu texto</h1>\n", for: "index.html")
        try "<h1>de fora de novo</h1>\n".write(to: arquivo, atomically: true, encoding: .utf8)
        ws.conferirDisco()
        #expect(ws.text(for: "index.html") == "<h1>meu texto</h1>\n")
    }

    @Test func dirtyAndSave() throws {
        let (ws, chrome, root) = try make()
        chrome.snapshot.editor.autoSave = false
        ws.openFile("src/main.js")
        ws.setText("// novo\n", for: "src/main.js")
        #expect(ws.activeTab?.isDirty == true)
        ws.save()
        #expect(ws.activeTab?.isDirty == false)
        #expect(try String(contentsOf: root.appending(path: "src/main.js"), encoding: .utf8) == "// novo\n")
    }

    @Test func fileOpsKeepTabsInSync() throws {
        let (ws, _, _) = try make()
        ws.openFile("src/main.js")
        ws.rename("src/main.js", to: "app.js")
        #expect(ws.tabs.map(\.path) == ["src/app.js"])
        #expect(ws.active == "src/app.js")
        ws.createFolder(near: nil, name: "lib")
        ws.move("src/app.js", into: "lib")
        #expect(ws.active == "lib/app.js")
        ws.delete("lib")
        #expect(ws.tabs.isEmpty)
        let created = ws.createFile(near: nil)
        #expect(created == "sem-titulo.txt")
        #expect(ws.active == "sem-titulo.txt")
    }

    @Test func revealLine() throws {
        let (ws, _, _) = try make()
        ws.open("index.html", line: 7)
        #expect(ws.reveal?.line == 7)
        let t = ws.reveal?.token
        ws.open("index.html", line: 7)
        #expect(ws.reveal?.token != t)
    }
}

struct AgentModelTests {
    @MainActor
    @Test func agentWithoutAccountAndChats() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "odete-app-ag-\(UUID().uuidString)")
        let store = ProjectStore(root: base.appending(path: "Projects"))
        let p = try store.create(name: "Ag", template: .blank)
        let chrome = ChromeState()
        let ws = WorkspaceModel(
            project: p,
            root: store.url(for: p),
            chrome: chrome,
            accounts: AccountStore(url: base.appending(path: "acc.json"), keychain: MemorySecrets()),
            aiAccounts: AIAccountStore(url: base.appending(path: "ai.json"), secrets: MemorySecrets())
        )
        let ag = try #require(ws.agent)
        #expect(ag.account == nil && ag.items.isEmpty && ag.mode == .build && ag.permit == .auto)
        ag.draft = "oi"
        ag.send()
        #expect(ag.items.count == 1 && !ag.running)
        if case let .error(_, t) = ag.items[0] {
            #expect(t.contains("Conecte"))
        } else {
            Issue.record("esperava erro")
        }
        ag.setMode(.plan); ag.setPermit(.full)
        #expect(chrome.snapshot.agentByProject[p.id]?.mode == "plan" && ag.permit == .full)
        // patches do host aparecem e o editor recarrega
        try ag.host.write("index.html", "<h1>novo</h1>")
        ag.patches.queue(path: "index.html", before: "", after: "<h1>novo</h1>")
        try await Task.sleep(for: .milliseconds(50))
        #expect(ag.pendingPatches.count == 1)
        ag.rejectAll()
        try await Task.sleep(for: .milliseconds(50))
        #expect(ag.pendingPatches.isEmpty)
        ws.stop()
    }
}
