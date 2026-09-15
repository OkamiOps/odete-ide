import Foundation
@testable import OdeteCore
import Testing

struct ChromeSnapshotTests {
    /// O estado salvo de quem usou uma versão anterior pode ter painel que não existe
    /// mais. Se isso derrubar a decodificação, some tudo junto: tema, abas, projetos.
    @Test func painelDesconhecidoViraArquivosSemLevarORestoJunto() throws {
        let json = """
        {"side":"outline","theme":"cursor","sideOpen":true,"sideWidth":321,"center":"preview"}
        """
        let snap = try JSONDecoder().decode(ChromeSnapshot.self, from: Data(json.utf8))
        #expect(snap.side == .files)
        #expect(snap.theme == .cursor)
        #expect(snap.sideWidth == 321)
        #expect(snap.center == .preview)
    }

    @Test func painelConhecidoContinuaValendo() throws {
        let json = #"{"side":"git"}"#
        let snap = try JSONDecoder().decode(ChromeSnapshot.self, from: Data(json.utf8))
        #expect(snap.side == .git)
    }
}
