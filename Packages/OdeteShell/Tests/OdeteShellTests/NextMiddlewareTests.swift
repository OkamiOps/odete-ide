import Foundation
import OdeteBundler
import OdeteNpm
import Testing

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
