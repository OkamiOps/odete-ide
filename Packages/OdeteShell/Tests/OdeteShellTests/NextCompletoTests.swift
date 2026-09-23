import Foundation
import OdeteBundler
import OdeteNpm
import Testing
import WebKit

/// O que faltava para um projeto Next de verdade aparecer inteiro no Preview: o CSS, a
/// árvore de servidor com síncronos e async misturados, os providers com filhos, as ilhas
/// sem mexer no layout, `next/*` no navegador e as convenções de rota do App Router.
///
/// Os testes de hidratação abrem a página num WKWebView de verdade: é o único jeito de
/// provar que a ilha responde a clique, e não só que o HTML saiu certo.
@MainActor
struct NextCompletoTests {
    let base = NextIlhasTests()

    func sobe(_ raiz: URL) async throws -> DevServer {
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        return dev
    }

    func pega(_ dev: DevServer, _ rota: String) async throws -> (String, HTTPURLResponse?) {
        let u = rota == "/" ? dev.url : URL(string: rota, relativeTo: dev.url)!
        let (d, r) = try await URLSession.shared.data(from: u)
        return (String(decoding: d, as: UTF8.self), r as? HTTPURLResponse)
    }

    func ate(_ prazo: Duration = .seconds(30), _ condicao: () async -> Bool) async -> Bool {
        let fim = ContinuousClock.now + prazo
        while ContinuousClock.now < fim {
            if await condicao() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condicao()
    }

    /// Um navegador de verdade, com o `console.error` guardado em `__erros` para o teste
    /// ver aviso de hidratação — que o React dá no console e não quebra nada visível.
    func navegador(_ url: URL) async -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.addUserScript(WKUserScript(
            source: """
            window.__erros = [];
            const e = console.error.bind(console);
            console.error = (...a) => { window.__erros.push(a.map(String).join(" ")); e(...a); };
            const w = console.warn.bind(console);
            console.warn = (...a) => { window.__erros.push("aviso: " + a.map(String).join(" ")); w(...a); };
            window.addEventListener("error", (ev) => window.__erros.push(String(ev.message || (ev.target && ev.target.src) || ev)), true);
            window.addEventListener("unhandledrejection", (ev) => window.__erros.push("rejeição: " + String(ev.reason && ev.reason.stack || ev.reason)));
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let wv = WKWebView(frame: .init(x: 0, y: 0, width: 1024, height: 768), configuration: cfg)
        wv.load(URLRequest(url: url))
        _ = await ate { !wv.isLoading }
        return wv
    }

    func js(_ wv: WKWebView, _ codigo: String) async -> Any? {
        try? await wv.evaluateJavaScript(codigo)
    }

    func texto(_ wv: WKWebView, _ codigo: String) async -> String {
        (await js(wv, codigo) as? String) ?? ""
    }

    /// O que chegou pelo socket do Preview (css ou reload).
    final class Avisos: @unchecked Sendable {
        private var lista: [String] = []
        private let trava = NSLock()
        func poe(_ s: String) { trava.withLock { lista.append(s) } }
        var todos: [String] { trava.withLock { lista } }
    }

    func escuta(_ dev: DevServer) throws -> (URLSessionWebSocketTask, Avisos, Task<Void, Never>) {
        let ws = try URLSession.shared.webSocketTask(with: #require(URL(string: "ws://127.0.0.1:\(dev.port)/@odete/ws")))
        ws.resume()
        let avisos = Avisos()
        let t = Task {
            while let m = try? await ws.receive() {
                if case let .string(s) = m { avisos.poe(s) }
            }
        }
        return (ws, avisos, t)
    }

    // MARK: - 1. CSS

    /// O CSS que o layout e a página importam chega à página, por uma folha no `<head>` do
    /// documento que o próprio layout escreve. Mudar só o CSS troca a folha sem recarregar.
    @Test func cssDoLayoutEDaPaginaChegaAoHead() async throws {
        guard let raiz = try await base.projeto([
            "app/globals.css": "body { margin-left: 13px; }",
            "app/pagina.css": ".cartao { padding: 7px; }",
            "app/layout.tsx": """
            import "./globals.css";
            export default function L({ children }: { children: React.ReactNode }) {
              return <html lang="pt-BR"><body className="corpo">{children}</body></html>;
            }
            """,
            "app/page.tsx": """
            import "./pagina.css";
            export default function P() { return <div className="cartao">oi</div>; }
            """,
        ]) else { return }
        let dev = try await sobe(raiz)
        defer { dev.stop() }

        let (html, _) = try await pega(dev, "/")
        // O documento é o do layout, com o que é da Odete dentro do `<head>` dele — e não
        // um `<html>` dentro do `<body>` de outro.
        #expect(html.hasPrefix("<!DOCTYPE html><html lang=\"pt-BR\"><head>"), "\(html.prefix(300))")
        #expect(!html.contains("<body><html"), "o documento saiu aninhado: \(html.prefix(300))")
        #expect(html.contains("<body class=\"corpo\">"))
        #expect(html.contains(#"<link rel="stylesheet" href="/@odete/css/@next/">"#), "faltou a folha: \(html.prefix(600))")

        let (css, r) = try await pega(dev, "/@odete/css/@next/")
        #expect(r?.value(forHTTPHeaderField: "content-type")?.contains("text/css") == true)
        #expect(css.contains("margin-left: 13px"), "o CSS do layout não veio: \(css)")
        #expect(css.contains("padding: 7px"), "o CSS da página não veio: \(css)")

        // Só o CSS muda: o Preview troca a folha e não recarrega.
        let (ws, recebido, t) = try escuta(dev)
        defer { ws.cancel(with: .normalClosure, reason: nil); t.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        try "body { margin-left: 21px; }".write(to: raiz.appending(path: "app/globals.css"), atomically: true, encoding: .utf8)
        let trocou = await ate { recebido.todos.contains("css") }
        #expect(trocou, "CSS sozinho não avisou o Preview: \(recebido.todos)")
        #expect(!recebido.todos.contains("reload"), "CSS sozinho recarregou a página")
        let (css2, _) = try await pega(dev, "/@odete/css/@next/")
        #expect(css2.contains("margin-left: 21px"), "a folha nova não saiu: \(css2)")
    }

    // MARK: - 2. Árvore de servidor

    /// Página síncrona com filhos async, em lista: o `renderToString` dava "A component
    /// suspended while responding to synchronous input"; agora a árvore inteira resolve.
    @Test func paginaSincronaComFilhosAsync() async throws {
        guard let raiz = try await base.projeto([
            "app/page.tsx": """
            async function Item({ n }: { n: number }) {
              await new Promise((r) => setTimeout(r, 5));
              return <li className="item">item {n}</li>;
            }
            function Lista() { return <ul>{[1, 2, 3].map((n) => <Item key={n} n={n} />)}</ul>; }
            export default function Page() { return <main><h1>sincrona</h1><Lista /></main>; }
            """,
        ]) else { return }
        let dev = try await sobe(raiz)
        defer { dev.stop() }
        let (html, r) = try await pega(dev, "/")
        #expect(r?.statusCode == 200, "\(html.prefix(400))")
        #expect(!html.contains("suspended"), "o async dentro do síncrono não resolveu: \(html.prefix(400))")
        #expect(html.contains("<h1>sincrona</h1>"))
        #expect(html.components(separatedBy: "<li class=\"item\">").count == 4, "faltou item: \(html.prefix(600))")
    }

    // MARK: - 3. Providers com filhos

    /// `<Providers>{children}</Providers>` vira ilha: os filhos de servidor vão como HTML, e
    /// a ilha de cliente que mora neles enxerga o contexto do provider — trocar o tema no
    /// provider muda o que ela mostra.
    @Test func providerComFilhosHidrataEPassaOContexto() async throws {
        guard let raiz = try await base.projeto([
            "app/Tema.tsx": """
            "use client";
            import { createContext, useContext, useState } from "react";
            const Tema = createContext("nenhum");
            export function Providers({ children }: { children: React.ReactNode }) {
              const [tema, setTema] = useState("claro");
              return (
                <Tema.Provider value={tema}>
                  <button id="troca" onClick={() => setTema("escuro")}>trocar</button>
                  {children}
                </Tema.Provider>
              );
            }
            export function MostraTema() {
              const tema = useContext(Tema);
              return <b id="tema">{tema}</b>;
            }
            """,
            "app/layout.tsx": """
            import { Providers } from "./Tema";
            export default function L({ children }: { children: React.ReactNode }) {
              return <html><body><Providers><main id="conteudo">{children}</main></Providers></body></html>;
            }
            """,
            "app/page.tsx": """
            import { MostraTema } from "./Tema";
            export default function P() { return <section><p id="srv">pagina de servidor</p><MostraTema /></section>; }
            """,
        ]) else { return }
        let dev = try await sobe(raiz)
        defer { dev.stop() }

        let (html, _) = try await pega(dev, "/")
        #expect(html.contains("$odeteSlot"), "os filhos não viraram slot: \(html.prefix(800))")
        #expect(!html.contains("data-estatica"), "o provider ficou estático: \(html.prefix(800))")
        #expect(html.contains("<odete-filhos data-slot=\"children\">"))
        #expect(html.contains("<b id=\"tema\">claro</b>"), "o contexto não chegou no servidor: \(html.prefix(800))")
        let (ilhas, _) = try await pega(dev, "/@odete/ilhas/")
        #expect(ilhas.contains("MostraTema") && ilhas.contains("Providers"), "faltou ilha no pacote: \(ilhas.suffix(1500))")

        let wv = await navegador(dev.url)
        let trocou = await ate {
            await texto(wv, "document.getElementById('troca').click(); document.getElementById('tema').textContent") == "escuro"
        }
        let corpo = await texto(wv, "document.body.innerHTML + '\\n' + window.__erros.join('\\n')")
        #expect(trocou, "a ilha de dentro não enxergou o provider: \(corpo)")
        #expect(await texto(wv, "document.getElementById('srv').textContent") == "pagina de servidor")
        #expect(await js(wv, "document.querySelectorAll('#tema').length") as? Int == 1, "a ilha de dentro duplicou")
        let erros = await js(wv, "window.__erros.join('\\n')") as? String ?? ""
        #expect(!erros.contains("ydrat"), "a hidratação reclamou: \(erros)")
    }

    // MARK: - 4. Ilha não mexe no layout

    /// Uma ilha dentro de um flex não pode virar um item a mais: `<odete-ilha>` e
    /// `<odete-filhos>` são `display: contents`.
    @Test func ilhaNaoMudaOLayout() async throws {
        guard let raiz = try await base.projeto([
            "app/Item.tsx": """
            "use client";
            export default function Item({ n }: { n: number }) { return <div className="item" style={{ width: 100 }}>{n}</div>; }
            """,
            "app/page.tsx": """
            import Item from "./Item";
            export default function P() {
              return <div id="linha" style={{ display: "flex" }}><Item n={1} /><Item n={2} /></div>;
            }
            """,
        ]) else { return }
        let dev = try await sobe(raiz)
        defer { dev.stop() }
        let (html, _) = try await pega(dev, "/")
        #expect(html.contains("odete-ilha,odete-filhos{display:contents}"), "faltou a regra: \(html.prefix(600))")

        let wv = await navegador(dev.url)
        let display = await texto(wv, "getComputedStyle(document.querySelector('odete-ilha')).display")
        #expect(display == "contents", "a ilha ocupa lugar: \(display)")
        // Os dois itens ficam lado a lado, filhos diretos do flex para o layout.
        let lado = await js(wv, """
        (() => { const i = document.querySelectorAll('.item'); return i[1].getBoundingClientRect().left - i[0].getBoundingClientRect().left; })()
        """) as? Double
        #expect(lado == 100, "os itens não ficaram lado a lado: \(String(describing: lado))")
    }

    // MARK: - 5. `next/*` no navegador

    /// Uma ilha que usa `next/link` e os hooks de `next/navigation` renderiza igual nos
    /// dois lados e navega de verdade no Preview.
    @Test func linkENavegacaoFuncionamNaIlha() async throws {
        guard let raiz = try await base.projeto([
            "app/Nav.tsx": """
            "use client";
            import Link from "next/link";
            import { usePathname, useSearchParams, useParams, useRouter } from "next/navigation";
            export default function Nav() {
              const p = usePathname();
              const b = useSearchParams();
              const params = useParams();
              const r = useRouter();
              return (
                <nav>
                  <span id="onde">{p + "|" + b.get("q") + "|" + String(params.slug)}</span>
                  <Link id="link" href={{ pathname: "/produtos/outro", query: { q: "2" } }}>outro</Link>
                  <button id="vai" onClick={() => r.push("/produtos/terceiro?q=3")}>vai</button>
                </nav>
              );
            }
            """,
            "app/produtos/[slug]/page.tsx": """
            import Nav from "../../Nav";
            export default async function P({ params }: any) {
              const { slug } = await params;
              return <main><h1 id="titulo">{slug}</h1><Nav /></main>;
            }
            """,
        ]) else { return }
        let dev = try await sobe(raiz)
        defer { dev.stop() }

        let (html, _) = try await pega(dev, "/produtos/um?q=1")
        #expect(html.contains("/produtos/um|1|um"), "os hooks não leram o pedido no servidor: \(html.prefix(800))")
        #expect(html.contains(#"href="/produtos/outro?q=2""#), "o Link não formatou o href: \(html.prefix(800))")
        let (js, _) = try await pega(dev, "/@odete/ilhas/produtos/um")
        #expect(js.contains("__odeteNextFabrica"), "o pacote não levou o substituto de next/*")

        let wv = await navegador(try #require(URL(string: "/produtos/um?q=1", relativeTo: dev.url)))
        let foi = await ate {
            _ = await self.js(wv, "document.getElementById('vai') && document.getElementById('vai').click()")
            return await texto(wv, "document.getElementById('titulo') ? document.getElementById('titulo').textContent : ''") == "terceiro"
        }
        let onde = await texto(wv, "location.href + '\\n' + window.__erros.join('\\n')")
        #expect(foi, "o router.push não navegou: \(onde)")
        #expect(await texto(wv, "document.getElementById('onde').textContent") == "/produtos/terceiro|3|terceiro")
        let erros = await self.js(wv, "window.__erros.join('\\n')") as? String ?? ""
        #expect(!erros.contains("ydrat"), "a hidratação reclamou: \(erros)")
    }

    // MARK: - 6. Convenções do App Router

    /// `loading`, `template`, `title.template`, ícone de `app/`, `generateMetadata` com
    /// params, `next/image` e `next/font` — o que um projeto real tem e não pode quebrar.
    @Test func convencoesDoAppRouter() async throws {
        guard let raiz = try await base.projeto([
            "app/layout.tsx": """
            import { Inter } from "next/font/google";
            const inter = Inter({ subsets: ["latin"], variable: "--fonte" });
            export const metadata = { title: { default: "Loja", template: "%s | Loja" } };
            export default function L({ children }: { children: React.ReactNode }) {
              return <html lang="pt-BR" className={inter.variable}><body>{children}</body></html>;
            }
            """,
            "app/template.tsx": "export default function T({ children }: any) { return <div id=\"molde\">{children}</div>; }",
            "app/loading.tsx": "export default function C() { return <p>carregando</p>; }",
            "app/produto/[id]/page.tsx": """
            import Image from "next/image";
            export async function generateMetadata({ params }: any) { const { id } = await params; return { title: "Produto " + id }; }
            export default async function P({ params }: any) {
              const { id } = await params;
              return <Image src="/foto.png" alt="foto" width={40} height={30} priority />;
            }
            """,
            "app/page.tsx": "export default function P() { return <p>inicio</p>; }",
        ]) else { return }
        try Data([0, 0, 1, 0]).write(to: raiz.appending(path: "app/favicon.ico"))
        let dev = try await sobe(raiz)
        defer { dev.stop() }

        let (a, _) = try await pega(dev, "/")
        #expect(a.contains("<title>Loja</title>"), "o default do título não valeu: \(a.prefix(600))")
        #expect(a.contains("<div id=\"molde\"><p>inicio</p></div>") || a.contains("<div id=\"molde\"><!--$--><p>inicio</p>"),
                "o template não embrulhou: \(a.prefix(800))")
        #expect(a.contains(#"<link rel="icon" href="/favicon.ico""#), "o ícone de app/ não foi para o head")
        #expect(a.contains("fonts.googleapis.com/css2?family=Inter"), "a fonte do Google não entrou")
        #expect(a.contains("__odete_fonte_inter_var"), "a variável da fonte não foi para o <html>")

        let (b, rb) = try await pega(dev, "/produto/42")
        #expect(rb?.statusCode == 200, "\(b.prefix(400))")
        #expect(b.contains("<title>Produto 42 | Loja</title>"), "o template do título não valeu: \(b.prefix(600))")
        #expect(b.contains(#"src="/foto.png""#) && b.contains(#"width="40""#), "o next/image não virou <img>: \(b.prefix(900))")
        #expect(!b.contains(" priority"), "prop do next/image vazou para o HTML")

        let (_, ri) = try await pega(dev, "/favicon.ico")
        #expect(ri?.statusCode == 200, "o favicon de app/ não foi servido")
    }

    /// Os arquivos que o `create-next-app` escreve (App Router + TypeScript + Tailwind), sem
    /// o que não roda aqui (eslint, next.config). Também é o projeto das medições.
    static let createNextApp: [String: String] = [
        "app/layout.tsx": """
        import type { Metadata } from "next";
        import { Geist, Geist_Mono } from "next/font/google";
        import "./globals.css";

        const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
        const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

        export const metadata: Metadata = {
          title: "Create Next App",
          description: "Generated by create next app",
        };

        export default function RootLayout({ children }: LayoutProps<"/">) {
          return (
            <html lang="en" className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}>
              <body className="min-h-full flex flex-col">{children}</body>
            </html>
          );
        }
        """,
        "app/page.tsx": """
        import Image from "next/image";
        export default function Home() {
          return (
            <div className="flex flex-col flex-1 items-center justify-center bg-zinc-50 font-sans dark:bg-black">
              <main className="flex flex-1 w-full max-w-3xl flex-col items-center justify-between py-32 px-16">
                <Image className="dark:invert h-5 w-[100px]" src="/next.svg" alt="Next.js logo" width={100} height={20} priority />
                <h1 className="max-w-xs text-3xl font-semibold">To get started, edit the page.tsx file.</h1>
              </main>
            </div>
          );
        }
        """,
        "app/globals.css": """
        :root {
          --background: #ffffff;
          --foreground: #171717;
        }
        body {
          background: var(--background);
          color: var(--foreground);
          font-family: Arial, Helvetica, sans-serif;
        }
        """,
        "public/next.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 2\"></svg>",
    ]

    /// O projeto do `create-next-app` (App Router + TypeScript + Tailwind), com os
    /// arquivos que ele escreve: fonte do Google no layout, `next/image` na página e o
    /// globals.css do Tailwind v4.
    @Test func projetoDoCreateNextApp() async throws {
        guard let raiz = try await base.projeto(Self.createNextApp) else { return }
        let dev = try await sobe(raiz)
        defer { dev.stop() }
        let (html, r) = try await pega(dev, "/")
        #expect(r?.statusCode == 200, "\(html.prefix(600))")
        #expect(html.hasPrefix("<!DOCTYPE html><html lang=\"en\""), "\(html.prefix(300))")
        #expect(html.contains("<title>Create Next App</title>"))
        #expect(html.contains("family=Geist&") && html.contains("family=Geist+Mono"), "as fontes do Google não entraram")
        #expect(html.contains("__odete_fonte_geist_var"), "a variável da fonte não foi para o <html>")
        #expect(html.contains(#"alt="Next.js logo""#) && html.contains(#"src="/next.svg""#))
        #expect(html.contains("/@odete/css/@next/"), "a folha do globals.css não entrou")
        let (css, _) = try await pega(dev, "/@odete/css/@next/")
        #expect(css.contains("--background: #ffffff"), "o globals.css não chegou: \(css.prefix(300))")
        let (svg, rs) = try await pega(dev, "/next.svg")
        #expect(rs?.statusCode == 200 && svg.contains("<svg"))
    }
}
