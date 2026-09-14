@testable import OdeteCore
import Testing

struct CompleteTests {
    @Test func wordsAndSnippets() {
        let src = "const counter = 1\nconst counterMax = 9\ncou"
        let s = Complete.suggestions(text: src, cursor: src.count, language: .javascript)
        #expect(s.map(\.label) == ["counter", "counterMax"])
        #expect(s[0].kind == .word)
        let s2 = Complete.suggestions(text: "lo", cursor: 2, language: .typescript)
        #expect(s2.first?.kind == .snippet && s2.first?.label == "log" && s2.first?.insert == "console.log($0)")
    }

    @Test func tooShort() {
        #expect(Complete.suggestions(text: "c", cursor: 1, language: .javascript).isEmpty)
        #expect(Complete.suggestions(text: "abc ", cursor: 4, language: .javascript).isEmpty)
    }

    @Test func paths() {
        let files = [
            "src/App.tsx",
            "src/components/Header.tsx",
            "src/components/Footer.tsx",
            "src/main.tsx",
            "package.json",
        ]
        let src = "import H from \"./components/He"
        let s = Complete.suggestions(
            text: src,
            cursor: src.count,
            language: .tsx,
            files: files,
            currentPath: "src/App.tsx"
        )
        #expect(s.map(\.label) == ["Header.tsx"])
        #expect(s[0].insert == "Header" && s[0].kind == .path)
        let src2 = "import x from \"./"
        let s2 = Complete.suggestions(
            text: src2,
            cursor: src2.count,
            language: .tsx,
            files: files,
            currentPath: "src/App.tsx"
        )
        #expect(s2.map(\.label) == ["components/", "main.tsx"])
        let src3 = "import x from \"../"
        let s3 = Complete.suggestions(
            text: src3,
            cursor: src3.count,
            language: .tsx,
            files: files,
            currentPath: "src/App.tsx"
        )
        #expect(s3.map(\.label) == ["src/", "package.json"])
    }

    @Test func contextDetectsPrefixStart() {
        let ctx = Complete.context(text: "foo bar", cursor: 7)
        #expect(ctx?.prefix == "bar" && ctx?.start == 4)
    }
}
