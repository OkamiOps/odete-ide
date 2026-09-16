import Foundation
@testable import OdeteBundler
import OdeteRuntime
import Synchronization
import Testing

func tmpProject() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appending(
        path: "odete-bundle-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: u.appending(path: "src"), withIntermediateDirectories: true)
    try "export const soma = (a: number, b: number): number => a + b;".write(
        to: u.appending(path: "src/soma.ts"),
        atomically: true,
        encoding: .utf8
    )
    try "import { soma } from './soma'; import './style.css'; export const App = () => <h1>{soma(40, 2)}</h1>; document.body.innerHTML = String(soma(1, 2));"
        .write(
            to: u.appending(path: "src/main.tsx"),
            atomically: true,
            encoding: .utf8
        )
    try "body { color: red }".write(to: u.appending(path: "src/style.css"), atomically: true, encoding: .utf8)
    try "<!doctype html><html><head></head><body><div id=root></div><script type=\"module\" src=\"/src/main.tsx\"></script></body></html>"
        .write(
            to: u.appending(path: "index.html"),
            atomically: true,
            encoding: .utf8
        )
    // react falso só para o runtime JSX resolver
    let react = u.appending(path: "node_modules/react")
    try FileManager.default.createDirectory(at: react, withIntermediateDirectories: true)
    try #"{"name":"react","version":"19.0.0","main":"index.js","exports":{".":"./index.js","./jsx-dev-runtime":"./jsx-dev-runtime.js","./jsx-runtime":"./jsx-runtime.js"}}"#
        .write(
            to: react.appending(path: "package.json"),
            atomically: true,
            encoding: .utf8
        )
    try "module.exports = { createElement: (t, p, ...c) => ({ t, p, c }) };".write(
        to: react.appending(path: "index.js"),
        atomically: true,
        encoding: .utf8
    )
    try "exports.jsxDEV = (t, p) => ({ t, p }); exports.Fragment = 'f';".write(
        to: react.appending(path: "jsx-dev-runtime.js"),
        atomically: true,
        encoding: .utf8
    )
    try "exports.jsx = (t, p) => ({ t, p }); exports.jsxs = exports.jsx; exports.Fragment = 'f';".write(
        to: react.appending(path: "jsx-runtime.js"),
        atomically: true,
        encoding: .utf8
    )
    return u
}

@Suite(.serialized) struct BundlerTests {
    @Test func loadsAndTransforms() async throws {
        let root = try tmpProject()
        let es = Esbuild(root: root) { _, t in print("[js]", t) }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(60)); if !Task
                .isCancelled
            {
                print("[watchdog] estourou"); es.engine.stop()
            }
        }
        defer { watchdog.cancel() }
        let v = try await es.ready()
        #expect(v == Esbuild.version)
        let out = try await es.transform(
            "const x: number = 1; export default x;",
            loader: "ts",
            options: ["format": "cjs"]
        )
        #expect(out.contains("module.exports") && !out.contains(": number"))
        let cjs = try es.transformCJSSync(
            "import a from './a'; export const b = a + 1;",
            file: root.appending(path: "src/x.ts").path
        )
        #expect(cjs.contains("require(\"./a\")"))
    }

    @Test func buildsProjectWithCss() async throws {
        let root = try tmpProject()
        let es = Esbuild(root: root)
        let r = try await es.build(entries: ["src/main.tsx"])
        #expect(r.ok, "\(r.diagnostics)")
        let js = r.files.first { $0.path.hasSuffix(".js") }
        let css = r.files.first { $0.path.hasSuffix(".css") }
        #expect(js?.text.contains("soma") == true && js?.text.contains("jsxDEV") == true)
        #expect(css?.text.contains("color: red") == true)
        let bad = try await es.build(entries: ["src/nao-existe.tsx"])
        #expect(!bad.ok && bad.diagnostics.first?.kind == .error)
    }

    @Test func runtimeRequiresTypeScriptViaEsbuild() async throws {
        let root = try tmpProject()
        let es = Esbuild(root: root)
        _ = try await es.ready()
        let out = Mutex<String>("")
        let p = JSProcess(cwd: root, output: { _, t in out.withLock { $0 += t } })
        p.setTransform(es.cjsTransform)
        try "import { soma } from './src/soma'; console.log('ts ok', soma(2, 3));".write(
            to: root.appending(path: "run.ts"),
            atomically: true,
            encoding: .utf8
        )
        let code = await p.run(file: root.appending(path: "run.ts"))
        #expect(code == 0 && out.withLock { $0 } == "ts ok 5", Comment(rawValue: out.withLock { $0 }))
    }

    @Test func devServerServesHtmlBundleAndCss() async throws {
        let root = try tmpProject()
        let dev = DevServer(root: root)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000)) // porta livre: o app pode estar na 5173
        defer { dev.stop() }
        let (h, _) = try await URLSession.shared.data(from: dev.url)
        let html = String(decoding: h, as: UTF8.self)
        #expect(html.contains("/@odete/js/src/main.tsx") && html.contains("/@odete/css/src/main.tsx") && html
            .contains("WebSocket"))
        let (j, jr) = try await URLSession.shared.data(from: dev.url.appending(path: "@odete/js/src/main.tsx"))
        #expect((jr as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-type")?.contains("javascript") == true)
        #expect(String(decoding: j, as: UTF8.self).contains("soma"))
        let (c, _) = try await URLSession.shared.data(from: dev.url.appending(path: "@odete/css/src/main.tsx"))
        #expect(String(decoding: c, as: UTF8.self).contains("color: red"))
        let (nf, nfr) = try await URLSession.shared.data(from: dev.url.appending(path: "nada.png"))
        #expect((nfr as? HTTPURLResponse)?.statusCode == 404 && !nf.isEmpty)
        // erro de build vira overlay, não 500
        try "import x from './nao'; x();".write(
            to: root.appending(path: "src/main.tsx"),
            atomically: true,
            encoding: .utf8
        )
        await dev.invalidateNow()
        let (e, _) = try await URLSession.shared.data(from: dev.url.appending(path: "@odete/js/src/main.tsx"))
        #expect(String(decoding: e, as: UTF8.self).contains("Não achei"))
        let d = await dev.diagnostics()
        #expect(d.first?.kind == .error)
    }
}

/// Um projeto Astro precisa aparecer no Preview.
///
/// A rota vem de `src/pages`, e um projeto Astro não tem `index.html` na raiz — o
/// servidor caía direto no 404 e o Preview ficava com "não encontrado: /" em todo
/// projeto criado pelo modelo Astro do próprio Hub.
struct AstroTests {
    func projetoAstro() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(
            path: "odete-astro-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        let fm = FileManager.default
        try fm.createDirectory(at: u.appending(path: "src/pages"), withIntermediateDirectories: true)
        try fm.createDirectory(at: u.appending(path: "src/components"), withIntermediateDirectories: true)
        try fm.createDirectory(at: u.appending(path: "src/layouts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: u.appending(path: "public"), withIntermediateDirectories: true)
        try #"{"name":"lp","dependencies":{"astro":"^5.0.0"}}"#
            .write(to: u.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try """
        ---
        const { title } = Astro.props;
        ---
        <html lang="pt-BR"><head><title>{title}</title>
        <style>body { color: #111; } @media (min-width: 40rem) { main { padding: 2rem } }</style>
        </head><body><slot /></body></html>
        """.write(to: u.appending(path: "src/layouts/Base.astro"), atomically: true, encoding: .utf8)
        try """
        ---
        const { nome } = Astro.props;
        ---
        <span class="tag">{nome}</span>
        """.write(to: u.appending(path: "src/components/Tag.astro"), atomically: true, encoding: .utf8)
        try """
        ---
        import Base from "../layouts/Base.astro";
        import Tag from "../components/Tag.astro";
        const titulo = "Odete LP";
        const itens = ["um", "dois"];
        ---
        <Base title={titulo}>
          <main>
            <h1>{titulo}</h1>
            <Tag nome="novo" />
            <ul>{itens.map((i) => <li>{i}</li>)}</ul>
          </main>
        </Base>
        """.write(to: u.appending(path: "src/pages/index.astro"), atomically: true, encoding: .utf8)
        try "<p>sobre</p>".write(to: u.appending(path: "src/pages/sobre.astro"), atomically: true, encoding: .utf8)
        return u
    }

    @Test func serveAPaginaDoAstroComLayoutEComponente() async throws {
        let root = try projetoAstro()
        let dev = DevServer(root: root)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .astro)
        defer { dev.stop() }

        let (d, r) = try await URLSession.shared.data(from: dev.url)
        #expect((r as? HTTPURLResponse)?.statusCode == 200)
        let html = String(decoding: d, as: UTF8.self)
        #expect(html.contains("<title>Odete LP</title>"), "o layout não renderizou")
        #expect(html.contains("<h1>Odete LP</h1>"), "o slot não entrou")
        #expect(html.contains(#"<span class="tag">novo</span>"#), "o componente não renderizou")
        #expect(html.contains("<li>um</li><li>dois</li>"), "a lista não renderizou")
        // o CSS tem chaves e não pode ter sido tratado como expressão
        #expect(html.contains("body { color: #111; }"))
        #expect(html.contains("@media (min-width: 40rem)"))
        // o reload continua sendo injetado
        #expect(html.contains("WebSocket"))
    }

    @Test func rotaPorNomeDeArquivo() async throws {
        let root = try projetoAstro()
        let dev = DevServer(root: root)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .astro)
        defer { dev.stop() }
        let (d, r) = try await URLSession.shared.data(from: dev.url.appending(path: "sobre"))
        #expect((r as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: d, as: UTF8.self).contains("<p>sobre</p>"))
    }

    @Test func rotaQueNaoExisteExplicaOQueProcurou() async throws {
        let root = try projetoAstro()
        let dev = DevServer(root: root)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .astro)
        defer { dev.stop() }
        let (d, r) = try await URLSession.shared.data(from: dev.url.appending(path: "nao-existe"))
        #expect((r as? HTTPURLResponse)?.statusCode == 404)
        #expect(String(decoding: d, as: UTF8.self).contains("src/pages"))
    }

    /// Os cantos do compilador, na página inteira e pelo caminho de verdade.
    ///
    /// Em JS puro dá para enganar o compilador com um componente escrito à mão; aqui
    /// tudo passa por `.astro` compilado, que foi como apareceu que o `<slot />` estava
    /// escapando o HTML do layout.
    @Test func cantosDoCompilador() async throws {
        let root = try projetoAstro()
        try """
        ---
        const xs = ["a", "b"];
        const crus = ["<b>x</b>"];
        const n = 3;
        const alvo = "/ir";
        ---
        <html><head>
        <style>.a { color: #111; } @media (min-width: 40rem) { .b { gap: 1px } }</style>
        <script>const o = {a: 1}; if (o) { console.log(1); }</script>
        </head><body>
        <ul id="jsx">{xs.map((x) => <li>{x}</li>)}</ul>
        <ul id="texto">{crus.map((x) => <li>{x}</li>)}</ul>
        <p id="cmp">{n < 5 ? "menor" : "maior"}</p>
        <p id="frag">{n ? <><b>s</b><i>n</i></> : null}</p>
        <a id="attr" href={alvo} data-x={n > 2}>ir</a>
        <p id="falso">{null}{false}{undefined}</p>
        <p id="crase">use `x` aqui</p>
        </body></html>
        """.write(to: root.appending(path: "src/pages/cantos.astro"), atomically: true, encoding: .utf8)

        let dev = DevServer(root: root)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .astro)
        defer { dev.stop() }
        let (d, _) = try await URLSession.shared.data(from: dev.url.appending(path: "cantos"))
        let html = String(decoding: d, as: UTF8.self)

        // JSX é marcação e renderiza; o conteúdo dentro dele continua sendo escapado
        #expect(html.contains("<ul id=\"jsx\"><li>a</li><li>b</li></ul>"))
        #expect(html.contains("<li>&lt;b&gt;x&lt;/b&gt;</li>"))
        // `<` entre valores é comparação, não início de elemento
        #expect(html.contains("<p id=\"cmp\">menor</p>"))
        #expect(html.contains("<p id=\"frag\"><b>s</b><i>n</i></p>"))
        #expect(html.contains("<a id=\"attr\" href=\"/ir\" data-x>ir</a>"))
        // nulo, falso e indefinido não viram texto
        #expect(html.contains("<p id=\"falso\"></p>"))
        #expect(html.contains("<p id=\"crase\">use `x` aqui</p>"))
        // chaves de CSS e de JS do navegador continuam intactas
        #expect(html.contains(".a { color: #111; }"))
        #expect(html.contains("@media (min-width: 40rem) { .b { gap: 1px } }"))
        #expect(html.contains("const o = {a: 1}; if (o) { console.log(1); }"))
    }

    /// Editar um componente tem que refletir sem reiniciar o servidor.
    @Test func editarComponenteReflete() async throws {
        let root = try projetoAstro()
        let dev = DevServer(root: root)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .astro)
        defer { dev.stop() }
        _ = try await URLSession.shared.data(from: dev.url)
        try """
        ---
        const { nome } = Astro.props;
        ---
        <b class="tag">{nome}!</b>
        """.write(to: root.appending(path: "src/components/Tag.astro"), atomically: true, encoding: .utf8)
        let (d, _) = try await URLSession.shared.data(from: dev.url)
        #expect(String(decoding: d, as: UTF8.self).contains(#"<b class="tag">novo!</b>"#))
    }
}
