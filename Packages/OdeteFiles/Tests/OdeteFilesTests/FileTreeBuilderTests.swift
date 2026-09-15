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

/// Com "mostrar ocultos", node_modules, .git e companhia entram na árvore — mas por ler,
/// para abrir o projeto não esperar por milhares de arquivos.
struct ArvoreComOcultosTests {
    func projeto() throws -> URL {
        let raiz = FileManager.default.temporaryDirectory.appending(path: "odete-ocultos-\(UUID().uuidString)")
        let fm = FileManager.default
        for pasta in ["src", "node_modules/left-pad", ".git/objects", ".odete"] {
            try fm.createDirectory(at: raiz.appending(path: pasta), withIntermediateDirectories: true)
        }
        try "a".write(to: raiz.appending(path: "src/app.ts"), atomically: true, encoding: .utf8)
        try "{}".write(
            to: raiz.appending(path: "node_modules/left-pad/package.json"),
            atomically: true,
            encoding: .utf8
        )
        try "x".write(to: raiz.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        return raiz
    }

    @Test func semOcultosNaoMostraNodeModulesNemGit() throws {
        let arvore = try FileTreeBuilder.build(at: projeto())
        let nomes = (arvore.children ?? []).map(\.name)
        #expect(nomes.contains("src"))
        #expect(nomes.contains(".gitignore"))
        #expect(!nomes.contains("node_modules"))
        #expect(!nomes.contains(".git"))
        #expect(!nomes.contains(".odete"))
    }

    @Test func comOcultosMostraMasNaoLe() throws {
        let raiz = try projeto()
        let arvore = try FileTreeBuilder.build(at: raiz, ocultos: true)
        let filhos = arvore.children ?? []
        #expect(filhos.map(\.name).contains("node_modules"))
        #expect(filhos.map(\.name).contains(".git"))
        let nm = try #require(filhos.first { $0.name == "node_modules" })
        #expect(nm.naoLido)
        // src continua lida na hora: é pasta de trabalho, não de ruído.
        let src = try #require(filhos.first { $0.name == "src" })
        #expect(!src.naoLido)

        let dentro = try FileTreeBuilder.children(
            of: raiz.appending(path: "node_modules"),
            prefix: "node_modules",
            ocultos: true
        )
        #expect(dentro.map(\.name) == ["left-pad"])
    }

    @Test func inserirColocaOsFilhosNoLugarCerto() throws {
        let raiz = try projeto()
        var arvore = try FileTreeBuilder.build(at: raiz, ocultos: true)
        let dentro = try FileTreeBuilder.children(
            of: raiz.appending(path: "node_modules"),
            prefix: "node_modules",
            ocultos: true
        )
        let inseriu = arvore.inserir(dentro, em: "node_modules")
        #expect(inseriu)
        #expect(arvore.find("node_modules/left-pad") != nil)
        #expect(arvore.find("node_modules")?.naoLido == false)
    }
}
