@testable import OdeteFiles
import Testing

struct TemplatesTests {
    @Test func everyTemplateHasReadme() {
        for t in Template.allCases {
            let files = t.files(projectName: "Meu App")
            #expect(files["README.md"] != nil, "\(t)")
            #expect(!files.isEmpty)
        }
    }

    @Test func viteReactShape() {
        let f = Template.viteReact.files(projectName: "Meu App")
        #expect(f["package.json"]?.contains("\"name\": \"meu-app\"") == true)
        #expect(f["src/main.tsx"] != nil && f["index.html"] != nil)
    }

    @Test func swiftPlaygroundShape() {
        let f = Template.swiftPlayground.files(projectName: "Meu App")
        #expect(f["MeuApp.swiftpm/Package.swift"]?.contains("iOSApplication") == true)
        #expect(f["MeuApp.swiftpm/ContentView.swift"] != nil)
    }
}
