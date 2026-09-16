import Foundation
import OdeteBundler
import OdeteNpm
import Testing

/// Um projeto Next precisa aparecer no Preview.
///
/// O Next roda um servidor Node que a Odete não tem. O que ela tem é o mesmo React e o
/// mesmo `require`, então a página é executada aqui. Os testes precisam do npm de
/// verdade, porque é o React do projeto que renderiza — sem rede, eles se calam em vez
/// de falhar por ruído.
struct NextTests {
    func projetoNext(_ arquivos: [String: String]) async throws -> URL? {
        let raiz = FileManager.default.temporaryDirectory
            .appending(path: "odete-next-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        for (caminho, corpo) in arquivos {
            let f = raiz.appending(path: caminho)
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try corpo.write(to: f, atomically: true, encoding: .utf8)
        }
        try #"{"name":"app","dependencies":{"next":"15.0.0","react":"19.2.0","react-dom":"19.2.0"}}"#
            .write(to: raiz.appending(path: "package.json"), atomically: true, encoding: .utf8)
        guard let rep = try? await Installer(project: raiz, registry: HTTPRegistry())
            .install(add: [.init("react@19.2.0"), .init("react-dom@19.2.0")]),
            !rep.installed.isEmpty
        else { return nil }
        return raiz
    }

    func corpo(_ raiz: URL, _ rota: String) async throws -> String {
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }
        let u = rota == "/" ? dev.url : dev.url.appending(path: rota)
        let (d, _) = try await URLSession.shared.data(from: u)
        return String(decoding: d, as: UTF8.self)
    }

    @Test func appRouterComLayout() async throws {
        guard let raiz = try await projetoNext([
            "app/layout.tsx": """
            export default function Layout({ children }: { children: any }) {
              return <div className="wrap"><header>topo</header>{children}</div>;
            }
            """,
            "app/page.tsx": """
            export default function Page() {
              return <h1>Oi do Next</h1>;
            }
            """,
        ]) else { return }
        let html = try await corpo(raiz, "/")
        #expect(html.contains("<h1>Oi do Next</h1>"), "a página não renderizou: \(html.prefix(400))")
        #expect(html.contains("<header>topo</header>"), "o layout não embrulhou")
    }

    /// Componente de servidor é função `async`, que o `renderToString` não aceita. Quem
    /// resolve a árvore antes é o nosso renderizador.
    @Test func componenteDeServidorAsync() async throws {
        guard let raiz = try await projetoNext([
            "app/page.tsx": """
            async function Dados() {
              const n = await Promise.resolve(42);
              return <span id="n">{n}</span>;
            }
            export default async function Page() {
              return <main><Dados /></main>;
            }
            """,
        ]) else { return }
        let html = try await corpo(raiz, "/")
        #expect(html.contains("<span id=\"n\">42</span>"), "async não resolveu: \(html.prefix(400))")
    }

    @Test func rotaAninhadaNoAppRouter() async throws {
        guard let raiz = try await projetoNext([
            "app/blog/page.tsx": "export default function P() { return <p>blog</p>; }",
        ]) else { return }
        #expect(try await corpo(raiz, "blog").contains("<p>blog</p>"))
    }

    @Test func pagesRouterComApp() async throws {
        guard let raiz = try await projetoNext([
            "pages/_app.tsx": """
            export default function App({ Component, pageProps }: any) {
              return <div id="app"><Component {...pageProps} /></div>;
            }
            """,
            "pages/index.tsx": "export default function Home() { return <h2>home</h2>; }",
            "pages/sobre.tsx": "export default function Sobre() { return <h2>sobre</h2>; }",
        ]) else { return }
        let home = try await corpo(raiz, "/")
        #expect(home.contains("<div id=\"app\">"), "o _app não embrulhou: \(home.prefix(300))")
        #expect(home.contains("<h2>home</h2>"))
        #expect(try await corpo(raiz, "sobre").contains("<h2>sobre</h2>"))
    }

    @Test func semReactOServidorExplica() async throws {
        let raiz = FileManager.default.temporaryDirectory
            .appending(path: "odete-next-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: raiz.appending(path: "app"), withIntermediateDirectories: true)
        try "export default function P() { return null; }"
            .write(to: raiz.appending(path: "app/page.tsx"), atomically: true, encoding: .utf8)
        try #"{"name":"a"}"#.write(to: raiz.appending(path: "package.json"), atomically: true, encoding: .utf8)
        let html = try await corpo(raiz, "/")
        #expect(html.contains("npm install"), "não explicou o que falta: \(html.prefix(300))")
    }
}

/// Hidratação: a página tem que responder a clique, não só aparecer.
///
/// Um módulo que começa com "use client" roda nos dois lados. No servidor ele renderiza
/// dentro de uma marca; no navegador só ele é baixado e hidratado, e o resto da página
/// continua sendo HTML.
struct NextIlhasTests {
    func projeto(_ arquivos: [String: String]) async throws -> URL? {
        let raiz = FileManager.default.temporaryDirectory
            .appending(path: "odete-ilha-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        for (caminho, corpo) in arquivos {
            let f = raiz.appending(path: caminho)
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try corpo.write(to: f, atomically: true, encoding: .utf8)
        }
        try #"{"name":"app","dependencies":{"react":"19.2.0","react-dom":"19.2.0"}}"#
            .write(to: raiz.appending(path: "package.json"), atomically: true, encoding: .utf8)
        guard let rep = try? await Installer(project: raiz, registry: HTTPRegistry())
            .install(add: [.init("react@19.2.0"), .init("react-dom@19.2.0")]),
            !rep.installed.isEmpty
        else { return nil }
        return raiz
    }

    static let contador = """
    "use client";
    import { useState } from "react";
    export default function Contador({ inicio }: { inicio: number }) {
      const [n, setN] = useState(inicio);
      return <button onClick={() => setN(n + 1)}>{n} toques</button>;
    }
    """

    @Test func componenteDeClienteVirilhaEHidrata() async throws {
        guard let raiz = try await projeto([
            "app/Contador.tsx": Self.contador,
            "app/page.tsx": """
            import Contador from "./Contador";
            export default function Page() {
              return <main><h1>estatico</h1><Contador inicio={7} /></main>;
            }
            """,
        ]) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }

        let (d, _) = try await URLSession.shared.data(from: dev.url)
        let html = String(decoding: d, as: UTF8.self)
        // o servidor renderizou o componente de cliente, dentro da marca
        #expect(html.contains("<odete-ilha"), "faltou a marca da ilha: \(html.prefix(400))")
        // O React separa nós de texto no SSR: `{n} toques` sai como `7<!-- --> toques`.
        #expect(html.contains("7") && html.contains("toques"), "o componente não renderizou no servidor")
        #expect(html.contains("app/Contador.tsx#default"), "a marca não diz qual módulo montar")
        #expect(
            html.contains(#"data-props="{&quot;inicio&quot;:7}""#) || html.contains("inicio"),
            "as props não foram junto"
        )
        // e a página pede o pacote de hidratação
        #expect(html.contains("/@odete/ilhas/"), "não pediu o pacote das ilhas")

        let (j, jr) = try await URLSession.shared.data(from: dev.url.appending(path: "@odete/ilhas/"))
        #expect((jr as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-type")?.contains("javascript") == true)
        let js = String(decoding: j, as: UTF8.self)
        #expect(js.contains("hydrateRoot"), "o pacote não hidrata: \(js.prefix(300))")
        #expect(js.contains("toques"), "o componente de cliente não entrou no pacote")
    }

    /// Página sem componente de cliente não baixa JS nenhum.
    @Test func paginaEstaticaNaoBaixaJS() async throws {
        guard let raiz = try await projeto([
            "app/page.tsx": "export default function P() { return <p>so html</p>; }",
        ]) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }
        let (d, _) = try await URLSession.shared.data(from: dev.url)
        let html = String(decoding: d, as: UTF8.self)
        #expect(html.contains("<p>so html</p>"))
        #expect(!html.contains("/@odete/ilhas/"), "pediu hidratação sem precisar")
    }
}

/// Middleware: a função que roda antes da rota e decide o que acontece.
///
/// Não depende do runtime da Vercel — depende de executar a função e ler o que ela
/// devolveu, e isso a Odete faz.
struct NextMiddlewareTests {
    let base = NextIlhasTests()

    func dev(_ raiz: URL) async throws -> DevServer {
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        return dev
    }

    @Test func middlewareRespondeSozinho() async throws {
        guard let raiz = try await base.projeto([
            "app/page.tsx": "export default function P() { return <p>pagina</p>; }",
            "middleware.ts": """
            import { NextResponse } from "next/server";
            export function middleware(req: any) {
              if (req.nextUrl.pathname === "/quem") {
                return NextResponse.json({ ok: true, caminho: req.nextUrl.pathname });
              }
              return NextResponse.next();
            }
            """,
        ]) else { return }
        let dev = try await dev(raiz)
        defer { dev.stop() }
        let (d, r) = try await URLSession.shared.data(from: dev.url.appending(path: "quem"))
        let corpo = String(decoding: d, as: UTF8.self)
        #expect(corpo.contains("\"ok\":true"), "o middleware não respondeu: \(corpo.prefix(200))")
        #expect(
            (r as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-type")?.contains("json") == true
        )
        // e quem passa continua chegando na página
        let (p, _) = try await URLSession.shared.data(from: dev.url)
        #expect(String(decoding: p, as: UTF8.self).contains("<p>pagina</p>"))
    }

    @Test func middlewareReescreveERedireciona() async throws {
        guard let raiz = try await base.projeto([
            "app/novo/page.tsx": "export default function P() { return <p>novo</p>; }",
            "middleware.ts": """
            import { NextResponse } from "next/server";
            export function middleware(req: any) {
              const p = req.nextUrl.pathname;
              if (p === "/velho") return NextResponse.rewrite(new URL("/novo", req.url));
              if (p === "/vai") return NextResponse.redirect(new URL("/novo", req.url));
              return NextResponse.next();
            }
            """,
        ]) else { return }
        let dev = try await dev(raiz)
        defer { dev.stop() }
        let (a, _) = try await URLSession.shared.data(from: dev.url.appending(path: "velho"))
        #expect(
            String(decoding: a, as: UTF8.self).contains("<p>novo</p>"),
            "a reescrita não pegou: \(String(decoding: a, as: UTF8.self).prefix(200))"
        )
        // o redirecionamento é seguido pela URLSession: chegar em /novo é a prova
        let (b, rb) = try await URLSession.shared.data(from: dev.url.appending(path: "vai"))
        #expect(String(decoding: b, as: UTF8.self).contains("<p>novo</p>"))
        #expect((rb as? HTTPURLResponse)?.url?.path == "/novo", "não redirecionou para /novo")
    }

    /// `NextResponse.next()` pode acrescentar cabeçalho e cookie ao que vier depois.
    @Test func middlewareAcrescentaCabecalho() async throws {
        guard let raiz = try await base.projeto([
            "app/page.tsx": "export default function P() { return <p>oi</p>; }",
            "middleware.ts": """
            import { NextResponse } from "next/server";
            export function middleware() {
              const r = NextResponse.next();
              r.headers.set("x-odete", "passou");
              r.cookies.set("visita", "1");
              return r;
            }
            """,
        ]) else { return }
        let dev = try await dev(raiz)
        defer { dev.stop() }
        let (d, r) = try await URLSession.shared.data(from: dev.url)
        let h = r as? HTTPURLResponse
        #expect(String(decoding: d, as: UTF8.self).contains("<p>oi</p>"), "a página não veio")
        #expect(h?.value(forHTTPHeaderField: "x-odete") == "passou", "o cabeçalho não passou")
        #expect(h?.value(forHTTPHeaderField: "set-cookie")?.contains("visita=1") == true)
    }

    /// `config.matcher` limita onde o middleware roda — inclusive no padrão do Next,
    /// `/((?!api|_next).*)`.
    @Test func matcherLimitaOndeRoda() async throws {
        guard let raiz = try await base.projeto([
            "app/page.tsx": "export default function P() { return <p>livre</p>; }",
            "app/admin/page.tsx": "export default function P() { return <p>admin</p>; }",
            "middleware.ts": """
            import { NextResponse } from "next/server";
            export function middleware() { return new NextResponse("barrado", { status: 403 }); }
            export const config = { matcher: ["/admin/:path*"] };
            """,
        ]) else { return }
        let dev = try await dev(raiz)
        defer { dev.stop() }
        let (a, _) = try await URLSession.shared.data(from: dev.url)
        #expect(String(decoding: a, as: UTF8.self).contains("<p>livre</p>"), "o matcher barrou demais")
        let (b, rb) = try await URLSession.shared.data(from: dev.url.appending(path: "admin"))
        #expect((rb as? HTTPURLResponse)?.statusCode == 403, "o matcher não pegou /admin")
        #expect(String(decoding: b, as: UTF8.self) == "barrado")
    }
}

/// `next/font`: a fonte declarada no código tem que chegar no `<head>`.
struct NextFontesTests {
    let base = NextIlhasTests()

    @Test func fonteDoGoogleEntraNoHead() async throws {
        guard let raiz = try await base.projeto([
            "app/layout.tsx": """
            import { Roboto_Mono } from "next/font/google";
            const fonte = Roboto_Mono({ subsets: ["latin"], weight: ["400", "700"] });
            export default function Layout({ children }: any) {
              return <div className={fonte.className}>{children}</div>;
            }
            """,
            "app/page.tsx": "export default function P() { return <p>texto</p>; }",
        ]) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }
        let (d, _) = try await URLSession.shared.data(from: dev.url)
        let html = String(decoding: d, as: UTF8.self)
        #expect(
            html.contains("fonts.googleapis.com/css2?family=Roboto+Mono:wght@400;700"),
            "a folha da fonte não entrou: \(html.prefix(500))"
        )
        #expect(html.contains("__odete_fonte_roboto_mono{font-family:'Roboto Mono'"), "faltou a regra CSS")
        #expect(html.contains("class=\"__odete_fonte_roboto_mono\""), "a classe não chegou no elemento")
    }

    @Test func fonteLocalViraFontFace() async throws {
        guard let raiz = try await base.projeto([
            "app/fontes/Minha.woff2": "nao-e-uma-fonte-de-verdade",
            "app/layout.tsx": """
            import localFont from "next/font/local";
            const fonte = localFont({ src: "./fontes/Minha.woff2", variable: "--minha" });
            export default function Layout({ children }: any) {
              return <div className={fonte.variable}>{children}</div>;
            }
            """,
            "app/page.tsx": "export default function P() { return <p>texto</p>; }",
        ]) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }
        let (d, _) = try await URLSession.shared.data(from: dev.url)
        let html = String(decoding: d, as: UTF8.self)
        #expect(html.contains("@font-face"), "não gerou @font-face: \(html.prefix(500))")
        #expect(html.contains("url('/app/fontes/Minha.woff2')"), "o arquivo da fonte não foi achado")
        #expect(html.contains("--minha:'Odete minha'"), "a custom property não saiu")
        // e o navegador consegue baixar o arquivo
        let (_, r) = try await URLSession.shared.data(from: dev.url.appending(path: "app/fontes/Minha.woff2"))
        #expect((r as? HTTPURLResponse)?.statusCode == 200, "a fonte não é servida")
    }
}
