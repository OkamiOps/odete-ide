import XCTest

final class SmokeTests: XCTestCase {
    @MainActor
    func testHubOrWorkspaceAppears() {
        let app = XCUIApplication()
        app.launch()
        // Ou o hub (botão "Novo projeto") ou um workspace reaberto (botão "Projetos").
        //
        // Os dois idiomas porque o simulador roda no idioma do Mac: desde que o app foi
        // traduzido, procurar só o rótulo em português fazia este teste falhar sempre,
        // sem que nada estivesse quebrado.
        let nomes = ["Novo projeto", "New project", "Projetos", "Projects"]
        let ok = nomes.contains { nome in
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", nome))
                .firstMatch.waitForExistence(timeout: nome == nomes[0] ? 12 : 2)
        }
        XCTAssertTrue(ok, "nem o hub nem o workspace apareceram")
    }
}
