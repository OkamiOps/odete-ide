@testable import OdeteCore
import Testing

struct IgnoreTests {
    @Test func noiseDirectories() {
        #expect(Ignore.isNoisePath("node_modules/react/index.js"))
        #expect(Ignore.isNoisePath("src/node_modules/x"))
        #expect(Ignore.isNoisePath(".git/HEAD"))
        #expect(Ignore.isNoisePath("dist/app.js"))
        #expect(Ignore.isNoisePath(".next/cache"))
    }

    @Test func noiseFiles() {
        #expect(Ignore.isNoisePath(".DS_Store"))
        #expect(Ignore.isNoisePath("src/.DS_Store"))
    }

    @Test func normalPaths() {
        #expect(!Ignore.isNoisePath("src/a.ts"))
        #expect(!Ignore.isNoisePath("package.json"))
        #expect(!Ignore.isNoisePath("builder/x.ts"))
    }
}
