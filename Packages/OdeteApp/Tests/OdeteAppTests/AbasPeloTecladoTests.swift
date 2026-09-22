import Foundation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteCore
import OdeteFiles
import OdeteI18n
import Testing

/// ⌃Tab, ⌃⇧Tab e ⌘1…⌘9.
@MainActor
struct AbasPeloTecladoTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func make() throws -> WorkspaceModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "odete-abas-\(UUID().uuidString)")
        let store = ProjectStore(root: root)
        let p = try store.create(name: "T", template: .blank)
        let chrome = ChromeState()
        let accounts = AccountStore(url: root.appending(path: "accounts.json"), keychain: MemorySecrets())
        return WorkspaceModel(
            project: p,
            root: store.url(for: p),
            chrome: chrome,
            accounts: accounts,
            aiAccounts: AIAccountStore(url: root.appending(path: "ai.json"), secrets: MemorySecrets())
        )
    }

    @Test func proximaEAnteriorDaoAVolta() throws {
        let ws = try make()
        ws.openFile("index.html")
        ws.openFile("src/main.js")
        #expect(ws.active == "src/main.js")
        ws.irParaAba(deslocamento: 1)
        #expect(ws.active == "index.html")
        ws.irParaAba(deslocamento: -1)
        #expect(ws.active == "src/main.js")
        ws.irParaAba(deslocamento: -1)
        #expect(ws.active == "index.html")
    }

    @Test func abaPorNumero() throws {
        let ws = try make()
        ws.openFile("index.html")
        ws.openFile("src/main.js")
        ws.irParaAba(numero: 1)
        #expect(ws.active == "index.html")
        ws.irParaAba(numero: 2)
        #expect(ws.active == "src/main.js")
        // Não existe a nona: fica onde está.
        ws.irParaAba(numero: 9)
        #expect(ws.active == "src/main.js")
    }

    @Test func documentoTemOMesmoFormatoDoCentro() throws {
        let ws = try make()
        ws.openFile("index.html")
        #expect(ws.documentoAtivo == "\(ws.project.id):index.html")
        #expect(ws.documentoAtivo?.hasPrefix(ws.prefixoDosDocumentos) == true)
    }
}
