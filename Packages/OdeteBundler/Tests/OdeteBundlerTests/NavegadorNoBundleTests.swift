import Foundation
@testable import OdeteBundler
import Testing

/// O bundle do navegador pega a versão de navegador dos pacotes. Antes o dev server e o
/// `vite build` resolviam como o Node: o axios entrava como `dist/node` e o uuid como
/// `dist/cjs`, com `require("http")` e `require("crypto")` dentro, e a página ficava branca
/// com "Dynamic require of … is not supported".
@Suite(.serialized) struct NavegadorNoBundleTests {
    /// Um axios e um uuid com o formato dos de verdade: a versão de Node puxa módulo do
    /// Node, a de navegador não.
    func projeto() throws -> URL {
        let raiz = Apoio.raiz("navegador")
        try Apoio.pagina(raiz)
        try Apoio.grava(
            #"{"name":"app","type":"module","dependencies":{"axios":"^1.7.0","uuid":"^9.0.0"}}"#,
            raiz,
            "package.json"
        )
        try Apoio.pacote(raiz, "axios", #"""
        {"name":"axios","type":"module","main":"index.js",
         "exports":{".":{"browser":{"require":"./dist/browser/axios.cjs","default":"./index.js"},
                         "default":{"require":"./dist/node/axios.cjs","default":"./index.js"}}},
         "browser":{"./lib/adapters/http.js":"./lib/helpers/null.js"}}
        """#, [
            "index.js": "import http from './lib/adapters/http.js';\nexport default { onde: 'navegador', adaptador: http };\n",
            "lib/adapters/http.js": "import http from 'http';\nexport default http.request;\n",
            "lib/helpers/null.js": "export default null;\n",
            "dist/node/axios.cjs": "const http = require('http');\nmodule.exports = { onde: 'node', http };\n",
            "dist/browser/axios.cjs": "module.exports = { onde: 'navegador-cjs' };\n",
        ])
        try Apoio.pacote(raiz, "uuid", #"""
        {"name":"uuid","exports":{".":{
          "node":{"module":"./dist/esm-node/index.js","require":"./dist/cjs/index.js","import":"./wrapper.mjs"},
          "browser":{"import":"./dist/esm-browser/index.js","require":"./dist/cjs-browser/index.js"},
          "default":"./dist/esm-browser/index.js"}}}
        """#, [
            "dist/cjs/index.js": "const c = require('crypto');\nexports.v4 = () => c.randomUUID();\n",
            "dist/esm-node/index.js": "import c from 'crypto';\nexport const v4 = () => c.randomUUID();\n",
            "wrapper.mjs": "export { v4 } from './dist/cjs/index.js';\n",
            "dist/esm-browser/index.js": "export const v4 = () => 'uuid-do-navegador';\n",
            "dist/cjs-browser/index.js": "exports.v4 = () => 'uuid-do-navegador-cjs';\n",
        ])
        try Apoio.grava("""
        import axios from "axios";
        import { v4 } from "uuid";
        import fs from "fs";
        (globalThis as any).__r = axios.onde + ":" + String(axios.adaptador) + ":" + v4() + ":" + typeof fs;
        """, raiz, "src/main.ts")
        return raiz
    }

    @Test func viteBuildLevaAVersaoDoNavegador() async throws {
        let raiz = try projeto()
        let (r, js, _) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(!js.contains("randomUUID") && !js.contains("Dynamic require"), "entrou a versão de Node")
        let rodou = Apoio.roda(js)
        #expect(rodou.erro == nil, "\(rodou.erro ?? "")")
        #expect(rodou.valor == "navegador:null:uuid-do-navegador:object")
        // O `fs` do app virou módulo vazio, e o build diz isso, como o Vite.
        #expect(r.diagnosticos.contains { $0.kind == .warning && $0.text.contains("\"fs\"") })
    }

    /// No dev server os pacotes vêm do pacote de dependências — o mesmo resolvedor vale lá.
    @Test func devServerPreEmpacotaAVersaoDoNavegador() async throws {
        let raiz = try projeto()
        let dev = DevServer(root: raiz)
        try await dev.start(port: Apoio.porta())
        defer { dev.stop() }
        let app = try await Apoio.texto(dev.url.appending(path: "@odete/js/src/main.ts"))
        let deps = try await Apoio.texto(dev.url.appending(path: "@odete/deps.js"))
        #expect(deps.contains("uuid-do-navegador") && !deps.contains("randomUUID"), "\(deps.prefix(400))")
        #expect(deps.contains("navegador") && !deps.contains("require(\"http\")") && !deps.contains("__require(\"http\")"))
        // O `fs` do app: módulo vazio que avisa no console quem o usar.
        #expect(app.contains("new Proxy") && !app.contains("__require(\"fs\")"))
    }

    /// `import "node:path"` no código do navegador também vira o módulo vazio — antes ia
    /// externo e o navegador parava em "node:path does not resolve".
    @Test func prefixoNodeNoNavegador() async throws {
        let raiz = Apoio.raiz("navegador-node")
        try Apoio.pagina(raiz)
        try Apoio.grava(#"{"name":"app"}"#, raiz, "package.json")
        try Apoio.grava(
            "import * as p from \"node:path\";\n(globalThis as any).__r = typeof p;\n",
            raiz,
            "src/main.ts"
        )
        let (r, js, _) = try await Apoio.viteBuild(raiz)
        #expect(r.ok, "\(r.diagnosticos.map(\.text))")
        #expect(Apoio.roda(js).valor == "object")
    }
}
