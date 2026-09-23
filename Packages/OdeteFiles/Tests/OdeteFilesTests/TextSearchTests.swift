import Foundation
@testable import OdeteFiles
import Testing

struct TextSearchTests {
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

    /// A troca discordava da busca: `^import` trocava só a primeira linha do arquivo, e
    /// com "Aa" desligado a regex da troca diferenciava maiúsculas.
    @Test func trocaIgualABusca() throws {
        let root = try tempDir()
        let ops = FileOps(root: root)
        try ops.write("a.js", "import a\nimport b\n")
        try ops.write("b.js", "<Button/>\n")
        #expect(try TextSearch.search(root: root, query: "^import", regex: true).count == 2)
        let r = try TextSearch.replace(root: root, query: "^import", with: "export", regex: true, in: ["a.js"])
        #expect(r.trocas == 2)
        #expect(try ops.read("a.js") == "export a\nexport b\n")
        #expect(try TextSearch.search(root: root, query: "button", regex: true).count == 1)
        try TextSearch.replace(root: root, query: "button", with: "Botao", regex: true, in: ["b.js"])
        #expect(try ops.read("b.js") == "<Botao/>\n")
    }

    /// Ocorrências de verdade (três numa linha são três) e linhas contadas também em CRLF,
    /// onde o arquivo inteiro virava a linha 1.
    @Test func contaOcorrenciasELinhasCRLF() throws {
        let root = try tempDir()
        let ops = FileOps(root: root)
        try ops.write("a.txt", "x x x\r\ny\r\nx\r\n")
        let hits = try TextSearch.search(root: root, query: "x")
        #expect(hits.map(\.line) == [1, 3])
        #expect(hits.map(\.ocorrencias) == [3, 1])
        #expect(hits[0].text == "x x x")
        // Busca nos textos abertos, e não no disco.
        let abertos = try TextSearch.search(root: root, query: "z", abertos: ["a.txt": "z\n"])
        #expect(abertos.map(\.path) == ["a.txt"])
    }

    @Test func grupoDaRegexNaTroca() throws {
        let c = ConsultaDeTexto(texto: "(\\w+)@(\\w+)", regex: true)
        let r = try c.trocar(em: "a@b c@d", por: "$2@$1")
        #expect(r.texto == "b@a d@c" && r.trocas == 2)
        // Literal: `$1` entra como está.
        let literal = try ConsultaDeTexto(texto: "a").trocar(em: "a", por: "$1")
        #expect(literal.texto == "$1")
    }
}
