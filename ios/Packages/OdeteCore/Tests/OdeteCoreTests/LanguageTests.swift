import Testing
@testable import OdeteCore

@Suite struct LanguageTests {
    @Test(arguments: [
        ("src/App.tsx", Language.tsx), ("a.ts", .typescript), ("a.js", .javascript), ("a.jsx", .jsx),
        ("index.html", .html), ("style.css", .css), ("package.json", .json), ("README.md", .markdown),
        ("Sources/App.swift", .swift), ("ci.yml", .yaml), ("Makefile", .plain), (".env", .plain), ("x.unknown", .plain),
    ])
    func detect(path: String, expected: Language) {
        #expect(Language.detect(path: path) == expected)
    }
}
