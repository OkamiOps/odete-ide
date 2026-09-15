@testable import OdeteCore
import Testing

struct OutlineTests {
    @Test func typescript() {
        let src = """
        import x from "y"
        export default function App() {
          const [n, setN] = useState(0)
          return null
        }
        export const helper = (a: number) => a * 2
        class Store {
          load() {
            if (x) {
            }
          }
        }
        interface Props { a: number }
        const total = 3
        """
        let items = Outline.items(text: src, language: .tsx)
        #expect(items.map(\.name) == ["App", "helper", "Store", "load", "Props", "total"])
        #expect(items[0].kind == .export && items[0].line == 2)
        #expect(items[3].kind == .property && items[3].level == 1)
        #expect(items[5].kind == .variable)
    }

    @Test func swift() {
        let src = """
        import SwiftUI
        struct ContentView: View {
            @State private var count = 0
            var body: some View {
                Text("x")
            }
            func bump() {
                let local = 1
            }
        }
        enum Kind { case a }
        """
        let items = Outline.items(text: src, language: .swift)
        #expect(items.map(\.name) == ["ContentView", "count", "body", "bump", "Kind"])
        #expect(items[2].kind == .property)
        #expect(items[3].level == 1)
    }

    @Test func markdownSkipsFences() {
        let src = "# Título\n\n```sh\n# comentário\n```\n\n## Sub\n#semtítulo\n"
        let items = Outline.items(text: src, language: .markdown)
        #expect(items.map(\.name) == ["Título", "Sub"])
        #expect(items[1].level == 1 && items[1].line == 7)
    }

    @Test func cssAndJson() {
        let css = ".card {\n  color: red;\n}\n@media (max-width: 600px) {\n  .card { padding: 0 }\n}\n"
        let items = Outline.items(text: css, language: .css)
        #expect(items.map(\.name) == [".card", "@media (max-width: 600px)", ".card"])
        #expect(items[2].level == 1)
        let json = "{\n  \"name\": \"x\",\n  \"scripts\": {\n    \"dev\": \"vite\"\n  },\n  \"deps\": {}\n}\n"
        #expect(Outline.items(text: json, language: .json).map(\.name) == ["name", "scripts", "deps"])
    }

    @Test func html() {
        let src = "<main id=\"app\">\n<h1>Olá</h1>\n<section id=\"hero\"></section>\n"
        let items = Outline.items(text: src, language: .html)
        #expect(items.map(\.name) == ["main#app", "Olá", "section#hero"])
        #expect(items[1].kind == .heading)
    }
}
