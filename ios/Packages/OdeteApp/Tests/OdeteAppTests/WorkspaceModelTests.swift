import Foundation
import OdeteAccounts
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
        let ws = WorkspaceModel(project: p, root: store.url(for: p), chrome: chrome, accounts: accounts)
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
