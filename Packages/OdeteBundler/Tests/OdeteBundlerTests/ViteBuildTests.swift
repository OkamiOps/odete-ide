import Foundation
import JavaScriptCore
@testable import OdeteBundler
import Testing

/// O `vite build` contra o Vite de verdade: nomes com hash, um bundle por página, a folha
/// ligada no HTML, `import.meta.env` e os `.env` do modo, `%VITE_X%`, `base`, arquivo
/// grande fora do JS (em bytes, sem estragar), `public/` e o `url(/…)` de public/ no CSS.
@Suite(.serialized) struct ViteBuildTests {
    func grava(_ texto: String, _ raiz: URL, _ caminho: String) throws {
        let u = raiz.appending(path: caminho)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try texto.write(to: u, atomically: true, encoding: .utf8)
    }

    func gravaBytes(_ d: Data, _ raiz: URL, _ caminho: String) throws {
        let u = raiz.appending(path: caminho)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: u)
    }

    func novaRaiz() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "odete-vite-build-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    func le(_ raiz: URL, _ caminho: String) throws -> String {
        try String(contentsOf: raiz.appending(path: caminho), encoding: .utf8)
    }

    /// Roda o JS de dist/ (sem DOM) e devolve `globalThis.__r`.
    func roda(_ js: String) -> (valor: String?, erro: String?) {
        let c = JSContext()!
        var erro: String?
        c.exceptionHandler = { _, e in erro = e?.toString() }
        c.evaluateScript(js)
        return (c.evaluateScript("globalThis.__r")?.toString(), erro)
    }

    func build(_ raiz: URL, _ opcoes: ViteBuild.Opcoes = .init()) async throws -> ViteBuild.Resultado {
        let r = try await ViteBuild.rodar(raiz: raiz, esbuild: Esbuild(root: raiz), opcoes: opcoes)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        return r
    }

    /// O `<script src>` e o `<link href>` que o index.html de dist/ aponta.
    func referencias(_ html: String) -> (js: [String], css: [String]) {
        (
            html.matches(of: /<script type="module" crossorigin src="([^"]+)"><\/script>/).map { String($0.1) },
            html.matches(of: /<link rel="stylesheet" crossorigin href="([^"]+)">/).map { String($0.1) }
        )
    }

    // MARK: - Página

    /// Dois scripts e uma folha ligada no HTML viram um JS e um CSS com hash, no <head>.
    /// Antes: um `<link>` por script apontando para um CSS que só um deles gerou, e a folha
    /// ligada continuava em `/src/base.css`, que não existe em dist/.
    @Test func umBundlePorPaginaComHashNoNome() async throws {
        let raiz = novaRaiz()
        try grava("""
        <!doctype html><html><head><title>t</title>
        <link rel="stylesheet" href="/src/base.css">
        <link rel="stylesheet" href="https://fonts.example.com/x.css">
        </head><body><div id="root"></div>
        <script type="module" src="/src/a.ts"></script>
        <script type="module" src="./src/b.ts"></script>
        </body></html>
        """, raiz, "index.html")
        try grava(".base { color: red }\n", raiz, "src/base.css")
        try grava(".a { color: blue }\n", raiz, "src/a.css")
        try grava(
            "import './a.css';\n(globalThis as any).__r = ((globalThis as any).__r || '') + 'a';\n",
            raiz,
            "src/a.ts"
        )
        try grava("(globalThis as any).__r = ((globalThis as any).__r || '') + 'b';\n", raiz, "src/b.ts")
        let r = try await build(raiz)
        let html = try le(raiz, "dist/index.html")
        let ref = referencias(html)
        #expect(ref.js.count == 1 && ref.css.count == 1, "\(html)")
        let js = try #require(ref.js.first), css = try #require(ref.css.first)
        #expect(js.wholeMatch(of: /\/assets\/index-[A-Z0-9]{8}\.js/) != nil, "\(js)")
        #expect(css.wholeMatch(of: /\/assets\/index-[A-Z0-9]{8}\.css/) != nil, "\(css)")
        // No <head>, e nada apontando para o código-fonte.
        #expect(try #require(html.range(of: js)?.lowerBound) < html.range(of: "</head>")!.lowerBound)
        #expect(!html.contains("/src/"), "\(html)")
        #expect(html.contains("https://fonts.example.com/x.css"), "folha de fora não pode sumir")
        // Os dois scripts, na ordem; a folha ligada antes da importada.
        #expect(try roda(le(raiz, "dist" + js)).valor == "ab")
        let folha = try le(raiz, "dist" + css)
        let base = try #require(folha.range(of: ".base{")), a = try #require(folha.range(of: ".a{"))
        #expect(base.lowerBound < a.lowerBound, "\(folha)")
        #expect(r.gravados.first?.caminho == "dist/index.html")
        #expect(Set(r.gravados.map(\.caminho)) == ["dist/index.html", "dist" + js, "dist" + css])
    }

    /// Sem CSS nenhum, nenhum `<link>` para um arquivo que não existe.
    @Test func semCSSSemLink() async throws {
        let raiz = novaRaiz()
        try grava(
            "<html><head></head><body><script type=\"module\" src=\"/src/main.ts\"></script></body></html>",
            raiz,
            "index.html"
        )
        try grava("(globalThis as any).__r = 'ok';\n", raiz, "src/main.ts")
        _ = try await build(raiz)
        let ref = try referencias(le(raiz, "dist/index.html"))
        #expect(ref.js.count == 1 && ref.css.isEmpty)
        let nomes = try FileManager.default.contentsOfDirectory(atPath: raiz.appending(path: "dist/assets").path)
        #expect(nomes.count == 1 && nomes[0].hasSuffix(".js"), "\(nomes)")
    }

    // MARK: - Ambiente

    func projetoComEnv() throws -> URL {
        let raiz = novaRaiz()
        try grava(
            "<html><head><title>%VITE_TITULO% (%MODE%)</title></head><body style=\"width:100%\">50%<script type=\"module\" src=\"/src/main.ts\"></script></body></html>",
            raiz, "index.html"
        )
        try grava("""
        const e = import.meta.env;
        (globalThis as any).__r = [e.MODE, e.PROD, e.DEV, e.BASE_URL, e.SSR, e.VITE_A, e.VITE_B, e.VITE_C, e.VITE_D,
          import.meta.env.VITE_NAO_EXISTE ?? "padrao", e.VITE_COMENTARIO, e.VITE_EXPANDE, e.VITE_ASPAS,
          typeof e.SEGREDO, process.env.NODE_ENV].join("|");
        """, raiz, "src/main.ts")
        // A ordem do Vite: .env < .env.local < .env.<modo> < .env.<modo>.local.
        try grava("""
        VITE_A=env
        VITE_B=env
        VITE_C=env
        VITE_D=env
        SEGREDO=nao-sai
        HOST=exemplo.com
        export VITE_COMENTARIO=valor # comentário
        VITE_EXPANDE=https://${HOST}/api
        VITE_ASPAS="com # dentro"
        """, raiz, ".env")
        try grava("VITE_B=local\nVITE_C=local\nVITE_D=local\n", raiz, ".env.local")
        try grava("VITE_C=producao\nVITE_D=producao\nVITE_TITULO=Loja\n", raiz, ".env.production")
        try grava("VITE_D=producao-local\n", raiz, ".env.production.local")
        try grava("VITE_A=dev\nVITE_B=dev\nVITE_C=dev\nVITE_D=dev\n", raiz, ".env.development")
        try grava("VITE_C=homolog\nVITE_TITULO=Homolog\n", raiz, ".env.staging")
        return raiz
    }

    func valorDoBuild(_ raiz: URL) throws -> String? {
        let js = try #require(try referencias(le(raiz, "dist/index.html")).js.first)
        let r = try roda(le(raiz, "dist" + js))
        #expect(r.erro == nil, "\(r.erro ?? "")")
        return r.valor
    }

    @Test func importMetaEnvEOsEnvDoModo() async throws {
        let raiz = try projetoComEnv()
        _ = try await build(raiz)
        #expect(try valorDoBuild(raiz) ==
            "production|true|false|/|false|env|local|producao|producao-local|padrao|valor|https://exemplo.com/api|com # dentro|undefined|production")
        let html = try le(raiz, "dist/index.html")
        #expect(html.contains("<title>Loja (production)</title>") && html.contains("width:100%\">50%"), "\(html)")
        let js = try #require(referencias(html).js.first)
        #expect(try !le(raiz, "dist" + js).contains("nao-sai"), "variável sem VITE_ foi parar no bundle")

        // `--mode staging`: os .env do modo, e o build continua de produção.
        _ = try await build(raiz, .init(modo: "staging"))
        #expect(try valorDoBuild(raiz) ==
            "staging|true|false|/|false|env|local|homolog|local|padrao|valor|https://exemplo.com/api|com # dentro|undefined|production")
        #expect(try le(raiz, "dist/index.html").contains("<title>Homolog (staging)</title>"))
    }

    /// O dev server continua com os `.env.development*`, e com o `import.meta.env` inteiro.
    @Test func devServerUsaOsEnvDeDesenvolvimento() async throws {
        let raiz = try projetoComEnv()
        try grava("VITE_D=dev-local\n", raiz, ".env.development.local")
        let dev = DevServer(esbuild: Esbuild(root: raiz))
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000))
        defer { dev.stop() }
        let (d, _) = try await URLSession.shared.data(from: dev.url.appending(path: "@odete/js/src/main.ts"))
        let r = roda(String(decoding: d, as: UTF8.self).replacingOccurrences(
            of: "import \"/@odete/deps.js\";",
            with: ""
        ))
        #expect(r.erro == nil, "\(r.erro ?? "")")
        #expect(r.valor ==
            "development|false|true|/|false|dev|dev|dev|dev-local|padrao|valor|https://exemplo.com/api|com # dentro|undefined|development")
        let (h, _) = try await URLSession.shared.data(from: dev.url)
        #expect(
            String(decoding: h, as: UTF8.self).contains("<title>%VITE_TITULO% (development)</title>"),
            "o título do dev não tem VITE_TITULO em .env.development: fica como está"
        )
    }

    // MARK: - base

    @Test func baseDoViteConfigEmTudo() async throws {
        let raiz = novaRaiz()
        try grava("""
        import { defineConfig } from "vite";
        // base: "/errado/",
        export default defineConfig({
          plugins: [],
          base: "/repo",
          server: { proxy: { "/api": "http://localhost:3000" } },
        });
        """, raiz, "vite.config.ts")
        try grava(
            "<html><head><link rel=\"icon\" href=\"/icone.svg\"></head><body><script type=\"module\" src=\"/src/main.ts\"></script></body></html>",
            raiz, "index.html"
        )
        try grava("<svg xmlns=\"http://www.w3.org/2000/svg\"/>", raiz, "public/icone.svg")
        try gravaBytes(Data(repeating: 0xFF, count: 10), raiz, "public/fundo.png")
        try gravaBytes(
            Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data((0 ..< 6000).map { UInt8($0 % 256) }),
            raiz,
            "src/foto.png"
        )
        try grava(".f { background: url(./foto.png) } .p { background: url(/fundo.png) }\n", raiz, "src/estilo.css")
        try grava("""
        import "./estilo.css";
        import foto from "./foto.png";
        (globalThis as any).__r = import.meta.env.BASE_URL + "|" + foto;
        """, raiz, "src/main.ts")
        #expect(ViteBuild.configDoVite(raiz).base == "/repo")
        _ = try await build(raiz)
        let html = try le(raiz, "dist/index.html")
        let ref = referencias(html)
        let js = try #require(ref.js.first), css = try #require(ref.css.first)
        #expect(js.hasPrefix("/repo/assets/index-") && css.hasPrefix("/repo/assets/index-"), "\(html)")
        #expect(html.contains("href=\"/repo/icone.svg\""), "\(html)")
        let valor = try #require(try roda(le(raiz, "dist" + js.dropFirst(5))).valor)
        #expect(valor.wholeMatch(of: /\/repo\/\|\/repo\/assets\/foto-[A-Z0-9]{8}\.png/) != nil, "\(valor)")
        // A foto saiu inteira, byte a byte; a folha aponta para ela e para a de public/ com o base.
        let foto = String(valor.split(separator: "|")[1].dropFirst(5))
        #expect(try Data(contentsOf: raiz.appending(path: "dist" + foto)) ==
            Data(contentsOf: raiz.appending(path: "src/foto.png")))
        let folha = try le(raiz, "dist" + css.dropFirst(5))
        #expect(folha.contains("/repo" + foto) && folha.contains("/repo/fundo.png"), "\(folha)")
        #expect(try Data(contentsOf: raiz.appending(path: "dist/fundo.png")) == Data(repeating: 0xFF, count: 10))

        // O `vite preview` serve sob o mesmo base (e na raiz, que é onde o Preview abre).
        let preview = DevServer(esbuild: Esbuild(root: raiz), root: raiz.appending(path: "dist"))
        try await preview.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .plain, base: "/repo/")
        defer { preview.stop() }
        for caminho in [String(js.dropFirst()), String(js.dropFirst(6))] {
            let (d, resposta) = try await URLSession.shared.data(from: preview.url.appending(path: caminho))
            #expect((resposta as? HTTPURLResponse)?.statusCode == 200 && d.count > 0, "\(caminho)")
        }
    }

    /// `base: "./"`: tudo relativo, e o arquivo importado vai embutido (de um arquivo à
    /// parte, o JS e o CSS precisariam de endereços relativos diferentes).
    @Test func baseRelativaEmbuteTudo() async throws {
        let raiz = novaRaiz()
        try grava(
            "<html><head></head><body><script type=\"module\" src=\"/src/main.ts\"></script></body></html>",
            raiz,
            "index.html"
        )
        try gravaBytes(Data(repeating: 7, count: 6000), raiz, "src/foto.png")
        try grava("import foto from './foto.png';\n(globalThis as any).__r = foto.slice(0, 22);\n", raiz, "src/main.ts")
        _ = try await build(raiz, .init(base: "./"))
        let js = try #require(try referencias(le(raiz, "dist/index.html")).js.first)
        #expect(js.hasPrefix("./assets/index-"))
        #expect(try roda(le(raiz, "dist" + js.dropFirst())).valor == "data:image/png;base64,")
    }

    @Test func normalizacaoDoBase() {
        #expect(ViteBuild.normalizaBase("") == "./")
        #expect(ViteBuild.normalizaBase("./") == "./")
        #expect(ViteBuild.normalizaBase("/") == "/")
        #expect(ViteBuild.normalizaBase("/repo") == "/repo/")
        #expect(ViteBuild.normalizaBase("repo/") == "/repo/")
        #expect(ViteBuild.normalizaBase("https://cdn.example.com/app") == "https://cdn.example.com/app/")
    }

    // MARK: - public/ e arquivos

    @Test func publicCopiadaEArquivoPequenoEmbutido() async throws {
        let raiz = novaRaiz()
        try grava(
            "<html><head></head><body><script type=\"module\" src=\"/src/main.ts\"></script></body></html>",
            raiz,
            "index.html"
        )
        try grava("User-agent: *\n", raiz, "public/robots.txt")
        try gravaBytes(Data([0x00, 0xFF, 0xD8, 0x80]), raiz, "public/img/bin.dat")
        try gravaBytes(Data(repeating: 1, count: 100), raiz, "src/icone.png")
        try grava(
            "import icone from './icone.png';\n(globalThis as any).__r = icone.slice(0, 22);\n",
            raiz,
            "src/main.ts"
        )
        _ = try await build(raiz)
        #expect(try le(raiz, "dist/robots.txt") == "User-agent: *\n")
        #expect(try Data(contentsOf: raiz.appending(path: "dist/img/bin.dat")) == Data([0x00, 0xFF, 0xD8, 0x80]))
        #expect(try valorDoBuild(raiz) == "data:image/png;base64,")
        let assets = try FileManager.default.contentsOfDirectory(atPath: raiz.appending(path: "dist/assets").path)
        #expect(assets.count == 1, "o ícone pequeno saiu como arquivo: \(assets)")
    }

    /// `"sideEffects": false`: do barril, só o módulo usado entra. Sem o campo, o módulo
    /// cujo topo faz alguma coisa continua (o esbuild não pode saber se precisa).
    @Test func sideEffectsFalseDoPacoteValeNoBuild() async throws {
        let raiz = novaRaiz()
        try grava(
            "<html><head></head><body><script type=\"module\" src=\"/src/main.ts\"></script></body></html>",
            raiz,
            "index.html"
        )
        for (nome, campo) in [("lib-limpa", #","sideEffects":false"#), ("lib-suja", "")] {
            try grava(
                #"{"name":"\#(nome)","type":"module","main":"index.js"\#(campo)}"#,
                raiz,
                "node_modules/\(nome)/package.json"
            )
            try grava(
                "export { a } from './a.js';\nexport { b } from './b.js';\n",
                raiz,
                "node_modules/\(nome)/index.js"
            )
            try grava("export const a = 'a-\(nome)';\n", raiz, "node_modules/\(nome)/a.js")
            try grava(
                "globalThis.__efeito = 'EFEITO_\(nome)';\nexport const b = 'b';\n",
                raiz,
                "node_modules/\(nome)/b.js"
            )
        }
        try grava(
            "import { a } from 'lib-limpa';\nimport { a as a2 } from 'lib-suja';\n(globalThis as any).__r = a + a2;\n",
            raiz,
            "src/main.ts"
        )
        _ = try await build(raiz)
        let js = try #require(try referencias(le(raiz, "dist/index.html")).js.first)
        let texto = try le(raiz, "dist" + js)
        #expect(!texto.contains("EFEITO_lib-limpa"), "o módulo sem uso de um pacote sideEffects:false entrou")
        #expect(texto.contains("EFEITO_lib-suja"))
        #expect(roda(texto).valor == "a-lib-limpaa-lib-suja")
    }

    /// `import "/src/…"` é da raiz do projeto, como no Vite — no build e no dev.
    @Test func importAbsolutoEhDaRaiz() async throws {
        let raiz = novaRaiz()
        try grava(
            "<html><head></head><body><script type=\"module\" src=\"/src/main.ts\"></script></body></html>",
            raiz,
            "index.html"
        )
        try grava("export const v = 'da-raiz';\n", raiz, "src/lib/util.ts")
        try grava("import { v } from '/src/lib/util';\n(globalThis as any).__r = v;\n", raiz, "src/main.ts")
        _ = try await build(raiz)
        #expect(try valorDoBuild(raiz) == "da-raiz")
    }

    /// Sem index.html ou sem script, o erro de sempre.
    @Test func semIndexOuSemScript() async throws {
        let raiz = novaRaiz()
        try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await ViteBuild.rodar(raiz: raiz, esbuild: Esbuild(root: raiz)) }
        try grava("<html><body>sem script</body></html>", raiz, "index.html")
        await #expect(throws: (any Error).self) { try await ViteBuild.rodar(raiz: raiz, esbuild: Esbuild(root: raiz)) }
        // O script que falta é dito pelo nome do HTML, não pela entrada virtual.
        try grava(
            "<html><body><script type=\"module\" src=\"/src/nao-existe.tsx\"></script></body></html>",
            raiz,
            "index.html"
        )
        do {
            _ = try await ViteBuild.rodar(raiz: raiz, esbuild: Esbuild(root: raiz))
            Issue.record("o build passou sem o script")
        } catch {
            #expect(error.localizedDescription.contains("/src/nao-existe.tsx"), "\(error.localizedDescription)")
            #expect(!error.localizedDescription.contains("__odete"))
        }
    }
}
