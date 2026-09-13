import XCTest

final class SmokeTests: XCTestCase {
    @MainActor
    func testHubOrWorkspaceAppears() {
        let app = XCUIApplication()
        app.launch()
        // Ou o hub (botão "Novo projeto") ou um workspace reaberto (botão "Projetos").
        let hub = app.buttons["Novo projeto"]
        let ws = app.buttons["Projetos"]
        let ok = hub.waitForExistence(timeout: 8) || ws.waitForExistence(timeout: 2)
        XCTAssertTrue(ok)
    }
}
