import Foundation
import OdeteBundler
import OdeteNpm
import Testing

/// Tailwind v4 e Sass no Next e no Astro, pelo pipeline de CSS do bundler (estilos.js e
/// tailwind.js), com os pacotes de verdade instalados. Sem rede, calam.
@MainActor
struct EstilosNextAstroTests {
    func projeto(_ arquivos: [String: String], pacote: String, instala: [String]) async throws -> URL? {
        let raiz = FileManager.default.temporaryDirectory
            .appending(path: "odete-estilos-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        for (caminho, corpo) in arquivos {
            let f = raiz.appending(path: caminho)
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try corpo.write(to: f, atomically: true, encoding: .utf8)
        }
        try pacote.write(to: raiz.appending(path: "package.json"), atomically: true, encoding: .utf8)
        guard let rep = try? await Installer(project: raiz, registry: HTTPRegistry())
            .install(add: instala.map { .init($0) }),
            !rep.installed.isEmpty
        else { return nil }
        return raiz
    }

    func pega(_ dev: DevServer, _ rota: String) async throws -> String {
        let (d, _) = try await URLSession.shared.data(from: URL(string: rota, relativeTo: dev.url)!)
        return String(decoding: d, as: UTF8.self)
    }

    /// O create-next-app com Tailwind v4: `@import "tailwindcss"` no globals.css vira as
    /// utilidades que a página usa, na folha da rota.
    @Test func createNextAppComTailwind() async throws {
        var arquivos = NextCompletoTests.createNextApp
        arquivos["app/globals.css"] = """
        @import "tailwindcss";

        :root {
          --background: #ffffff;
          --foreground: #171717;
        }

        @theme inline {
          --color-background: var(--background);
          --color-foreground: var(--foreground);
          --font-sans: var(--font-geist-sans);
        }

        body {
          background: var(--background);
          color: var(--foreground);
        }
        """
        arquivos["postcss.config.mjs"] = #"export default { plugins: { "@tailwindcss/postcss": {} } };"#
        guard let raiz = try await projeto(
            arquivos,
            pacote: #"{"name":"app","dependencies":{"next":"16.0.0","react":"19.2.0","react-dom":"19.2.0"}}"#,
            instala: ["react@19.2.0", "react-dom@19.2.0", "tailwindcss@^4.1.0"]
        ) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }
        let html = try await pega(dev, "/")
        #expect(html.contains("/@odete/css/@next/"), "\(html.prefix(500))")
        let css = try await pega(dev, "/@odete/css/@next/")
        #expect(!css.contains("@import \"tailwindcss\""), "o Tailwind não processou o globals.css")
        #expect(css.contains(".flex") && css.contains("display: flex"), "faltou a utilidade .flex: \(css.prefix(400))")
        #expect(css.contains(".bg-zinc-50"), "faltou .bg-zinc-50")
        #expect(css.contains(".max-w-3xl"), "faltou .max-w-3xl")
        #expect(css.contains("--background: #ffffff"))
    }

    /// Astro com Tailwind v4 e Sass: o global.css com `@import "tailwindcss"` importado no
    /// layout, `@apply` num `<style>` com `@reference`, e `<style lang="scss">` — todos com
    /// escopo. Uma classe nova no template aparece na folha depois de editar.
    @Test func astroComTailwindESass() async throws {
        guard let raiz = try await projeto(
            [
                "src/styles/global.css": "@import \"tailwindcss\";",
                "src/layouts/Base.astro": """
                ---
                import "../styles/global.css";
                ---
                <html><head><title>t</title></head><body><slot /></body></html>
                """,
                "src/components/Titulo.astro": """
                <h1>título</h1>
                <style>
                  @reference "../styles/global.css";
                  h1 { @apply text-red-500 font-bold; }
                </style>
                """,
                "src/pages/index.astro": """
                ---
                import Base from "../layouts/Base.astro";
                import Titulo from "../components/Titulo.astro";
                ---
                <Base><main class="flex p-4"><Titulo /><p>oi <span class="x">x</span></p></main></Base>
                <style lang="scss">
                  $cor: #123456;
                  p { color: $cor; .x { margin: 1px; } }
                </style>
                """,
            ],
            pacote: #"{"name":"site","type":"module","dependencies":{"astro":"^5.0.0"}}"#,
            instala: ["tailwindcss@^4.1.0", "sass@^1.80.0"]
        ) else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .astro)
        defer { dev.stop() }
        let html = try await pega(dev, "/")
        #expect(html.contains(#"class="flex p-4""#), "\(html.prefix(600))")
        var css = try await pega(dev, "/@odete/css/@astro/")
        #expect(
            css.contains(".flex") && css.contains(".p-4"),
            "o Tailwind do global.css não gerou as utilidades: \(css.prefix(500))"
        )
        #expect(css.contains("h1[data-astro-cid-"), "o <style> com @apply não ganhou escopo: \(css.suffix(800))")
        #expect(css.contains("--color-red-500") || css.contains("oklch"), "o @apply não virou CSS: \(css.suffix(800))")
        #expect(!css.contains("@apply"), "sobrou @apply cru")
        #expect(css.contains("color: #123456"), "o Sass não compilou: \(css.suffix(800))")
        #expect(
            css
                .range(
                    of: #"p\[data-astro-cid-[a-z0-9]+\] \.x\[data-astro-cid-[a-z0-9]+\]"#,
                    options: .regularExpression
                ) != nil,
            "o aninhamento do Sass não ganhou escopo: \(css.suffix(800))"
        )

        let pagina = raiz.appending(path: "src/pages/index.astro")
        let texto = try String(contentsOf: pagina, encoding: .utf8)
        try texto.replacingOccurrences(of: "flex p-4", with: "grid gap-7").write(
            to: pagina,
            atomically: true,
            encoding: .utf8
        )
        #expect(await dev.arquivosMudaram([pagina.path]) == .reload)
        _ = try await pega(dev, "/")
        css = try await pega(dev, "/@odete/css/@astro/")
        #expect(css.contains(".gap-7"), "a classe nova do template não entrou na folha")
    }
}
