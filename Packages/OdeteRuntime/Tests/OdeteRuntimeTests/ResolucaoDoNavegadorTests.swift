import Foundation
@testable import OdeteRuntime
import Testing

/// A resolução que o bundle do navegador usa (dev server e `vite build`). A do Node pegava
/// `dist/node` do axios e `dist/cjs` do uuid, e a página ficava branca com "Dynamic require
/// of http is not supported".
struct ResolucaoDoNavegadorTests {
    func projeto() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(
            path: "odete-navegador-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: u.appending(path: "src"), withIntermediateDirectories: true)
        try grava(#"{"name":"app","type":"module"}"#, u, "package.json")
        try grava("", u, "src/main.ts")
        return u
    }

    func grava(_ texto: String, _ raiz: URL, _ caminho: String) throws {
        let u = raiz.appending(path: caminho)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try texto.write(to: u, atomically: true, encoding: .utf8)
    }

    func resolve(
        _ spec: String,
        de: URL,
        _ modo: ResolucaoDoNavegador.Modo = .importacao
    ) -> ResolucaoDoNavegador.Achado? {
        ResolucaoDoNavegador.resolver(spec, from: de.path, modo: modo)
    }

    func arquivo(_ raiz: URL, _ rel: String) -> ResolucaoDoNavegador.Achado {
        .arquivo(raiz.appending(path: rel).path)
    }

    /// O `exports` do axios: `browser` antes de `default`, com `require` e `default`
    /// dentro. E o mapa `browser` do package.json troca o adaptador http pelo nulo — que
    /// é importado por caminho relativo, de dentro do pacote.
    @Test func axiosPegaAVersaoDoNavegadorEOMapaBrowser() throws {
        let raiz = try projeto()
        try grava(#"""
        {"name":"axios","type":"module","main":"index.js",
         "exports":{".":{"types":"./index.d.ts",
           "browser":{"require":"./dist/browser/axios.cjs","default":"./index.js"},
           "default":{"require":"./dist/node/axios.cjs","default":"./index.js"}}},
         "browser":{"./lib/adapters/http.js":"./lib/helpers/null.js","./lib/platform/node/index.js":"./lib/platform/browser/index.js"}}
        """#, raiz, "node_modules/axios/package.json")
        for f in ["index.js", "dist/browser/axios.cjs", "dist/node/axios.cjs", "lib/adapters/http.js",
                  "lib/adapters/adapters.js", "lib/helpers/null.js", "lib/platform/node/index.js",
                  "lib/platform/browser/index.js"]
        {
            try grava("export default 1;", raiz, "node_modules/axios/" + f)
        }
        let main = raiz.appending(path: "src/main.ts")
        #expect(resolve("axios", de: main) == arquivo(raiz, "node_modules/axios/index.js"))
        #expect(resolve("axios", de: main, .require) == arquivo(raiz, "node_modules/axios/dist/browser/axios.cjs"))
        let adapters = raiz.appending(path: "node_modules/axios/lib/adapters/adapters.js")
        #expect(resolve("./http.js", de: adapters) == arquivo(raiz, "node_modules/axios/lib/helpers/null.js"))
        // Sem extensão também: a chave do mapa vale para o arquivo que ela resolveria.
        #expect(resolve("../platform/node/index", de: adapters)
            == arquivo(raiz, "node_modules/axios/lib/platform/browser/index.js"))
        // O Node continua como era.
        #expect(ModuleLoader.resolveModule("axios", from: main.path)?.hasSuffix("dist/node/axios.cjs") == true)
    }

    /// O uuid: `node` primeiro no objeto, e `browser` com `import`/`require` dentro.
    @Test func uuidPegaOBuildDoNavegador() throws {
        let raiz = try projeto()
        try grava(#"""
        {"name":"uuid","exports":{".":{
          "node":{"module":"./dist/esm-node/index.js","require":"./dist/cjs/index.js","import":"./wrapper.mjs"},
          "browser":{"import":"./dist/esm-browser/index.js","require":"./dist/cjs-browser/index.js"},
          "default":"./dist/esm-browser/index.js"}}}
        """#, raiz, "node_modules/uuid/package.json")
        for f in ["dist/esm-node/index.js", "dist/cjs/index.js", "wrapper.mjs", "dist/esm-browser/index.js",
                  "dist/cjs-browser/index.js"]
        {
            try grava("", raiz, "node_modules/uuid/" + f)
        }
        let main = raiz.appending(path: "src/main.ts")
        #expect(resolve("uuid", de: main) == arquivo(raiz, "node_modules/uuid/dist/esm-browser/index.js"))
        #expect(resolve("uuid", de: main, .require) == arquivo(raiz, "node_modules/uuid/dist/cjs-browser/index.js"))
    }

    /// Sem `exports`: `browser` (texto) ganha de `module`, que ganha de `main`.
    @Test func camposBrowserModuleMain() throws {
        let raiz = try projeto()
        try grava(#"{"name":"a","main":"node.js","module":"esm.js","browser":"navegador.js"}"#, raiz, "node_modules/a/package.json")
        try grava(#"{"name":"b","main":"node.js","module":"esm.js"}"#, raiz, "node_modules/b/package.json")
        for p in ["a", "b"] {
            for f in ["node.js", "esm.js", "navegador.js"] {
                try grava("", raiz, "node_modules/\(p)/\(f)")
            }
        }
        let main = raiz.appending(path: "src/main.ts")
        #expect(resolve("a", de: main) == arquivo(raiz, "node_modules/a/navegador.js"))
        #expect(resolve("b", de: main) == arquivo(raiz, "node_modules/b/esm.js"))
    }

    /// `false` no mapa `browser` apaga o módulo: de caminho e de nome de pacote.
    @Test func browserFalseViraVazio() throws {
        let raiz = try projeto()
        try grava(
            #"{"name":"c","main":"index.js","browser":{"./servidor.js":false,"fs":false,"ws":"./ws-navegador.js"}}"#,
            raiz,
            "node_modules/c/package.json"
        )
        for f in ["index.js", "servidor.js", "ws-navegador.js"] {
            try grava("", raiz, "node_modules/c/" + f)
        }
        let index = raiz.appending(path: "node_modules/c/index.js")
        #expect(resolve("./servidor.js", de: index) == .vazio)
        #expect(resolve("fs", de: index) == .vazio)
        #expect(resolve("ws", de: index) == arquivo(raiz, "node_modules/c/ws-navegador.js"))
    }

    /// Módulo do Node sem pacote instalado volta como `embutido`; com pacote (o `buffer` do
    /// npm), o pacote ganha.
    @Test func modulosDoNode() throws {
        let raiz = try projeto()
        try grava(#"{"name":"buffer","main":"index.js"}"#, raiz, "node_modules/buffer/package.json")
        try grava("", raiz, "node_modules/buffer/index.js")
        let main = raiz.appending(path: "src/main.ts")
        #expect(resolve("fs", de: main) == .embutido("fs"))
        #expect(resolve("node:path", de: main) == .embutido("path"))
        #expect(resolve("crypto", de: main) == .embutido("crypto"))
        #expect(resolve("buffer", de: main) == arquivo(raiz, "node_modules/buffer/index.js"))
        #expect(resolve("nao-existe", de: main) == nil)
    }

    /// `@import "tailwindcss"` é o index.css do pacote (condição `style`), não o `lib.js`; e
    /// `@import "./base"` num CSS é o `base.css`.
    @Test func estiloPelaCondicaoStyle() throws {
        let raiz = try projeto()
        try grava(#"""
        {"name":"tailwindcss","style":"index.css","exports":{".":{"types":"./dist/lib.d.mts","style":"./index.css","require":"./dist/lib.js","import":"./dist/lib.mjs"},"./preflight":"./preflight.css"}}
        """#, raiz, "node_modules/tailwindcss/package.json")
        for f in ["index.css", "preflight.css", "dist/lib.js", "dist/lib.mjs"] {
            try grava("", raiz, "node_modules/tailwindcss/" + f)
        }
        try grava("", raiz, "src/base.css")
        let css = raiz.appending(path: "src/index.css")
        #expect(resolve("tailwindcss", de: css, .estilo) == arquivo(raiz, "node_modules/tailwindcss/index.css"))
        #expect(resolve("tailwindcss/preflight", de: css, .estilo)
            == arquivo(raiz, "node_modules/tailwindcss/preflight.css"))
        #expect(resolve("./base", de: css, .estilo) == arquivo(raiz, "src/base.css"))
        #expect(resolve("tailwindcss", de: css) == arquivo(raiz, "node_modules/tailwindcss/dist/lib.mjs"))
    }

    /// `#interno` pelo `imports` do package.json, com as condições do navegador.
    @Test func importsDoPacote() throws {
        let raiz = try projeto()
        try grava(
            ##"{"name":"d","main":"index.js","imports":{"#cripto":{"browser":"./cripto-navegador.js","node":"./cripto-node.js"},"#util/*":"./util/*.js"}}"##,
            raiz,
            "node_modules/d/package.json"
        )
        for f in ["index.js", "cripto-navegador.js", "cripto-node.js", "util/x.js"] {
            try grava("", raiz, "node_modules/d/" + f)
        }
        let index = raiz.appending(path: "node_modules/d/index.js")
        #expect(resolve("#cripto", de: index) == arquivo(raiz, "node_modules/d/cripto-navegador.js"))
        #expect(resolve("#util/x", de: index) == arquivo(raiz, "node_modules/d/util/x.js"))
    }

    /// O caminho volta limpo (sem `./` no meio) e sem mexer em `/private`: é o mesmo que o
    /// observador e o metafile usam.
    @Test func caminhoNormalizadoPeloTexto() {
        #expect(ResolucaoDoNavegador.normaliza("/a/./b/../c/x.js") == "/a/c/x.js")
        #expect(ResolucaoDoNavegador.normaliza("/private/var/x/./y") == "/private/var/x/y")
    }
}
