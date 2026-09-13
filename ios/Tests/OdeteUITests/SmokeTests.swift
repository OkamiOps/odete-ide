import XCTest

final class SmokeTests: XCTestCase {
    @MainActor
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Odete"].waitForExistence(timeout: 5))
    }
}
