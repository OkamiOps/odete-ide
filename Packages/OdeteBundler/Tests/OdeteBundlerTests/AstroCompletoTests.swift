import Foundation
@testable import OdeteBundler
import Testing

/// O que um projeto Astro de verdade usa e o Preview não mostrava: frontmatter em
/// TypeScript, CSS importado e `<style>` com escopo, imagem importada, rotas dinâmicas com
/// `getStaticPaths`, endpoints, páginas em Markdown e módulos `.ts` que mudam.
///
/// Nenhum destes precisa de pacote instalado: o compilador, o empacotamento dos imports e
/// o Markdown são da Odete. As content collections (que usam o zod do projeto) estão nos
/// testes do shell, com npm de verdade.
struct AstroCompletoTests {
    func projeto(_ arquivos: [String: String]) throws -> URL {
        let raiz = FileManager.default.temporaryDirectory
            .appending(path: "odete-astro2-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        for (caminho, corpo) in arquivos {
            let f = raiz.appending(path: caminho)
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try corpo.write(to: f, atomically: true, encoding: .utf8)
        }
        if arquivos["package.json"] == nil {
            try #"{"name":"site","type":"module","dependencies":{"astro":"^5.0.0"}}"#
                .write(to: raiz.appending(path: "package.json"), atomically: true, encoding: .utf8)
        }
        return raiz
    }

    func sobe(_ raiz: URL) async throws -> DevServer {
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .astro)
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

    // MARK: - 7. TypeScript no frontmatter

    @Test func frontmatterEmTypeScriptCompila() async throws {
        let raiz = try projeto([
            "src/components/Cartao.astro": """
            ---
            import type { HTMLAttributes } from "astro/types";
            interface Props extends HTMLAttributes<"div"> {
              titulo: string;
              n?: number;
            }
            const { titulo, n = 1 } = Astro.props as Props;
            const dobro: number = n * 2;
            type Cor = "azul" | "verde";
            const cor = "azul" as Cor;
            enum Tam { P = "p", G = "g" }
            ---
            <div class={`cartao ${cor}`} data-tam={Tam.G}>{titulo}: {dobro}{(n as number) > 1 && <b>muitos</b>}</div>
            """,
            "src/pages/index.astro": """
            ---
            import Cartao from "../components/Cartao.astro";
            import { type Item, rotulo } from "../dados";
            const itens: Item[] = [{ nome: "a" }, { nome: "b" }];
            function soma<T extends number>(a: T, b: T): number { return a + b; }
            ---
            <html><body>
              <Cartao titulo="um" n={3} />
              <p id="soma">{soma(2, 3)}</p>
              <ul>{itens.map((i: Item) => <li>{rotulo(i)}</li>)}</ul>
            </body></html>
            """,
            "src/dados.ts": """
            export interface Item { nome: string }
            export const rotulo = (i: Item): string => "item " + i.nome;
            """,
        ])
        let dev = try await sobe(raiz)
        defer { dev.stop() }
        let (html, r) = try await pega(dev, "/")
        #expect(r?.statusCode == 200, "\(html.prefix(600))")
        #expect(html.contains(#"<div class="cartao azul" data-tam="g">um: 6<b>muitos</b></div>"#), "\(html.prefix(900))")
        #expect(html.contains(#"<p id="soma">5</p>"#))
        #expect(html.contains("<li>item a</li><li>item b</li>"), "o .ts importado não veio: \(html.prefix(900))")
    }

    // MARK: - 8. CSS, `<style>` e imagem

    /// O CSS importado no frontmatter e o `<style>` do componente vão para uma folha da
    /// página; o `<style>` ganha escopo (só vale para os elementos do componente) e o
    /// `is:global` não. Imagem importada é o ImageMetadata: endereço, largura e altura.
    @Test func cssEstiloComEscopoEImagem() async throws {
        let raiz = try projeto([
            "src/styles/global.css": "body { margin: 3px; }",
            "src/components/Titulo.astro": """
            <h1 class="t">título</h1>
            <style>
              h1 { color: red; }
              .t:hover, nav > a { color: blue; }
              @media (min-width: 40rem) { h1 { font-size: 2rem; } }
              @keyframes pisca { from { opacity: 0; } to { opacity: 1; } }
              :global(.solto) { color: green; }
            </style>
            <style is:global>
              .global-mesmo { color: black; }
            </style>
            """,
            "src/pages/index.astro": """
            ---
            import "../styles/global.css";
            import Titulo from "../components/Titulo.astro";
            import foto from "../assets/ponto.png";
            ---
            <html><head><title>x</title></head><body>
              <Titulo />
              <h1 id="fora">fora</h1>
              <img id="foto" src={foto.src} width={foto.width} height={foto.height} />
            </body></html>
            """,
        ])
        // PNG de 3×2
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAEUlEQVR4nGP4z8DwHwYYYBwAwNsI+NTq2hEAAAAASUVORK5CYII=")!
        try FileManager.default.createDirectory(at: raiz.appending(path: "src/assets"), withIntermediateDirectories: true)
        try png.write(to: raiz.appending(path: "src/assets/ponto.png"))
        let dev = try await sobe(raiz)
        defer { dev.stop() }

        let (html, _) = try await pega(dev, "/")
        #expect(html.contains(#"<link rel="stylesheet" href="/@odete/css/@astro/">"#), "faltou a folha: \(html.prefix(600))")
        // O elemento do componente leva o atributo de escopo; o de fora, não.
        let cid = try #require(html.firstMatch(of: /<h1 class="t" (data-astro-cid-[a-z0-9]+)>/)?.1)
        #expect(html.contains(#"<h1 id="fora">fora</h1>"#), "o escopo vazou para fora do componente")
        #expect(!html.contains("<style>"), "o <style> ficou no meio da página: \(html.prefix(900))")
        #expect(html.contains(#"src="/@odete/arquivo/src/assets/ponto.png" width="3" height="2""#), "a imagem não virou metadata: \(html.prefix(900))")

        let (css, _) = try await pega(dev, "/@odete/css/@astro/")
        #expect(css.contains("margin: 3px"), "o CSS importado não veio: \(css)")
        #expect(css.contains("h1[\(cid)] { color: red; }"), "o <style> não ganhou escopo: \(css)")
        #expect(css.contains(".t[\(cid)]:hover, nav[\(cid)] > a[\(cid)]"), "seletor composto sem escopo: \(css)")
        #expect(css.contains("@media (min-width: 40rem) { h1[\(cid)]"), "o @media não foi escopado por dentro: \(css)")
        #expect(css.contains("from { opacity: 0; }"), "o @keyframes foi mexido: \(css)")
        #expect(css.contains(".solto { color: green; }"), "o :global não escapou: \(css)")
        #expect(css.contains(".global-mesmo { color: black; }"), "o is:global ganhou escopo: \(css)")

        let (_, ri) = try await pega(dev, "/@odete/arquivo/src/assets/ponto.png")
        #expect(ri?.statusCode == 200 && ri?.value(forHTTPHeaderField: "content-type") == "image/png")
    }

    /// Mudar só CSS — a folha importada ou o `<style>` do componente — troca a folha no
    /// Preview sem recarregar a página.
    @Test func soCSSTrocaAFolhaSemRecarregar() async throws {
        let raiz = try projeto([
            "src/styles/g.css": "body { margin: 1px; }",
            "src/pages/index.astro": """
            ---
            import "../styles/g.css";
            ---
            <html><body><p>oi</p></body></html>
            <style>p { color: red; }</style>
            """,
        ])
        let dev = try await sobe(raiz)
        defer { dev.stop() }
        _ = try await pega(dev, "/")
        let g = raiz.appending(path: "src/styles/g.css").path
        #expect(await ate { dev.arquivosVigiados.contains(g) }, "o CSS importado não entrou no grafo: \(dev.arquivosVigiados)")

        #expect(await dev.arquivosMudaram([g]) == .nada, "arquivo igual não pode mudar nada")
        try "body { margin: 9px; }".write(toFile: g, atomically: true, encoding: .utf8)
        #expect(await dev.arquivosMudaram([g]) == .css, "CSS importado recarregou a página")
        let (css, _) = try await pega(dev, "/@odete/css/@astro/")
        #expect(css.contains("margin: 9px"))

        let pagina = raiz.appending(path: "src/pages/index.astro")
        try """
        ---
        import "../styles/g.css";
        ---
        <html><body><p>oi</p></body></html>
        <style>p { color: blue; }</style>
        """.write(to: pagina, atomically: true, encoding: .utf8)
        #expect(await dev.arquivosMudaram([pagina.path]) == .css, "mudar só o <style> recarregou a página")
        let (css2, _) = try await pega(dev, "/@odete/css/@astro/")
        #expect(css2.contains("color: blue"))

        try """
        ---
        import "../styles/g.css";
        ---
        <html><body><p>tchau</p></body></html>
        <style>p { color: blue; }</style>
        """.write(to: pagina, atomically: true, encoding: .utf8)
        #expect(await dev.arquivosMudaram([pagina.path]) == .reload, "mudar o HTML não recarregou")
    }

    // MARK: - 9. Rotas

    /// `[slug].astro` com `getStaticPaths` (e as props de cada caminho), `[...resto]`, e o
    /// `Astro.url`/`Astro.params` de verdade — num componente também.
    @Test func rotasDinamicasComGetStaticPaths() async throws {
        let raiz = try projeto([
            "src/components/Onde.astro": "<i id=\"onde\">{Astro.url.pathname}</i>",
            "src/pages/produto/[slug].astro": """
            ---
            import Onde from "../../components/Onde.astro";
            export async function getStaticPaths() {
              return [
                { params: { slug: "caneca" }, props: { preco: 30 } },
                { params: { slug: "camisa" }, props: { preco: 80 } },
              ];
            }
            interface Props { preco: number }
            const { slug } = Astro.params;
            const { preco } = Astro.props as Props;
            ---
            <p id="p">{slug} custa {preco}</p><Onde />
            """,
            "src/pages/docs/[...resto].astro": """
            ---
            export const getStaticPaths = () => [
              { params: { resto: undefined } },
              { params: { resto: "guia/inicio" } },
            ];
            const { resto } = Astro.params;
            ---
            <p id="d">docs:{resto ?? "raiz"}</p>
            """,
            "src/pages/usuario/[id].astro": "<p id=\"u\">usuário {Astro.params.id}</p>",
            "src/pages/404.astro": "<h1>sumiu</h1>",
            "src/pages/index.astro": "<p>raiz</p>",
        ])
        let dev = try await sobe(raiz)
        defer { dev.stop() }

        let (a, ra) = try await pega(dev, "/produto/caneca")
        #expect(ra?.statusCode == 200)
        #expect(a.contains(#"<p id="p">caneca custa 30</p>"#), "\(a.prefix(500))")
        #expect(a.contains(#"<i id="onde">/produto/caneca</i>"#), "o Astro.url do componente é fixo: \(a.prefix(500))")
        #expect(try await pega(dev, "/produto/camisa").0.contains("camisa custa 80"))

        let (n, rn) = try await pega(dev, "/produto/outra")
        #expect(rn?.statusCode == 404, "caminho fora do getStaticPaths não é 404")
        #expect(n.contains("<h1>sumiu</h1>"), "o 404.astro não foi usado: \(n.prefix(300))")

        #expect(try await pega(dev, "/docs").0.contains("docs:raiz"))
        #expect(try await pega(dev, "/docs/guia/inicio").0.contains("docs:guia/inicio"))
        // Sem getStaticPaths, os params vêm da URL (rota de servidor).
        #expect(try await pega(dev, "/usuario/42").0.contains("usuário 42"))
        #expect(try await pega(dev, "/").0.contains("<p>raiz</p>"), "a rota literal parou de funcionar")
    }

    /// `src/pages/*.ts` e `.js` são endpoints: a função do método devolve a resposta.
    @Test func endpointsRespondemPorMetodo() async throws {
        let raiz = try projeto([
            "src/pages/api/[nome].ts": """
            import type { APIRoute } from "astro";
            export const GET: APIRoute = ({ params, url }) =>
              new Response(JSON.stringify({ oi: params.nome, q: url.searchParams.get("q") }), {
                headers: { "content-type": "application/json" },
              });
            export async function POST({ request }: { request: Request }) {
              const corpo = await request.json();
              return new Response("recebi " + corpo.x, { status: 201 });
            }
            """,
            "src/pages/feed.xml.js": """
            export function GET() {
              return new Response("<rss><channel><title>t</title></channel></rss>");
            }
            """,
            "src/pages/index.astro": "<p>raiz</p>",
        ])
        let dev = try await sobe(raiz)
        defer { dev.stop() }
        let (j, rj) = try await pega(dev, "/api/marcos?q=1")
        #expect(rj?.statusCode == 200, "\(j)")
        #expect(j.contains(#""oi":"marcos""#) && j.contains(#""q":"1""#), "\(j)")
        #expect(rj?.value(forHTTPHeaderField: "content-type")?.contains("json") == true)

        var req = URLRequest(url: URL(string: "/api/x", relativeTo: dev.url)!)
        req.httpMethod = "POST"
        req.httpBody = Data(#"{"x":7}"#.utf8)
        let (d, r) = try await URLSession.shared.data(for: req)
        #expect((r as? HTTPURLResponse)?.statusCode == 201)
        #expect(String(decoding: d, as: UTF8.self) == "recebi 7")

        let (x, rx) = try await pega(dev, "/feed.xml")
        #expect(rx?.statusCode == 200 && x.contains("<rss>"), "\(x)")
        #expect(rx?.value(forHTTPHeaderField: "content-type")?.contains("xml") == true)
    }

    /// `.md` em `src/pages` é página: Markdown vira HTML, e o `layout` do frontmatter
    /// embrulha com as props do Astro (`frontmatter`, `headings`).
    @Test func paginaMarkdownComLayout() async throws {
        let raiz = try projeto([
            "src/layouts/Post.astro": """
            ---
            const { frontmatter } = Astro.props;
            ---
            <html><head><title>{frontmatter.title}</title></head><body><article><slot /></article></body></html>
            """,
            "src/pages/post.md": """
            ---
            title: "Meu post"
            layout: ../layouts/Post.astro
            ---
            # Olá, *mundo*

            Um [link](https://astro.build) e `código`.

            - um
            - dois

            | a | b |
            | - | - |
            | 1 | 2 |
            """,
            "src/pages/solto.md": "## Sem layout\n\ntexto",
        ])
        let dev = try await sobe(raiz)
        defer { dev.stop() }
        let (html, r) = try await pega(dev, "/post")
        #expect(r?.statusCode == 200, "\(html.prefix(400))")
        #expect(html.contains("<title>Meu post</title>"), "o layout não recebeu o frontmatter: \(html.prefix(600))")
        #expect(html.contains(#"<h1 id="olá-mundo">Olá, <em>mundo</em></h1>"#), "\(html.prefix(900))")
        #expect(html.contains(#"<a href="https://astro.build">link</a>"#) && html.contains("<code>código</code>"))
        #expect(html.contains("<li>um</li>") && html.contains("<td>2</td>"))
        let (s, _) = try await pega(dev, "/solto")
        #expect(s.contains(#"<h2 id="sem-layout">Sem layout</h2>"#), "\(s.prefix(300))")
    }

    // MARK: - 10. Módulos .ts importados

    /// Editar um `.ts` que o frontmatter importa refaz a página — antes o `require` guardava
    /// o módulo para sempre.
    @Test func editarModuloTsImportadoRefaz() async throws {
        let raiz = try projeto([
            "src/config.ts": "export const NOME: string = \"primeiro\";",
            "src/pages/index.astro": """
            ---
            import { NOME } from "../config";
            ---
            <p id="n">{NOME}</p>
            """,
        ])
        let dev = try await sobe(raiz)
        defer { dev.stop() }
        #expect(try await pega(dev, "/").0.contains("<p id=\"n\">primeiro</p>"))
        let cfg = raiz.appending(path: "src/config.ts")
        #expect(await ate { dev.arquivosVigiados.contains(cfg.path) }, "o .ts importado não entrou no grafo")
        try "export const NOME: string = \"segundo\";".write(to: cfg, atomically: true, encoding: .utf8)
        #expect(await dev.arquivosMudaram([cfg.path]) == .reload)
        #expect(try await pega(dev, "/").0.contains("<p id=\"n\">segundo</p>"), "a página não viu o .ts novo")
    }

    /// As frases do Astro no motor passam pelo `tr()` do Swift (`Esbuild.textosDoMotor`), e
    /// o erro chega à página com a frase da tabela, preenchida.
    @Test func mensagensDoAstroSaoTraduzidas() async throws {
        let tabela = try #require(
            JSONSerialization.jsonObject(with: Data(Esbuild.textosDoMotor().utf8)) as? [String: String]
        )
        for k in ["astroSemZod", "astroColecaoNaoExiste", "astroLoaderProprio", "astroSchema", "astroConfigIlegivel"] {
            #expect(tabela[k]?.isEmpty == false, "falta a chave \(k)")
        }
        let raiz = try projeto([
            "src/pages/index.astro": """
            ---
            import { getCollection } from "astro:content";
            const posts = await getCollection("nada");
            ---
            <p>{posts.length}</p>
            """,
        ])
        let dev = try await sobe(raiz)
        defer { dev.stop() }
        let (html, r) = try await pega(dev, "/")
        #expect(r?.statusCode == 500)
        let esperado = try #require(tabela["astroColecaoNaoExiste"]).replacingOccurrences(of: "%1$@", with: "nada")
            .replacingOccurrences(of: "\"", with: "&quot;")
        #expect(html.contains(esperado) || html.contains(esperado.replacingOccurrences(of: "&quot;", with: "\"")),
                "a frase não veio da tabela: \(html.suffix(600))")
    }

    /// O resto do que os modelos usam: `class:list`, `set:html`, `<Fragment>`, slot com
    /// nome, `Astro.slots`, `import.meta.env` e o SVG importado como componente.
    @Test func diretivasSlotsEEnv() async throws {
        let raiz = try projeto([
            "src/components/Caixa.astro": """
            <section>
              <header><slot name="topo">sem topo</slot></header>
              <slot />
              {Astro.slots.has("rodape") ? <footer><slot name="rodape" /></footer> : <em>sem rodapé</em>}
            </section>
            """,
            "src/pages/index.astro": """
            ---
            import Caixa from "../components/Caixa.astro";
            import Logo from "../logo.svg";
            const ativo = true;
            const cru = "<b>forte</b>";
            ---
            <div id="c" class:list={["a", { b: ativo, c: false }, ["d"]]}></div>
            <div id="h" set:html={cru} />
            <Fragment set:html={cru} />
            <Caixa><span slot="topo">TOPO</span><p>meio</p></Caixa>
            <p id="modo">{import.meta.env.MODE}</p>
            <Logo width={10} />
            """,
            "src/logo.svg": #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 4 4"><rect width="4" height="4"/></svg>"#,
        ])
        let dev = try await sobe(raiz)
        defer { dev.stop() }
        let (html, _) = try await pega(dev, "/")
        #expect(html.contains(#"<div id="c" class="a b d"></div>"#), "\(html.prefix(800))")
        #expect(html.contains(#"<div id="h"><b>forte</b></div>"#))
        #expect(html.contains("<header><span>TOPO</span></header>"), "o slot com nome não foi: \(html.prefix(900))")
        #expect(html.contains("<p>meio</p>") && html.contains("<em>sem rodapé</em>"))
        #expect(html.contains(#"<p id="modo">development</p>"#))
        #expect(html.contains(#"<svg width="10" xmlns="http://www.w3.org/2000/svg""#), "o SVG não virou componente: \(html.prefix(1200))")
    }
}
