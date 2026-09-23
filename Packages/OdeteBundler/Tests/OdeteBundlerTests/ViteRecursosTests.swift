import Foundation
@testable import OdeteBundler
import Testing

/// `import.meta.glob`, `?raw`, `?url`, `?inline` e `?worker`: o que o Vite acrescenta ao
/// `import` e que o esbuild sozinho não conhece.
@Suite(.serialized) struct ViteRecursosTests {
    func projeto(_ main: String) throws -> URL {
        let raiz = Apoio.raiz("vite-recursos")
        try Apoio.pagina(raiz)
        try Apoio.grava(#"{"name":"app","type":"module"}"#, raiz, "package.json")
        try Apoio.grava(main, raiz, "src/main.ts")
        try Apoio.grava("export default 'A';\nexport const nome = 'a';\n", raiz, "src/paginas/a.ts")
        try Apoio.grava("export default 'B';\nexport const nome = 'b';\n", raiz, "src/paginas/b.ts")
        try Apoio.grava("export default 'X';\n", raiz, "src/paginas/rascunho/x.ts")
        return raiz
    }

    @Test func globAnsiosoEPreguicoso() async throws {
        let raiz = try projeto("""
        const ansioso = import.meta.glob("./paginas/*.ts", { eager: true, import: "default" });
        const todos = import.meta.glob(["./paginas/**/*.ts", "!./paginas/rascunho/**"], { eager: true });
        const preguicoso = import.meta.glob<{ nome: string }>("./paginas/*.ts");
        const g = globalThis as any;
        g.__r = Object.keys(ansioso).join(",") + "|" + Object.values(ansioso).join(",") + "|" +
          Object.values(todos).map((m: any) => m.nome).join(",") + "|" + typeof preguicoso["./paginas/a.ts"];
        preguicoso["./paginas/b.ts"]().then((m) => { g.__r2 = m.nome; });
        """)
        let (r, js, _) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(Apoio.roda(js).valor == "./paginas/a.ts,./paginas/b.ts|A,B|a,b|function")
    }

    /// Padrão da raiz e alias: as chaves saem a partir da raiz (`/src/…`), como no Vite; e
    /// `query` e `import` juntos.
    @Test func globDaRaizComQuery() async throws {
        let raiz = try projeto("""
        const textos = import.meta.glob("/src/textos/*.txt", { query: "?raw", import: "default", eager: true });
        (globalThis as any).__r = Object.entries(textos).map(([k, v]) => k + "=" + v).join(",");
        """)
        try Apoio.grava("um", raiz, "src/textos/1.txt")
        try Apoio.grava("dois", raiz, "src/textos/2.txt")
        let (r, js, _) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(Apoio.roda(js).valor == "/src/textos/1.txt=um,/src/textos/2.txt=dois")
    }

    /// No dev server, um arquivo novo na pasta do glob entra sem mexer em quem importa.
    @Test func globNoDevVeArquivoNovo() async throws {
        let raiz = try projeto("export const paginas = Object.keys(import.meta.glob(\"./paginas/*.ts\"));\n")
        let dev = DevServer(root: raiz)
        try await dev.start(port: Apoio.porta())
        defer { dev.stop() }
        let antes = try await Apoio.texto(dev.url.appending(path: "@odete/js/src/main.ts"))
        #expect(antes.contains("./paginas/a.ts") && !antes.contains("./paginas/c.ts"))
        let pasta = raiz.appending(path: "src/paginas").path
        #expect(await Apoio.ate { dev.arquivosVigiados.contains(raiz.appending(path: "src/main.ts").path) })
        try Apoio.grava("export default 'C';\n", raiz, "src/paginas/c.ts")
        _ = await dev.arquivosMudaram([], criados: [pasta + "/c.ts"])
        let depois = try await Apoio.texto(dev.url.appending(path: "@odete/js/src/main.ts"))
        #expect(depois.contains("./paginas/c.ts"), "\(depois.prefix(600))")
    }

    @Test func rawUrlInline() async throws {
        let raiz = try projeto("""
        import texto from "./leia.md?raw";
        import pequeno from "./p.svg?url";
        import grande from "./g.bin?url";
        import folha from "./f.css?inline";
        (globalThis as any).__r = [texto, pequeno.slice(0, 5), grande, folha.includes("color")].join("|");
        """)
        try Apoio.grava("# Olá\n", raiz, "src/leia.md")
        try Apoio.grava("<svg xmlns=\"http://www.w3.org/2000/svg\"/>", raiz, "src/p.svg")
        try Data(repeating: 7, count: 9000).write(to: raiz.appending(path: "src/g.bin"))
        try Apoio.grava(".x { color: red }\n", raiz, "src/f.css")
        let (r, js, css) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        let v = Apoio.roda(js).valor ?? ""
        let partes = v.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        #expect(partes.count == 4, "\(v)")
        #expect(partes.first == "# Olá\n")
        #expect(partes.dropFirst().first == "data:")
        // O grande sai como arquivo com hash, gravado em dist/.
        let grande = partes.count > 2 ? partes[2] : ""
        #expect(grande.hasPrefix("/assets/g-") && grande.hasSuffix(".bin"), "\(grande)")
        #expect(FileManager.default.fileExists(atPath: raiz.appending(path: "dist" + grande).path))
        #expect(partes.last == "true")
        // O `?inline` não entra na folha da página.
        #expect(!css.contains("color"))
    }

    /// No dev server o `?url` é o endereço do arquivo no próprio servidor.
    @Test func urlNoDev() async throws {
        let raiz = try projeto("import u from \"./p.svg?url\";\nexport const endereco = u;\n")
        try Apoio.grava("<svg xmlns=\"http://www.w3.org/2000/svg\"/>", raiz, "src/p.svg")
        let dev = DevServer(root: raiz)
        try await dev.start(port: Apoio.porta())
        defer { dev.stop() }
        let js = try await Apoio.texto(dev.url.appending(path: "@odete/js/src/main.ts"))
        #expect(js.contains("\"/src/p.svg\""), "\(js.prefix(400))")
        let svg = try await Apoio.texto(dev.url.appending(path: "src/p.svg"))
        #expect(svg.contains("<svg"))
    }

    /// `?worker`: um construtor de Worker com o código do worker empacotado dentro.
    @Test func worker() async throws {
        let raiz = try projeto("""
        import Trabalhador from "./trabalho.ts?worker";
        (globalThis as any).__r = typeof Trabalhador;
        """)
        try Apoio.grava("import { dobro } from './conta';\nself.onmessage = (e) => postMessage(dobro(e.data));\n", raiz, "src/trabalho.ts")
        try Apoio.grava("export const dobro = (n: number) => n * 2 + 1000;\n", raiz, "src/conta.ts")
        let (r, js, _) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(Apoio.roda(js).valor == "function")
        #expect(js.contains("new Worker") && js.contains("1e3"), "\(js.prefix(800))")
    }
}
