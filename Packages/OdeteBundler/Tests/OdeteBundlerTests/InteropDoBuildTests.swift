import Foundation
import JavaScriptCore
@testable import OdeteBundler
import Testing

/// O `vite build` e o dev server dão o mesmo valor ao mesmo import de pacote.
///
/// O dev server põe uma fachada ESM na frente de cada pacote (bundler.js), e o `default`
/// de um CommonJS segue o `__esModule`, como no Vite: `exports.default` num pacote que o
/// Babel ou o TypeScript compilaram, `module.exports` num CommonJS puro, o default de
/// verdade num pacote ESM. Sem a mesma fachada, o build de produção usava a regra do Node
/// quando quem importa é ESM "de nascença" (`.mjs`, `.mts`): o objeto inteiro no lugar da
/// função — o que quebra pacotes como o react-transition-group só depois do deploy.
@Suite(.serialized) struct InteropDoBuildTests {
    func grava(_ texto: String, _ raiz: URL, _ caminho: String) throws {
        let u = raiz.appending(path: caminho)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try texto.write(to: u, atomically: true, encoding: .utf8)
    }

    /// Um pacote de cada tipo, importado de um `.tsx` e de um `.mjs` do projeto.
    func projeto(tipoModulo: Bool) throws -> URL {
        let raiz = FileManager.default.temporaryDirectory.appending(
            path: "odete-interop-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try grava(
            tipoModulo ? #"{"name":"app","private":true,"type":"module"}"# : #"{"name":"app","private":true}"#,
            raiz,
            "package.json"
        )
        try grava(
            "<!doctype html><html><head></head><body><script type=\"module\" src=\"/src/main.tsx\"></script></body></html>",
            raiz,
            "index.html"
        )
        try grava("""
        import fn, { nomeado } from "lib-cjs";
        import * as NS from "lib-cjs";
        import B, { outro } from "lib-babel";
        import T from "lib-ts";
        import E, { x } from "lib-esm";
        import { y } from "lib-esm-sem-default";
        import { deMjs } from "./interop.mjs";
        const chama = (f: any) => (typeof f === "function" ? f() : "objeto");
        (globalThis as any).__resultado = [typeof fn, chama(fn), nomeado, NS.nomeado, typeof NS.default,
          chama(B), outro, chama(T), chama(E), x, y, deMjs].join(",");
        """, raiz, "src/main.tsx")
        // Um `.mjs` do projeto: para o esbuild, ESM do Node — onde a regra do Node valia.
        try grava("""
        import B from "lib-babel";
        import fn from "lib-cjs";
        export const deMjs = (typeof B === "function" ? B() : "objeto") + "+" + (typeof fn === "function" ? fn() : "objeto");
        """, raiz, "src/interop.mjs")
        try grava(#"{"name":"lib-cjs","main":"index.js"}"#, raiz, "node_modules/lib-cjs/package.json")
        try grava(
            "module.exports = function () { return 'fn'; }; module.exports.nomeado = 'nom';",
            raiz,
            "node_modules/lib-cjs/index.js"
        )
        // Babel: `__esModule` não enumerável, via defineProperty.
        try grava(#"{"name":"lib-babel","main":"index.js"}"#, raiz, "node_modules/lib-babel/package.json")
        try grava(
            "Object.defineProperty(exports, '__esModule', { value: true }); exports.default = function () { return 'babel'; }; exports.outro = 'out';",
            raiz, "node_modules/lib-babel/index.js"
        )
        // TypeScript (tsc) antigo: `exports.__esModule = true`, atribuído.
        try grava(#"{"name":"lib-ts","main":"index.js"}"#, raiz, "node_modules/lib-ts/package.json")
        try grava(
            "\"use strict\";\nexports.__esModule = true;\nexports.default = function () { return 'ts'; };\n",
            raiz, "node_modules/lib-ts/index.js"
        )
        try grava(#"{"name":"lib-esm","type":"module","main":"index.js"}"#, raiz, "node_modules/lib-esm/package.json")
        try grava(
            "export default function () { return 'esm'; }\nexport const x = 'xis';\nexport const naoUsado = 'NAO_USADO_MARCA';\n",
            raiz, "node_modules/lib-esm/index.js"
        )
        // ESM sem default, e sem "type": o formato sai da sintaxe.
        try grava(
            #"{"name":"lib-esm-sem-default","main":"index.js"}"#,
            raiz,
            "node_modules/lib-esm-sem-default/package.json"
        )
        try grava(
            "export const y = 'ipsilon';\nexport const naoUsado2 = 'NAO_USADO_MARCA2';\n",
            raiz,
            "node_modules/lib-esm-sem-default/index.js"
        )
        return raiz
    }

    static let esperado = "function,fn,nom,nom,function,babel,out,ts,esm,xis,ipsilon,babel+fn"

    /// O que o Preview roda: o pacote de dependências e depois o bundle do app.
    func rodaNoDev(_ raiz: URL) async throws -> String? {
        let dev = DevServer(esbuild: Esbuild(root: raiz))
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000))
        defer { dev.stop() }
        let (a, _) = try await URLSession.shared.data(from: dev.url.appending(path: "@odete/js/src/main.tsx"))
        let (d, _) = try await URLSession.shared.data(from: dev.url.appending(path: "@odete/deps.js"))
        let app = String(decoding: a, as: UTF8.self), deps = String(decoding: d, as: UTF8.self)
        #expect(app.hasPrefix("import \"/@odete/deps.js\";"), "o dev não pré-empacotou: \(app.prefix(300))")
        let c = JSContext()!
        var erro: String?
        c.exceptionHandler = { _, e in erro = e?.toString() }
        c
            .evaluateScript(
                "(function () {\n\(deps.replacingOccurrences(of: "export default ", with: "var __p = "))\n})();"
            )
        c
            .evaluateScript(
                "(function () {\n\(app.replacingOccurrences(of: "import \"/@odete/deps.js\";", with: ""))\n})();"
            )
        #expect(erro == nil, "o dev quebrou: \(erro ?? "")")
        return c.evaluateScript("globalThis.__resultado")?.toString()
    }

    func rodaNoBuild(_ raiz: URL) async throws -> (resultado: String?, js: String) {
        let r = try await Esbuild(root: raiz).build(entries: ["src/main.tsx"], dev: false, minify: true)
        #expect(r.ok, "\(r.diagnostics)")
        #expect(r.diagnostics.isEmpty, "o build avisou: \(r.diagnostics.map(\.text))")
        let js = try #require(r.files.first { $0.path.hasSuffix(".js") }?.text)
        let c = JSContext()!
        var erro: String?
        c.exceptionHandler = { _, e in erro = e?.toString() }
        c.evaluateScript(js)
        #expect(erro == nil, "o build quebrou: \(erro ?? "")")
        return (c.evaluateScript("globalThis.__resultado")?.toString(), js)
    }

    @Test(arguments: [true, false])
    func mesmoImportMesmoValorNoDevENoBuild(tipoModulo: Bool) async throws {
        let raiz = try projeto(tipoModulo: tipoModulo)
        let dev = try await rodaNoDev(raiz)
        let build = try await rodaNoBuild(raiz)
        #expect(dev == Self.esperado, "dev: \(dev ?? "nil")")
        #expect(build.resultado == Self.esperado, "build: \(build.resultado ?? "nil")")
        // A fachada não custa o tree-shaking dos pacotes ESM.
        #expect(!build.js.contains("NAO_USADO_MARCA"), "o build levou export não usado de pacote ESM")
        // A fachada só vai onde a regra do Node valeria: o `.mjs`.
        #expect(!build.js.contains("?odete"))
    }

    /// Quando o pacote de dependências não sai (ESM com `await` no topo), o dev server
    /// volta a levar os pacotes no bundle do app — e o `default` continua o mesmo.
    @Test func devSemPacoteDeDependenciasDaOMesmoDefault() async throws {
        let raiz = try projeto(tipoModulo: true)
        try grava(#"{"name":"lib-tla","type":"module","main":"index.js"}"#, raiz, "node_modules/lib-tla/package.json")
        try grava("export const pronto = await Promise.resolve('tla');\n", raiz, "node_modules/lib-tla/index.js")
        let main = raiz.appending(path: "src/main.tsx")
        try grava(
            "import { pronto } from \"lib-tla\";\n" + String(contentsOf: main, encoding: .utf8)
                .replacingOccurrences(of: "deMjs].join", with: "deMjs, pronto].join"),
            raiz,
            "src/main.tsx"
        )
        let dev = DevServer(esbuild: Esbuild(root: raiz))
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000))
        defer { dev.stop() }
        let (a, _) = try await URLSession.shared.data(from: dev.url.appending(path: "@odete/js/src/main.tsx"))
        let app = String(decoding: a, as: UTF8.self)
        #expect(!app.contains("@odete/deps.js"), "não caiu no bundle com os pacotes")
        // `await` no topo: roda dentro de uma função assíncrona, que o JSC termina antes de
        // devolver (a promessa já está resolvida).
        let c = try #require(JSContext())
        var erro: String?
        c.exceptionHandler = { _, e in erro = e?.toString() }
        c.evaluateScript("(async function () {\n\(app)\n})().catch(function (e) { globalThis.__erro = String(e); });")
        #expect(erro == nil && c.evaluateScript("globalThis.__erro")?.isUndefined == true, "\(erro ?? "")")
        #expect(c.evaluateScript("globalThis.__resultado")?.toString() == Self.esperado + ",tla")
    }
}
