import Foundation
@testable import OdeteBundler
import Testing

/// Tailwind v4 do jeito oficial — `tailwindcss` + `@tailwindcss/vite`, `plugins:
/// [react(), tailwindcss()]` e `@import "tailwindcss";` — no Preview e no `vite build`.
///
/// Os testes de encanamento usam um `tailwindcss` falso com a mesma API (`compile()` que
/// acumula candidatos): provam o que chega ao compilador — o CSS do pacote pela condição
/// `style`, os candidatos de cada arquivo, o que o .gitignore esconde, o `@source`. Os de
/// verdade copiam o pacote de um `node_modules` do Mac:
/// `TEST_RUNNER_ODETE_TAILWIND_DIR=<node_modules com tailwindcss e @tailwindcss/typography>`.
@Suite(.serialized) struct TailwindTests {
    static let temTailwind = ProcessInfo.processInfo.environment["ODETE_TAILWIND_DIR"].map { !$0.isEmpty } ?? false

    /// Um `compile()` que junta os `@import` pelo `loadStylesheet` e devolve uma regra por
    /// candidato que pareça classe. Acumula, como o de verdade.
    static let compileFalso = """
    exports.compile = async function (css, opts) {
      var base = "", m, re = /@import\\s+["']([^"']+)["'];?/g;
      while ((m = re.exec(css))) { var s = await opts.loadStylesheet(m[1], opts.base); base += s.content; }
      var fora = css.replace(re, "").replace(/@source[^;]*;/g, "");
      var vistos = new Set();
      globalThis.__twFalsoChamadas = (globalThis.__twFalsoChamadas || 0) + 1;
      return {
        root: null, sources: (css.match(/@source\\s+"([^"]+)"/g) || []).map(function (x) {
          return { base: opts.base, pattern: /"([^"]+)"/.exec(x)[1], negated: false };
        }), features: 16,
        build: function (novos) {
          novos.forEach(function (c) { if (/^(?:[a-z]+:)?(?:text|bg|p|m|flex|underline)(?:-|$)/.test(c)) vistos.add(c); });
          return base + Array.from(vistos).sort().map(function (c) {
            return "." + c.replace(/[^a-zA-Z0-9-]/g, function (x) { return "\\\\" + x; }) + " { --falso: 1; }";
          }).join("\\n") + "\\n" + fora;
        },
      };
    };
    """

    func projetoFalso() throws -> URL {
        let raiz = Apoio.raiz("tailwind-falso")
        try Apoio.pagina(raiz, entrada: "/src/main.tsx")
        try Apoio.grava(
            #"{"name":"app","type":"module","devDependencies":{"tailwindcss":"^4","@tailwindcss/vite":"^4"}}"#,
            raiz,
            "package.json"
        )
        try Apoio.pacote(raiz, "tailwindcss", #"""
        {"name":"tailwindcss","version":"4.9.9","style":"index.css",
         "exports":{".":{"types":"./dist/lib.d.mts","style":"./index.css","require":"./dist/lib.js","import":"./dist/lib.mjs"},"./package.json":"./package.json"}}
        """#, [
            "index.css": ".tw-index-falso { --origem: index-css; }\n",
            "dist/lib.js": Self.compileFalso,
            "dist/lib.mjs": "export const compile = null;\n",
        ])
        try Apoio.grava("node_modules\ndist\nescondido/\n", raiz, ".gitignore")
        try Apoio.grava("@import \"tailwindcss\";\n", raiz, "src/index.css")
        try Apoio.grava("""
        import "./index.css";
        import { App } from "./App";
        document.body.innerHTML = App();
        """, raiz, "src/main.tsx")
        try Apoio.grava(
            "export const App = () => `<div class=\"text-red-500 md:flex hover:underline bg-[#123456]\">oi</div>`;\n",
            raiz,
            "src/App.tsx"
        )
        // Fora do grafo do JS: o Tailwind lê, o esbuild não.
        try Apoio.grava("<p class=\"p-4\">conteúdo</p>\n", raiz, "conteudo/sobre.html")
        try Apoio.grava("export const x = 'bg-green-500';\n", raiz, "escondido/x.ts")
        return raiz
    }

    @Test func devServerGeraAsClassesDoProjeto() async throws {
        let raiz = try projetoFalso()
        let dev = DevServer(root: raiz)
        try await dev.start(port: Apoio.porta())
        defer { dev.stop() }
        let css = try await Apoio.texto(dev.url.appending(path: "@odete/css/src/main.tsx"))
        // O CSS do pacote veio pela condição `style` (o index.css, não o lib.js).
        #expect(css.contains(".tw-index-falso"), "\(css)")
        for classe in [#".text-red-500"#, #".md\:flex"#, #".hover\:underline"#, ##".bg-\[\#123456\]"##, #".p-4"#] {
            #expect(css.contains(classe), "faltou \(classe) em \(css)")
        }
        // O .gitignore esconde a pasta; node_modules nunca é varrido.
        #expect(!css.contains("bg-green-500"))
        #expect(!css.contains("@import"))
    }

    /// Editar um arquivo que só o Tailwind lê (fora do grafo do JS) refaz a folha e troca
    /// sem recarregar a página. E o compilador não é refeito: só os candidatos novos.
    @Test func arquivoSoDoTailwindTrocaAFolhaSemRecarregar() async throws {
        let raiz = try projetoFalso()
        let dev = DevServer(root: raiz)
        try await dev.start(port: Apoio.porta())
        defer { dev.stop() }
        _ = try await Apoio.texto(dev.url.appending(path: "@odete/css/src/main.tsx"))
        let sobre = raiz.appending(path: "conteudo/sobre.html").path
        #expect(await Apoio.ate { dev.arquivosVigiados.contains(sobre) }, "\(dev.arquivosVigiados)")
        try Apoio.grava("<p class=\"p-4 m-8\">conteúdo</p>\n", raiz, "conteudo/sobre.html")
        let trocou = await Apoio.ate { await dev.estatisticas()["css"] == 1 }
        let estatisticas = await dev.estatisticas()
        #expect(trocou, "\(estatisticas)")
        #expect(await dev.estatisticas()["reload"] == 0)
        let css = try await Apoio.texto(dev.url.appending(path: "@odete/css/src/main.tsx"))
        #expect(css.contains(".m-8"), "\(css)")
        let chamadas = try await dev.esbuild.engine.call("eval", ["globalThis.__twFalsoChamadas"])
        #expect(chamadas == "1", "o compilador foi refeito: \(chamadas)")
    }

    /// Arquivo novo numa pasta varrida entra na folha.
    @Test func arquivoNovoEntraNaFolha() async throws {
        let raiz = try projetoFalso()
        let dev = DevServer(root: raiz)
        try await dev.start(port: Apoio.porta())
        defer { dev.stop() }
        _ = try await Apoio.texto(dev.url.appending(path: "@odete/css/src/main.tsx"))
        try Apoio.grava("export const y = 'text-blue-700';\n", raiz, "src/novo.ts")
        _ = await dev.arquivosMudaram([], criados: [raiz.appending(path: "src/novo.ts").path])
        let css = try await Apoio.texto(dev.url.appending(path: "@odete/css/src/main.tsx"))
        #expect(css.contains(".text-blue-700"), "\(css)")
    }

    /// O guia do Tailwind com Vite liga a folha no HTML (`<link href="/src/style.css">`):
    /// ela passa pelo build, em vez de chegar crua com o `@import "tailwindcss"`.
    @Test func folhaLigadaNoHtml() async throws {
        let raiz = try projetoFalso()
        try Apoio.pagina(raiz, entrada: "/src/main.tsx", cabeca: #"<link href="/src/style.css" rel="stylesheet">"#)
        try Apoio.grava("@import \"tailwindcss\";\n", raiz, "src/style.css")
        let dev = DevServer(root: raiz)
        try await dev.start(port: Apoio.porta())
        defer { dev.stop() }
        let html = try await Apoio.texto(dev.url)
        #expect(html.contains("href=\"/@odete/css/src/style.css\""), "\(html)")
        let css = try await Apoio.texto(dev.url.appending(path: "@odete/css/src/style.css"))
        #expect(css.contains(#".md\:flex"#) && !css.contains("@import"), "\(css)")
        // E no `vite build` a folha ligada também sai processada.
        let (r, _, cssBuild) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(cssBuild.contains(#".md\:flex"#), "\(cssBuild)")
    }

    @Test func viteBuildGeraAsClasses() async throws {
        let raiz = try projetoFalso()
        let (r, _, css) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(css.contains(#".hover\:underline"#) && css.contains(".p-4"), "\(css)")
        #expect(!css.contains("bg-green-500"))
    }

    /// `@source` explícito entra mesmo se o .gitignore esconde.
    @Test func sourceExplicito() async throws {
        let raiz = try projetoFalso()
        try Apoio.grava("@import \"tailwindcss\";\n@source \"../escondido\";\n", raiz, "src/index.css")
        let (r, _, css) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(css.contains(".bg-green-500"), "\(css)")
    }

    /// O extrator de candidatos pega o que o Tailwind precisa, com colchete, aspas e `>`.
    @Test func extratorDeCandidatos() async throws {
        let raiz = try projetoFalso()
        let es = Esbuild(root: raiz)
        _ = try await es.ready()
        let jsx = #"""
        <div className={cn("text-red-500 md:flex", ativo && "hover:underline")} />
        <p className="content-['oi'] [&>*]:p-4 data-[state=open]:bg-red-500 w-[calc(100%-2rem)] bg-(--minha) *:p-2" />
        <i className={`!font-bold md:hover:bg-red-500/50 ${x ? "grid-cols-[1fr_2fr]" : "px-1.5"}`} />
        <img class=flex-1 src="/a.png" /><b class="bg-[url('/img.png')] [&[data-x='1']]:p-2 bg-[#123456]" />
        """#
        let json = try await es.engine.call("eval", ["JSON.stringify(globalThis.__odeteTailwind.candidatosDe(\(DevServer.comoLiteralJS(jsx))))"])
        let lista = try JSONDecoder().decode(String.self, from: Data(json.utf8))
        let achados = try Set(JSONDecoder().decode([String].self, from: Data(lista.utf8)))
        for c in ["text-red-500", "md:flex", "hover:underline", "content-['oi']", "[&>*]:p-4", "data-[state=open]:bg-red-500",
                  "w-[calc(100%-2rem)]", "bg-(--minha)", "*:p-2", "!font-bold", "md:hover:bg-red-500/50", "grid-cols-[1fr_2fr]",
                  "px-1.5", "flex-1", "bg-[url('/img.png')]", "[&[data-x='1']]:p-2", "bg-[#123456]"]
        {
            #expect(achados.contains(c), "faltou \(c)")
        }
    }

    // MARK: - Tailwind de verdade

    /// O template oficial: Vite + React + `tailwindcss` + `@tailwindcss/vite`.
    func projetoOficial() throws -> URL? {
        let raiz = Apoio.raiz("tailwind-oficial")
        guard try Apoio.copiaPacotes("ODETE_TAILWIND_DIR", ["tailwindcss"], para: raiz) else { return nil }
        // O plugin do Vite fica instalado como no projeto de verdade; ele não roda aqui.
        _ = try? Apoio.copiaPacotes("ODETE_TAILWIND_DIR", ["@tailwindcss/vite"], para: raiz)
        try Apoio.pagina(raiz, entrada: "/src/main.tsx")
        try Apoio.grava(#"""
        {"name":"app","private":true,"type":"module",
         "devDependencies":{"@tailwindcss/vite":"^4.3.3","@vitejs/plugin-react":"^5.0.0","tailwindcss":"^4.3.3","vite":"^7.1.0"}}
        """#, raiz, "package.json")
        try Apoio.grava("""
        import { defineConfig } from 'vite'
        import react from '@vitejs/plugin-react'
        import tailwindcss from '@tailwindcss/vite'

        export default defineConfig({
          plugins: [react(), tailwindcss()],
        })
        """, raiz, "vite.config.ts")
        try Apoio.grava("node_modules\ndist\n*.local\n", raiz, ".gitignore")
        try Apoio.grava("""
        @import "tailwindcss";

        @theme {
          --color-marca: #0a7cff;
        }

        .botao {
          @apply rounded-lg px-4 py-2 hover:bg-red-500 md:p-8;
        }
        """, raiz, "src/index.css")
        try Apoio.grava("""
        import "./index.css";
        import { App } from "./App";
        document.getElementById("root")!.innerHTML = App();
        """, raiz, "src/main.tsx")
        try Apoio.grava("""
        export function App() {
          return `<div class="text-red-500 md:flex hover:underline bg-[#123456] text-marca">
            <button class="botao">oi</button>
          </div>`;
        }
        """, raiz, "src/App.tsx")
        return raiz
    }

    @Test(.enabled(if: temTailwind)) func tailwindDeVerdadeNoPreview() async throws {
        guard let raiz = try projetoOficial() else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: Apoio.porta())
        defer { dev.stop() }
        let inicio = ContinuousClock.now
        let css = try await Apoio.texto(dev.url.appending(path: "@odete/css/src/main.tsx"))
        let primeira = ContinuousClock.now - inicio
        let medidaInicial = try await dev.esbuild.engine.call("eval", ["JSON.stringify(globalThis.__odeteTailwind.medicoes)"])
        for classe in [#".text-red-500"#, #".md\:flex"#, #".hover\:underline"#, ##".bg-\[\#123456\]"##, #".text-marca"#] {
            #expect(css.contains(classe), "faltou \(classe)")
        }
        #expect(css.contains("--color-red-500") && css.contains("#0a7cff"))
        // O `@apply` virou declarações, com a variante.
        #expect(css.contains(".botao") && css.contains("padding-inline") && !css.contains("@apply"))
        #expect(css.contains("@layer") && !css.contains("@import \"tailwindcss\""))

        // Edição com classe nova no componente: o JS muda (recarrega) e a folha já vem com ela.
        let tsx = raiz.appending(path: "src/App.tsx")
        let texto = try String(contentsOf: tsx, encoding: .utf8).replacingOccurrences(of: "text-marca", with: "text-marca underline-offset-8")
        try texto.write(to: tsx, atomically: true, encoding: .utf8)
        let t0 = ContinuousClock.now
        _ = await dev.arquivosMudaram([tsx.path])
        let edicao = ContinuousClock.now - t0
        let depois = try await Apoio.texto(dev.url.appending(path: "@odete/css/src/main.tsx"))
        #expect(depois.contains(".underline-offset-8"))
        let m = try await dev.esbuild.engine.call("eval", ["JSON.stringify(globalThis.__odeteTailwind.medicoes.ultima)"])
        print("[medida] tailwind no Preview: primeiro pedido de CSS (bundle inteiro) \(primeira) \(medidaInicial); edição com classe nova (rebuild inteiro) \(edicao), geração \(m)")
    }

    @Test(.enabled(if: temTailwind)) func tailwindDeVerdadeNoViteBuild() async throws {
        guard let raiz = try projetoOficial() else { return }
        let inicio = ContinuousClock.now
        let (r, _, css) = try await Apoio.viteBuild(raiz)
        print("[medida] vite build com tailwind: \(ContinuousClock.now - inicio), CSS \(css.utf8.count) bytes")
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        for classe in [#".text-red-500"#, #".md\:flex"#, #".hover\:underline"#, ##".bg-\[\#123456\]"##, #".text-marca"#] {
            #expect(css.contains(classe), "faltou \(classe)")
        }
        // Minificado pelo esbuild, e sem CSS aninhado (o `@apply hover:` escreve `&:hover`).
        #expect(!css.contains("\n  ") && !css.contains("&:hover"), "\(css.prefix(600))")
        #expect(css.contains(".botao:hover"))
    }

    /// Tailwind 3: `tailwind.config.js` + PostCSS, com `@tailwind base/components/utilities`.
    /// `TEST_RUNNER_ODETE_TAILWIND3_DIR=<node_modules de um npm i tailwindcss@3 postcss>`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ODETE_TAILWIND3_DIR"] != nil))
    func tailwind3DeVerdade() async throws {
        let raiz = Apoio.raiz("tailwind3")
        let origem = try #require(ProcessInfo.processInfo.environment["ODETE_TAILWIND3_DIR"])
        let nomes = try FileManager.default.contentsOfDirectory(atPath: origem).filter { !$0.hasPrefix(".") }
        #expect(try Apoio.copiaPacotes("ODETE_TAILWIND3_DIR", nomes, para: raiz))
        try Apoio.pagina(raiz, entrada: "/src/main.tsx")
        try Apoio.grava(#"{"name":"app","type":"module","devDependencies":{"tailwindcss":"^3.4.0","postcss":"^8"}}"#, raiz, "package.json")
        try Apoio.grava("""
        /** @type {import('tailwindcss').Config} */
        export default {
          content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
          theme: { extend: { colors: { marca: "#0a7cff" } } },
          plugins: [],
        }
        """, raiz, "tailwind.config.js")
        try Apoio.grava("export default { plugins: { tailwindcss: {}, autoprefixer: {} } }\n", raiz, "postcss.config.js")
        try Apoio.grava("@tailwind base;\n@tailwind components;\n@tailwind utilities;\n.botao { @apply px-4 hover:underline; }\n", raiz, "src/index.css")
        try Apoio.grava("import \"./index.css\";\n(globalThis as any).__r = `<p class=\"text-red-500 md:flex bg-[#123456] text-marca\">`;\n", raiz, "src/main.tsx")
        let inicio = ContinuousClock.now
        let (r, _, css) = try await Apoio.viteBuild(raiz)
        print("[medida] vite build com tailwind 3: \(ContinuousClock.now - inicio)")
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        for classe in [#".text-red-500"#, #".md\:flex"#, ##".bg-\[\#123456\]"##, #".text-marca"#, ".botao:hover"] {
            #expect(css.contains(classe), "faltou \(classe)")
        }
        #expect(!css.contains("@tailwind"))
    }

    /// `@plugin` com um plugin JS de verdade (o typography), carregado pelo esbuild.
    @Test(.enabled(if: temTailwind)) func pluginDeVerdade() async throws {
        guard let raiz = try projetoOficial() else { return }
        guard try Apoio.copiaPacotes("ODETE_TAILWIND_DIR", ["@tailwindcss/typography", "postcss-selector-parser", "cssesc", "util-deprecate"], para: raiz)
        else { return }
        try Apoio.grava("@import \"tailwindcss\";\n@plugin \"@tailwindcss/typography\";\n", raiz, "src/index.css")
        try Apoio.grava("export function App() { return `<article class=\"prose lg:prose-xl\">x</article>`; }\n", raiz, "src/App.tsx")
        let (r, _, css) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(css.contains(".prose"), "\(css.prefix(400))")
    }
}
