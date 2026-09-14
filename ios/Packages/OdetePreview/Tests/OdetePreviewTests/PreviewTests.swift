import Foundation
@testable import OdetePreview
import Testing

struct PreviewTests {
    @MainActor
    @Test func modelBasics() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "odete-pv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let m = PreviewModel(root: root)
        #expect(!m.hasIndex)
        try "<h1>oi</h1>".write(to: root.appending(path: "index.html"), atomically: true, encoding: .utf8)
        #expect(m.hasIndex && m.staticURL().absoluteString == "odete://static/index.html")
        m.log(.error, "x"); m.log(.log, "y")
        #expect(m.errorCount == 1 && m.console.count == 2)
        m.reload(); m.go(m.staticURL("a.html"))
        #expect(m.reloadTick == 1 && m.navTick == 1 && m.url?.path == "/a.html")
    }

    @Test func viewports() {
        #expect(Viewport.phone.width == 390 && Viewport.fill.width == nil && Viewport.allCases.count == 3)
    }
}
