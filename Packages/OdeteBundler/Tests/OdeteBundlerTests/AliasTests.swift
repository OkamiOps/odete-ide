import Foundation
@testable import OdeteBundler
import Testing

/// `@/` e companhia. Antes o alias não existia: no dev server o import virava externo (o
/// navegador pedia `@/lib/utils` e parava) e no build aparecia "Rode npm install".
@Suite(.serialized) struct AliasTests {
    /// Como o template do Vite com o shadcn: o tsconfig.json só com `references`, as opções
    /// no tsconfig.app.json (com comentário e vírgula sobrando, como o TypeScript aceita) e
    /// um `extends`.
    func projetoComTsconfig() throws -> URL {
        let raiz = Apoio.raiz("alias-ts")
        try Apoio.pagina(raiz, entrada: "/src/main.tsx")
        try Apoio.grava(#"{"name":"app","type":"module"}"#, raiz, "package.json")
        try Apoio.grava(
            #"{ "files": [], "references": [{ "path": "./tsconfig.app.json" }, { "path": "./tsconfig.node.json" }] }"#,
            raiz,
            "tsconfig.json"
        )
        try Apoio.grava("""
        {
          // as opções do app
          "extends": "./tsconfig.base.json",
          "compilerOptions": {
            "jsx": "react-jsx", /* o shadcn pede isto: */
            "paths": { "@/*": ["./src/*"], },
          },
          "include": ["src"],
        }
        """, raiz, "tsconfig.app.json")
        try Apoio.grava(#"{ "compilerOptions": { "strict": true } }"#, raiz, "tsconfig.base.json")
        try Apoio.grava(#"{ "compilerOptions": {}, "include": ["vite.config.ts"] }"#, raiz, "tsconfig.node.json")
        try Apoio.grava("export const cn = (...a: string[]) => a.join(' ') + ' cn-ok';\n", raiz, "src/lib/utils.ts")
        try Apoio.grava(
            "import { cn } from \"@/lib/utils\";\nexport const Botao = () => cn('a', 'b');\n",
            raiz,
            "src/components/ui/botao.ts"
        )
        try Apoio.grava(
            "import { Botao } from \"@/components/ui/botao\";\n(globalThis as any).__r = Botao();\n",
            raiz,
            "src/main.tsx"
        )
        return raiz
    }

    @Test func pathsDoTsconfigComReferencesNoBuild() async throws {
        let raiz = try projetoComTsconfig()
        let (r, js, _) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(Apoio.roda(js).valor == "a b cn-ok")
    }

    @Test func pathsDoTsconfigNoDevServer() async throws {
        let raiz = try projetoComTsconfig()
        let dev = DevServer(root: raiz)
        try await dev.start(port: Apoio.porta())
        defer { dev.stop() }
        let js = try await Apoio.texto(dev.url.appending(path: "@odete/js/src/main.tsx"))
        #expect(js.contains("cn-ok"), "o alias ficou de fora do bundle: \(js.prefix(300))")
        #expect(!js.contains("from \"@/"), "o alias virou import externo")
    }

    /// O `resolve.alias` do vite.config: objeto, com os dois jeitos comuns de escrever a pasta.
    @Test func aliasDoViteConfigObjeto() async throws {
        let raiz = Apoio.raiz("alias-vite")
        try Apoio.pagina(raiz)
        try Apoio.grava(#"{"name":"app","type":"module"}"#, raiz, "package.json")
        try Apoio.grava("""
        import path from "path";
        import { fileURLToPath, URL } from "node:url";
        import { defineConfig } from "vite";
        import react from "@vitejs/plugin-react";

        // alias: { "@": "/nao/isto" }
        export default defineConfig({
          plugins: [react()],
          resolve: {
            alias: {
              "@": fileURLToPath(new URL("./src", import.meta.url)),
              "~util": path.resolve(__dirname, "./src/util"),
            },
          },
        });
        """, raiz, "vite.config.ts")
        try Apoio.grava("export const a = 'A';\n", raiz, "src/lib/a.ts")
        try Apoio.grava("export const b = 'B';\n", raiz, "src/util/index.ts")
        try Apoio.grava(
            "import { a } from \"@/lib/a\";\nimport { b } from \"~util\";\n(globalThis as any).__r = a + b;\n",
            raiz,
            "src/main.ts"
        )
        let (r, js, _) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(Apoio.roda(js).valor == "AB")
    }

    /// A lista de `{ find, replacement }`, com `find` em expressão regular.
    @Test func aliasDoViteConfigLista() async throws {
        let raiz = Apoio.raiz("alias-lista")
        try Apoio.pagina(raiz)
        try Apoio.grava(#"{"name":"app","type":"module"}"#, raiz, "package.json")
        try Apoio.grava("""
        import { resolve } from "path";
        export default {
          resolve: {
            alias: [
              { find: "#comp", replacement: resolve(__dirname, "src/componentes") },
              { find: /^~\\//, replacement: `${__dirname}/src/` },
            ],
          },
        };
        """, raiz, "vite.config.js")
        try Apoio.grava("export const c = 'C';\n", raiz, "src/componentes/c.ts")
        try Apoio.grava("export const d = 'D';\n", raiz, "src/d.ts")
        try Apoio.grava(
            "import { c } from \"#comp/c\";\nimport { d } from \"~/d\";\n(globalThis as any).__r = c + d;\n",
            raiz,
            "src/main.ts"
        )
        let (r, js, _) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(Apoio.roda(js).valor == "CD")
    }

    /// `baseUrl` sozinho: `import "components/x"` é o src/components/x.
    @Test func baseUrlDoTsconfig() async throws {
        let raiz = Apoio.raiz("alias-base")
        try Apoio.pagina(raiz)
        try Apoio.grava(#"{"name":"app"}"#, raiz, "package.json")
        try Apoio.grava(#"{ "compilerOptions": { "baseUrl": "src" } }"#, raiz, "tsconfig.json")
        try Apoio.grava("export const x = 'X';\n", raiz, "src/components/x.ts")
        try Apoio.grava(
            "import { x } from \"components/x\";\n(globalThis as any).__r = x;\n",
            raiz,
            "src/main.ts"
        )
        let (r, js, _) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(Apoio.roda(js).valor == "X")
    }

    /// Alias para um arquivo que não existe: o erro fala do alias e de onde ele aponta, não
    /// manda instalar um pacote.
    @Test func aliasQuebradoDizOndeApontava() async throws {
        let raiz = try projetoComTsconfig()
        try Apoio.grava("import { z } from \"@/nao/existe\";\n(globalThis as any).__r = z;\n", raiz, "src/main.tsx")
        let r = try await ViteBuild.rodar(raiz: raiz, esbuild: Esbuild(root: raiz))
        #expect(!r.ok)
        let texto = r.diagnosticos.map(\.text).joined(separator: "\n")
        #expect(texto.contains("@/nao/existe") && texto.contains("src/nao/existe"), "\(texto)")
        #expect(!texto.contains("npm install"), "\(texto)")
    }

    /// O `paths` do tsconfig não desvia import de dentro de pacote: um `"*"` que pega tudo
    /// não pode trocar o que um pacote importa.
    @Test func pathsNaoValeDentroDePacote() async throws {
        let raiz = Apoio.raiz("alias-pacote")
        try Apoio.pagina(raiz)
        try Apoio.grava(#"{"name":"app"}"#, raiz, "package.json")
        try Apoio.grava(#"{ "compilerOptions": { "paths": { "*": ["./src/tipos/*"] } } }"#, raiz, "tsconfig.json")
        try Apoio.pacote(raiz, "p", #"{"name":"p","main":"index.js"}"#, [
            "index.js": "import q from 'q';\nexport default 'p' + q;\n",
        ])
        try Apoio.pacote(raiz, "q", #"{"name":"q","main":"index.js"}"#, ["index.js": "export default 'q';\n"])
        try Apoio.grava("export default 'tipo-q';\n", raiz, "src/tipos/q.ts")
        try Apoio.grava("import p from \"p\";\n(globalThis as any).__r = p;\n", raiz, "src/main.ts")
        let (r, js, _) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(Apoio.roda(js).valor == "pq")
    }
}
