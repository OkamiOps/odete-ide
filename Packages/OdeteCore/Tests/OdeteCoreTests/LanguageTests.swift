@testable import OdeteCore
import Testing

struct LanguageTests {
    @Test(arguments: [
        ("src/App.tsx", Language.tsx), ("a.ts", .typescript), ("a.js", .javascript), ("a.jsx", .jsx),
        ("index.html", .html), ("style.css", .css), ("package.json", .json), ("README.md", .markdown),
        ("Sources/App.swift", .swift),
        ("ci.yml", .yaml), // Makefile: a receita de um alvo é shell de verdade, linha a linha. Colorir como
        // shell acerta o comentário e o corpo; deixar em branco não acerta nada.
        ("Makefile", .bash), (".env", .plain), ("x.unknown", .plain), (".gitignore", .plain),
    ])
    func detect(path: String, expected: Language) {
        #expect(Language.detect(path: path) == expected)
    }
}
