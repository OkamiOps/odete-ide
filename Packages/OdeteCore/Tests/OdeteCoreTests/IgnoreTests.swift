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

    /// Num projeto do iCloud os pacotes moram em `node_modules.nosync`; tudo que pula
    /// `node_modules` tem que pular ela também.
    @Test func pastaDeModulosForaDaNuvem() {
        #expect(Ignore.isNoisePath("node_modules.nosync/react/index.js"))
        #expect(Ignore.isNoisePath("node_modules.nosync"))
        #expect(!Ignore.isNoisePath("src/node_modules.nosync.ts"))
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
