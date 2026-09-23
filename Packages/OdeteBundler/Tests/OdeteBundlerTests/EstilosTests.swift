import Foundation
@testable import OdeteBundler
import Testing

/// CSS Modules, Sass e Less. Antes `import s from "./a.module.css"` era `{}` calado e um
/// `.scss` virava uma string em data URL — sem erro e sem estilo.
///
/// Os testes com o Sass e o Less de verdade copiam os pacotes de um `node_modules` do Mac:
/// `TEST_RUNNER_ODETE_ESTILOS_DIR=<node_modules com sass, immutable e less>`.
@Suite(.serialized) struct EstilosTests {
    static let temPacotes = ProcessInfo.processInfo.environment["ODETE_ESTILOS_DIR"].map { !$0.isEmpty } ?? false

    func projeto(_ main: String) throws -> URL {
        let raiz = Apoio.raiz("estilos")
        try Apoio.pagina(raiz)
        try Apoio.grava(#"{"name":"app","type":"module"}"#, raiz, "package.json")
        try Apoio.grava(main, raiz, "src/main.ts")
        return raiz
    }

    @Test func cssModulesDevolveOMapaDasClasses() async throws {
        let raiz =
            try projeto(
                "import s from \"./a.module.css\";\n(globalThis as any).__r = s.titulo + \"|\" + s[\"com-traco\"];\n"
            )
        try Apoio.grava(
            ".titulo { color: red }\n.com-traco { color: blue }\n:global(.solta) { margin: 0 }\n",
            raiz,
            "src/a.module.css"
        )
        let (r, js, css) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        let v = Apoio.roda(js).valor ?? ""
        let nomes = v.split(separator: "|").map(String.init)
        #expect(nomes.count == 2 && !nomes.contains("undefined"), "\(v)")
        // O nome que o JS recebe é o que está no CSS; `:global` fica como escrito.
        #expect(nomes.allSatisfy { css.contains("." + $0) }, "\(css)")
        #expect(css.contains(".solta"))
    }

    @Test func scssSemOPacoteSassDizComoInstalar() async throws {
        let raiz = try projeto("import \"./app.scss\";\n")
        try Apoio.grava("$cor: red;\n.a { color: $cor; }\n", raiz, "src/app.scss")
        let r = try await ViteBuild.rodar(raiz: raiz, esbuild: Esbuild(root: raiz))
        #expect(!r.ok)
        let texto = r.diagnosticos.map(\.text).joined(separator: "\n")
        #expect(texto.contains("npm i -D sass"), "\(texto)")
    }

    @Test func lessSemOPacoteLessDizComoInstalar() async throws {
        let raiz = try projeto("import \"./app.less\";\n")
        try Apoio.grava("@cor: red;\n.a { color: @cor; }\n", raiz, "src/app.less")
        let r = try await ViteBuild.rodar(raiz: raiz, esbuild: Esbuild(root: raiz))
        #expect(!r.ok)
        #expect(r.diagnosticos.map(\.text).joined().contains("npm i -D less"))
    }

    /// `@import` de CSS de um pacote que está no package.json mas não foi instalado: no dev
    /// server o JS desse pacote vai pelo esm.sh, mas o CSS não tem para onde ir — antes
    /// chegava cru ao navegador e a folha sumia calada.
    @Test func importDeCSSDePacoteQueFaltaDizQueFalta() async throws {
        let raiz = try projeto("import \"./app.css\";\nconsole.log(1);\n")
        try Apoio.grava(
            #"{"name":"app","type":"module","dependencies":{"estilos-que-faltam":"^1.0.0"}}"#,
            raiz,
            "package.json"
        )
        try Apoio.grava("@import \"estilos-que-faltam/base.css\";\n.a { color: red }\n", raiz, "src/app.css")
        let dev = DevServer(root: raiz)
        try await dev.start(port: Apoio.porta())
        defer { dev.stop() }
        let css = try await Apoio.texto(dev.url.appending(path: "@odete/css/src/main.ts"))
        #expect(!css.contains("@import \"estilos-que-faltam"), "\(css)")
        let erros = await dev.diagnostics().filter { $0.kind == .error }.map(\.text)
        #expect(erros.contains { $0.contains("estilos-que-faltam") && $0.contains("npm install") }, "\(erros)")
    }

    /// O Sass de verdade (o dart-sass em JS): `@use` de parcial, aninhamento, variável, e
    /// o `.module.scss`.
    @Test(.enabled(if: temPacotes)) func sassDeVerdade() async throws {
        let raiz =
            try projeto(
                "import \"./app.scss\";\nimport s from \"./b.module.scss\";\n(globalThis as any).__r = s.caixa;\n"
            )
        #expect(try Apoio.copiaPacotes("ODETE_ESTILOS_DIR", ["sass", "immutable"], para: raiz))
        try Apoio.grava("$cor: #ff0000;\n", raiz, "src/_vars.scss")
        try Apoio.grava("@use \"./vars\" as v;\n.a { .b { color: v.$cor; } }\n", raiz, "src/app.scss")
        try Apoio.grava(".caixa { padding: 1px + 2px; }\n", raiz, "src/b.module.scss")
        let inicio = ContinuousClock.now
        let (r, js, css) = try await Apoio.viteBuild(raiz)
        print("[medida] vite build com sass: \(ContinuousClock.now - inicio)")
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(css.contains(".a .b") && (css.contains("red") || css.contains("#f00")), "\(css)")
        #expect(css.contains("3px"))
        #expect(Apoio.roda(js).valor.map { !$0.isEmpty && $0 != "undefined" } == true)
    }

    /// Erro de Sass aponta arquivo e linha.
    @Test(.enabled(if: temPacotes)) func erroDeSassComLugar() async throws {
        let raiz = try projeto("import \"./app.scss\";\n")
        #expect(try Apoio.copiaPacotes("ODETE_ESTILOS_DIR", ["sass", "immutable"], para: raiz))
        try Apoio.grava(".a {\n  color: $nao-existe;\n}\n", raiz, "src/app.scss")
        let r = try await ViteBuild.rodar(raiz: raiz, esbuild: Esbuild(root: raiz))
        #expect(!r.ok)
        let d = r.diagnosticos.first { $0.kind == .error }
        #expect(d?.text.contains("Undefined variable") == true, "\(r.diagnosticos)")
        #expect(d?.file == "src/app.scss" && d?.line == 2, "\(String(describing: d))")
    }

    @Test(.enabled(if: temPacotes)) func lessDeVerdade() async throws {
        let raiz = try projeto("import \"./app.less\";\n")
        #expect(try Apoio.copiaPacotes("ODETE_ESTILOS_DIR", ["less"], para: raiz))
        try Apoio.grava("@cor: #00ff00;\n", raiz, "src/vars.less")
        try Apoio.grava("@import \"./vars.less\";\n.a { .b { color: @cor; } }\n", raiz, "src/app.less")
        let (r, _, css) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(
            css.contains(".a .b") && (css.contains("#0f0") || css.contains("lime") || css.contains("#00ff00")),
            "\(css)"
        )
    }

    /// No dev server: mexer no parcial que o `.scss` usa refaz só a folha — o parcial não
    /// passa pelo esbuild, e mesmo assim é vigiado.
    @Test(.enabled(if: temPacotes)) func parcialDoSassEVigiadoNoDev() async throws {
        let raiz = try projeto("import \"./app.scss\";\nconsole.log(1);\n")
        #expect(try Apoio.copiaPacotes("ODETE_ESTILOS_DIR", ["sass", "immutable"], para: raiz))
        try Apoio.grava("$cor: red;\n", raiz, "src/_vars.scss")
        try Apoio.grava("@use \"./vars\" as v;\n.a { color: v.$cor; }\n", raiz, "src/app.scss")
        let dev = DevServer(root: raiz)
        try await dev.start(port: Apoio.porta())
        defer { dev.stop() }
        let css = try await Apoio.texto(dev.url.appending(path: "@odete/css/src/main.ts"))
        #expect(css.contains("color: red"), "\(css)")
        let parcial = raiz.appending(path: "src/_vars.scss").path
        #expect(await Apoio.ate { dev.arquivosVigiados.contains(parcial) }, "\(dev.arquivosVigiados)")
        try Apoio.grava("$cor: blue;\n", raiz, "src/_vars.scss")
        // Quem percebe é o observador: a folha troca, a página não recarrega.
        let trocou = await Apoio.ate { await dev.estatisticas()["css"] == 1 }
        let estatisticas = await dev.estatisticas()
        #expect(trocou, "\(estatisticas)")
        #expect(await dev.estatisticas()["reload"] == 0)
        let depois = try await Apoio.texto(dev.url.appending(path: "@odete/css/src/main.ts"))
        #expect(depois.contains("color: blue"), "\(depois)")
    }
}
