import Foundation
import OdeteBundler
import OdeteNpm
import Testing

/// App Router inteiro: segmento dinâmico, grupo de rota, route handler, metadata,
/// `not-found` e `error`. É o que faz um projeto Next de verdade abrir no Preview.
struct NextRotasTests {
    let base = NextIlhasTests()

    func corpo(_ dev: DevServer, _ rota: String) async throws -> (String, HTTPURLResponse?) {
        let u = rota == "/" ? dev.url : dev.url.appending(path: rota)
        let (d, r) = try await URLSession.shared.data(from: u)
        return (String(decoding: d, as: UTF8.self), r as? HTTPURLResponse)
    }

    @Test func segmentoDinamicoEGrupoDeRota() async throws {
        guard let raiz = try await base.projeto([
            "app/(loja)/produto/[id]/page.tsx": """
            export default async function P({ params }: any) {
              const { id } = await params;
              return <p id="p">produto {id}</p>;
            }
            """,
            "app/blog/[...resto]/page.tsx": """
            export default function P({ params }: any) {
              return <p id="b">{params.resto.join("/")}</p>;
            }
            """,
            "app/page.tsx": "export default function P() { return <p>raiz</p>; }",
        ]) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }

        let (a, _) = try await corpo(dev, "produto/abc")
        #expect(a.contains("produto ") && a.contains("abc"), "o grupo ou o [id] não casou: \(a.prefix(400))")
        let (b, _) = try await corpo(dev, "blog/2026/setembro/oi")
        #expect(b.contains("2026/setembro/oi"), "o catch-all não pegou o resto: \(b.prefix(400))")
        let (c, _) = try await corpo(dev, "/")
        #expect(c.contains("<p>raiz</p>"), "a raiz parou de funcionar")
    }

    @Test func routeHandlerRespondePorMetodo() async throws {
        guard let raiz = try await base.projeto([
            "app/api/itens/route.ts": """
            import { NextResponse } from "next/server";
            export async function GET() { return NextResponse.json({ itens: ["a", "b"] }); }
            export async function POST(req: any) {
              const corpo = await req.json();
              return NextResponse.json({ recebi: corpo.nome }, { status: 201 });
            }
            """,
            "app/api/eco/[quem]/route.ts": """
            export async function GET(_req: any, { params }: any) { return { oi: params.quem }; }
            """,
            "app/page.tsx": "export default function P() { return <p>raiz</p>; }",
        ]) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }

        let (g, rg) = try await corpo(dev, "api/itens")
        #expect(g.contains("\"itens\""), "o GET não respondeu: \(g.prefix(300))")
        #expect(rg?.value(forHTTPHeaderField: "content-type")?.contains("json") == true)

        var req = URLRequest(url: dev.url.appending(path: "api/itens"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = Data(#"{"nome":"caneca"}"#.utf8)
        let (d, r) = try await URLSession.shared.data(for: req)
        #expect((r as? HTTPURLResponse)?.statusCode == 201, "o POST não respondeu 201")
        #expect(String(decoding: d, as: UTF8.self).contains("caneca"))

        let (e, _) = try await corpo(dev, "api/eco/marcos")
        #expect(e.contains("\"oi\":\"marcos\""), "o param do handler não chegou: \(e.prefix(300))")

        // método sem função é 405, não 404
        var del = URLRequest(url: dev.url.appending(path: "api/itens"))
        del.httpMethod = "DELETE"
        let (_, rd) = try await URLSession.shared.data(for: del)
        #expect((rd as? HTTPURLResponse)?.statusCode == 405)
    }

    @Test func metadataViraCabeca() async throws {
        guard let raiz = try await base.projeto([
            "app/layout.tsx": """
            export const metadata = { title: "Site inteiro", description: "descricao do site" };
            export default function L({ children }: any) { return <div>{children}</div>; }
            """,
            "app/loja/page.tsx": """
            export async function generateMetadata() { return { title: "Loja" }; }
            export default function P() { return <p>loja</p>; }
            """,
            "app/page.tsx": "export default function P() { return <p>raiz</p>; }",
        ]) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }
        let (a, _) = try await corpo(dev, "/")
        #expect(a.contains("<title>Site inteiro</title>"), "o metadata do layout não saiu: \(a.prefix(400))")
        #expect(a.contains("name=\"description\" content=\"descricao do site\""))
        let (b, _) = try await corpo(dev, "loja")
        #expect(b.contains("<title>Loja</title>"), "a página não sobrepôs o título: \(b.prefix(400))")
        #expect(b.contains("descricao do site"), "o que a página não define vem do layout")
    }

    @Test func naoAchouEErroUsamAPaginaDoProjeto() async throws {
        guard let raiz = try await base.projeto([
            "app/not-found.tsx": "export default function NF() { return <p id=\"nf\">nao achei isso</p>; }",
            "app/error.tsx": """
            "use client";
            export default function Erro({ error }: any) {
              return <p id="err">quebrou: {error.message}</p>;
            }
            """,
            "app/quebra/page.tsx": """
            export default function P(): any { throw new Error("de proposito"); }
            """,
            "app/page.tsx": "export default function P() { return <p>raiz</p>; }",
        ]) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }

        let (a, ra) = try await corpo(dev, "nao/existe")
        #expect(ra?.statusCode == 404)
        #expect(a.contains("nao achei isso"), "o not-found do projeto não foi usado: \(a.prefix(400))")

        let (b, rb) = try await corpo(dev, "quebra")
        #expect(rb?.statusCode == 500)
        #expect(b.contains("de proposito"), "o error do projeto não foi usado: \(b.prefix(400))")
    }

    @Test func pagesRouterTambemTemSegmentoDinamico() async throws {
        guard let raiz = try await base.projeto([
            "pages/post/[id].tsx": "export default function P({ id }: any) { return <p>post</p>; }",
            "pages/index.tsx": "export default function H() { return <p>home</p>; }",
        ]) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }
        #expect(try await corpo(dev, "post/42").0.contains("<p>post</p>"))
        #expect(try await corpo(dev, "/").0.contains("<p>home</p>"))
    }
}
