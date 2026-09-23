import Foundation
import Observation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteCore
import OdeteEditor
import OdeteFiles
import OdeteI18n
import Testing

/// O que o `onChange` viu. Ele roda síncrono, no `willSet` da escrita.
final class LidoNoAviso: @unchecked Sendable {
    var vezes = 0
    var chaves: Int?
}

/// Aprovar um patch com o editor aberto derrubava o app com "Fatal access conflict
/// detected". A escrita de `patchChanges` (e das outras análises) segurava um acesso
/// `inout` ao valor guardado durante todo o `withMutation`; o `willSet` da observação
/// fazia o SwiftUI refazer o corpo do editor ali mesmo, o corpo lia `patchChanges`, e a
/// leitura batia no acesso ainda aberto. A checagem de exclusividade vale também em
/// Release, então o app de produção caía igual.
///
/// O `onChange` de `withObservationTracking` roda no mesmo ponto que o SwiftUI (síncrono,
/// no `willSet`), e aqui faz o papel do corpo da view: lê a propriedade que está sendo
/// escrita. Com o conflito, o processo de teste aborta.
@MainActor
struct EscritaDaAnaliseTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func make() throws -> WorkspaceModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "odete-escrita-\(UUID().uuidString)")
        let store = ProjectStore(root: root)
        let p = try store.create(name: "T", template: .blank)
        let chrome = ChromeState()
        chrome.snapshot.editor.autoSave = false
        let accounts = AccountStore(url: root.appending(path: "accounts.json"), keychain: MemorySecrets())
        return WorkspaceModel(
            project: p,
            root: store.url(for: p),
            chrome: chrome,
            accounts: accounts,
            aiAccounts: AIAccountStore(url: root.appending(path: "ai.json"), secrets: MemorySecrets())
        )
    }

    /// O caso do crash: `refreshPatchMarks` escreve as marcas do patch aprovado e o editor
    /// aberto relê `patchChanges` no aviso.
    @Test func marcasDoPatchLidasNoAvisoNaoDerrubam() throws {
        let ws = try make()
        let marcas = [EditorLineChange(line: 2, kind: .added)]
        let lido = LidoNoAviso()
        withObservationTracking {
            _ = ws.patchChanges
        } onChange: {
            MainActor.assumeIsolated {
                lido.vezes += 1
                lido.chaves = ws.patchChanges.count
            }
        }
        ws.patchChanges["a.js"] = marcas
        #expect(lido.vezes == 1)
        // No `willSet` o valor ainda é o de antes.
        #expect(lido.chaves == 0)
        #expect(ws.patchChanges["a.js"] == marcas)
    }

    /// As análises que passam pela mesma escrita. `gutterFiles` também passa, mas um
    /// `FileDiff` só nasce de um diff do git de verdade.
    enum Analise: String, CaseIterable, Sendable {
        case outlines, links, patchChanges, lint, syntax, gutter

        @MainActor func chaves(_ ws: WorkspaceModel) -> Int {
            switch self {
            case .outlines: ws.outlines.count
            case .links: ws.links.count
            case .patchChanges: ws.patchChanges.count
            case .lint: ws.lint.count
            case .syntax: ws.syntax.count
            case .gutter: ws.gutter.count
            }
        }

        /// Uma chave nova com lista vazia: já é diferente de `[:]`, então avisa.
        @MainActor func escrever(_ ws: WorkspaceModel) {
            switch self {
            case .outlines: ws.outlines["a.js"] = []
            case .links: ws.links["a.js"] = []
            case .patchChanges: ws.patchChanges["a.js"] = []
            case .lint: ws.lint["a.js"] = []
            case .syntax: ws.syntax["a.js"] = []
            case .gutter: ws.gutter["a.js"] = []
            }
        }
    }

    @Test(arguments: Analise.allCases)
    func lerNoAvisoDaEscritaNaoDerruba(_ a: Analise) throws {
        let ws = try make()
        let lido = LidoNoAviso()
        withObservationTracking {
            _ = a.chaves(ws)
        } onChange: {
            MainActor.assumeIsolated {
                lido.vezes += 1
                lido.chaves = a.chaves(ws)
            }
        }
        a.escrever(ws)
        #expect(lido.vezes == 1)
        #expect(lido.chaves == 0)
        #expect(a.chaves(ws) == 1)
    }
}
