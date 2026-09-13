import Foundation
import Testing
@testable import OdeteFiles

@Suite struct TextSearchTests {
    @Test func literalAndRegex() throws {
        let root = try tempDir()
        let ops = FileOps(root: root)
        try ops.write("a.ts", "const Foo = 1;\nlet bar = foo();\n")
        try ops.write("node_modules/x.js", "foo")
        try ops.write("b.md", "nada aqui")
        let hits = try TextSearch.search(root: root, query: "foo")
        #expect(hits.map { "\($0.path):\($0.line):\($0.column)" } == ["a.ts:1:7", "a.ts:2:11"])
        let cs = try TextSearch.search(root: root, query: "foo", caseSensitive: true)
        #expect(cs.count == 1 && cs[0].line == 2)
        let re = try TextSearch.search(root: root, query: "^let \\w+", regex: true)
        #expect(re.count == 1 && re[0].column == 1)
        #expect(try TextSearch.search(root: root, query: "").isEmpty)
    }
}
