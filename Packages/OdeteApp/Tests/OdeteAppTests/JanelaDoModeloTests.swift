import Foundation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteCore
import OdeteFiles
import OdeteI18n
import Testing

/// A janela do modelo: a lista da conta primeiro, depois `LimitesDosModelos` — e o anel
/// do compositor usa a mesma que o laço.
@MainActor
@Suite(.serialized) struct JanelaDoModeloTests {
    @Test func semListaDaContaVemDosLimitesDosModelos() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "odete-janela-\(UUID().uuidString)")
        let store = ProjectStore(root: base)
        let p = try store.create(name: "T", template: .blank)
        let ia = AIAccountStore(url: base.appending(path: "ia-teste.json"), secrets: MemorySecrets())
        ia.addBuiltIn(AIAccount(kind: .apple))
        let ws = WorkspaceModel(
            project: p,
            root: store.url(for: p),
            chrome: ChromeState(),
            accounts: AccountStore(url: base.appending(path: "contas-teste.json"), keychain: MemorySecrets()),
            aiAccounts: ia
        )
        let ag = try #require(ws.agent)
        #expect(ag.account?.kind == .apple)
        await ag.atualizarJanela()
        let esperado = await LimitesDosModelos.limites(provider: .apple, model: ag.model).contexto
        #expect(esperado != nil && ag.janelaDoModelo == esperado, "a janela não veio de LimitesDosModelos")
        // A lista da conta, quando diz, vence; senão vale a dos limites.
        let daLista = ag.models.first { $0.id == ag.model }?.ctx
        #expect(ag.janelaDeContexto == (daLista ?? esperado))
        #expect(ag.contextWindow == ag.janelaDeContexto, "o anel e o laço contam janelas diferentes")
        ws.stop()
    }
}
