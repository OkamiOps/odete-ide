import Foundation
@testable import OdeteCore
import Testing

struct StackTests {
    private func pkg(_ deps: [String: String]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["dependencies": deps])
    }

    @Test func detectsFrameworks() {
        #expect(Stack.detect(paths: ["package.json"], packageJSON: pkg(["next": "15"])).id == "next")
        #expect(Stack.detect(paths: ["package.json"], packageJSON: pkg(["astro": "5"])).id == "astro")
        #expect(Stack.detect(paths: ["package.json"], packageJSON: pkg(["@nestjs/core": "11"])).kind == .api)
        #expect(Stack.detect(paths: ["package.json"], packageJSON: pkg(["vite": "8", "react": "19"])).label == "Vite")
        #expect(Stack.detect(paths: ["package.json"], packageJSON: pkg(["react": "19"])).id == "react")
    }

    @Test func swiftAndHtml() {
        #expect(Stack.detect(paths: ["Package.swift", "Sources/App.swift"], packageJSON: nil).kind == .swift)
        #expect(Stack.detect(paths: ["App.swiftpm/Package.swift"], packageJSON: nil).kind == .swift)
        #expect(Stack.detect(paths: ["index.html"], packageJSON: nil) == .html)
        #expect(Stack.detect(paths: ["index.html"], packageJSON: Data("{broken".utf8)) == .html)
    }
}
