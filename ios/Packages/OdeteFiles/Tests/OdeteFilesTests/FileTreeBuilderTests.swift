import Foundation
@testable import OdeteFiles
import Testing

struct FileTreeBuilderTests {
    @Test func buildsSortedTreeIgnoringNoise() throws {
        let root = try tempDir()
        let ops = FileOps(root: root)
        try ops.write("src/b.ts", "")
        try ops.write("src/A.ts", "")
        try ops.write("zeta.md", "")
        try ops.write("node_modules/x/index.js", "")
        try ops.write(".odete/project.json", "{}")
        try ops.createDirectory("assets")
        let tree = try FileTreeBuilder.build(at: root)
        #expect(tree.children?.map(\.name) == ["assets", "src", "zeta.md"])
        let src = tree.children?[1]
        #expect(src?.children?.map(\.name) == ["A.ts", "b.ts"])
        #expect(tree.allFiles().map(\.path) == ["src/A.ts", "src/b.ts", "zeta.md"])
    }
}
