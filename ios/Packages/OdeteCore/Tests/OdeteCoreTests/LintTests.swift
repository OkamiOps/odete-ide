@testable import OdeteCore
import Testing

struct LintTests {
    @Test func jsRules() {
        let src = "var a = 1\nif (a == null) debugger\nconsole.log('x == y')\n// var inside comment\nconst s = \"debugger\"\n"
        let issues = Lint.rules(text: src, language: .javascript)
        #expect(issues.map(\.rule) == ["no-var", "eqeqeq", "no-debugger", "no-console"])
        #expect(issues[1].line == 2 && issues[1].column == 7 && issues[1].length == 2)
        #expect(issues[2].severity == .warning)
    }

    @Test func jsonError() {
        let issues = Lint.rules(text: "{\n  \"a\": 1,\n  \"b\": \n}\n", language: .json)
        #expect(issues.count == 1 && issues[0].severity == .error && issues[0].line >= 3)
        #expect(Lint.rules(text: "{\"a\": [1, 2]}", language: .json).isEmpty)
    }

    @Test func cssBraces() {
        let issues = Lint.rules(text: ".a {\n  color: red !important;\n", language: .css)
        #expect(issues.map(\.rule) == ["no-important", "css-brace"])
    }

    @Test func swiftRules() {
        let issues = Lint.rules(text: "let x = try! foo()\nprint(x) // TODO: remover\n", language: .swift)
        #expect(issues.map(\.rule) == ["no-force-try", "no-print", "todo"])
    }

    @Test func arquivoGrandeNaoEVarrido() {
        let grande = String(repeating: "var x = 1\n", count: 60000)
        #expect(grande.utf8.count > Limites.arquivoGrande)
        #expect(Lint.rules(text: grande, language: .javascript).isEmpty)
        // JSON passa mesmo grande: uma análise só, e um erro é o que se quer ver num
        // `package-lock.json` que alguém quebrou.
        let json = "[" + String(repeating: "1,", count: 250_000) + "1"
        #expect(Lint.rules(text: json, language: .json).count == 1)
    }

    @Test func avisoDemaisVemCortadoComOTotal() {
        let issues = Lint.rules(text: String(repeating: "var x = 1\n", count: 250), language: .javascript)
        #expect(issues.count == Lint.tetoDeAvisos + 1)
        #expect(issues.last?.rule == "teto")
        #expect(issues.last?.message == "mais 150 aviso(s) neste arquivo")
        #expect(issues.last?.line == 101)
    }
}
