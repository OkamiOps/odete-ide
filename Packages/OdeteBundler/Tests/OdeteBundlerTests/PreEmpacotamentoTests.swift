import Foundation
import JavaScriptCore
@testable import OdeteBundler
import Testing

/// O pacote de dependências do dev server (o `optimizeDeps` do Vite).
///
/// Os pacotes de node_modules saem do bundle do app e vêm de `/@odete/deps.js`, feito uma
/// vez e guardado em `node_modules/.odete-deps/`. Estes testes provam o que isso não pode
/// quebrar — uma cópia só do React (hooks funcionando), `default` e nomeados de pacote
/// CommonJS, o `vite build` com tudo dentro — e o que tem de valer: cache entre
/// servidores, cache que cai com o lockfile, com um pacote reinstalado e com import novo,
/// e rebuild do app que não encosta nos pacotes.
@Suite(.serialized) struct PreEmpacotamentoTests {
    func porta() -> Int {
        20000 + Int.random(in: 0 ..< 20000)
    }

    func texto(_ u: URL) async throws -> String {
        let (d, _) = try await URLSession.shared.data(from: u)
        return String(decoding: d, as: UTF8.self)
    }

    func ate(_ prazo: Duration = .seconds(15), _ condicao: () async -> Bool) async -> Bool {
        let fim = ContinuousClock.now + prazo
        while ContinuousClock.now < fim {
            if await condicao() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return await condicao()
    }

    func grava(_ texto: String, _ raiz: URL, _ caminho: String) throws {
        let u = raiz.appending(path: caminho)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try texto.write(to: u, atomically: true, encoding: .utf8)
    }

    /// Um projeto Vite com um React de mentira que falha como o de verdade: o hook só
    /// funciona com o "despachante" que o react-dom liga no React que ele mesmo importou.
    /// Duas cópias do React e o `useState` do app cai em "Invalid hook call".
    func projetoComHooks() throws -> URL {
        let raiz = FileManager.default.temporaryDirectory.appending(
            path: "odete-pre-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try grava(#"{"name":"app","private":true,"type":"module"}"#, raiz, "package.json")
        try grava(
            #"{"name":"app","lockfileVersion":3,"packages":{"node_modules/react":{"version":"19.0.0"}}}"#,
            raiz,
            "package-lock.json"
        )
        try grava(
            "<!doctype html><html><head></head><body><div id=\"root\"></div><script type=\"module\" src=\"/src/main.tsx\"></script></body></html>",
            raiz, "index.html"
        )
        try grava("""
        import { useState } from "react";
        import { createRoot } from "react-dom/client";
        import { dobro } from "./dobro";
        import "./estilo.css";

        function Contador() {
          const [n] = useState(20);
          return <b>{dobro(n) + 2}</b>;
        }

        createRoot(document.getElementById("root")!).render(<Contador />);
        """, raiz, "src/main.tsx")
        try grava("export const dobro = (n: number): number => n * 2;\n", raiz, "src/dobro.ts")
        try grava(".contador { color: green }\n", raiz, "src/estilo.css")
        try grava(
            #"{"name":"react","version":"19.0.0","main":"index.js","exports":{".":"./index.js","./jsx-dev-runtime":"./jsx-dev-runtime.js","./jsx-runtime":"./jsx-runtime.js"}}"#,
            raiz, "node_modules/react/package.json"
        )
        try grava("""
        "use strict";
        globalThis.__copiasDoReact = (globalThis.__copiasDoReact || 0) + 1;
        var interno = { atual: null };
        exports.__INTERNO = interno;
        exports.useState = function (v) {
          if (!interno.atual) throw new Error("Invalid hook call: REACT_MARCA");
          return interno.atual.useState(v);
        };
        """, raiz, "node_modules/react/index.js")
        try grava(
            "exports.jsxDEV = function (t, p) { return { t: t, p: p }; }; exports.Fragment = 'f';",
            raiz, "node_modules/react/jsx-dev-runtime.js"
        )
        try grava(
            "exports.jsx = function (t, p) { return { t: t, p: p }; }; exports.jsxs = exports.jsx; exports.Fragment = 'f';",
            raiz, "node_modules/react/jsx-runtime.js"
        )
        try grava(
            #"{"name":"react-dom","version":"19.0.0","main":"index.js","exports":{".":"./index.js","./client":"./client.js"}}"#,
            raiz, "node_modules/react-dom/package.json"
        )
        try grava("exports.version = '19.0.0-falso';", raiz, "node_modules/react-dom/index.js")
        try grava("""
        "use strict";
        var React = require("react");
        require("./estilo.css");
        require("./interno.js");
        function texto(x) {
          if (x == null || typeof x === "boolean") return "";
          if (typeof x !== "object") return String(x);
          if (Array.isArray(x)) return x.map(texto).join("");
          if (typeof x.t === "function") return texto(x.t(x.p));
          return texto(x.p && x.p.children);
        }
        exports.createRoot = function (el) {
          return { render: function (x) {
            React.__INTERNO.atual = { useState: function (v) { return [v, function () {}]; } };
            try { el.textContent = texto(x); } finally { React.__INTERNO.atual = null; }
          } };
        };
        """, raiz, "node_modules/react-dom/client.js")
        try grava(".react-dom-falso { margin: 0 }\n", raiz, "node_modules/react-dom/estilo.css")
        try grava("exports.marca = 'interno-do-react-dom';", raiz, "node_modules/react-dom/interno.js")
        return raiz
    }

    /// O que o Preview roda: o pacote de dependências e depois o bundle do app, cada um no
    /// seu escopo (são módulos), com um DOM mínimo. Devolve o texto posto em `#root`.
    func roda(_ dev: DevServer, contexto: JSContext = JSContext()) async throws -> (texto: String, erro: String?) {
        let app = try await texto(dev.url.appending(path: "@odete/js/src/main.tsx"))
        let deps = try await texto(dev.url.appending(path: "@odete/deps.js"))
        #expect(app.hasPrefix("import \"/@odete/deps.js\";"), "o bundle não começa importando as dependências")
        var erro: String?
        contexto.exceptionHandler = { _, e in erro = e?.toString() }
        contexto.evaluateScript("""
        var raiz = { textContent: "" };
        globalThis.document = { getElementById: function () { return raiz; }, body: {} };
        """)
        let semExport = deps.replacingOccurrences(of: "export default ", with: "var __padrao = ")
        contexto.evaluateScript("(function () {\n\(semExport)\n})();")
        let semImport = app.replacingOccurrences(of: "import \"/@odete/deps.js\";", with: "")
        contexto.evaluateScript("(function () {\n\(semImport)\n})();")
        return (contexto.evaluateScript("raiz.textContent")?.toString() ?? "", erro)
    }

    func stats(_ dev: DevServer) async -> [String: Int] {
        await dev.estatisticas()
    }

    // MARK: - Uma cópia do React

    @Test func hooksFuncionamComUmaCopiaSoDoReact() async throws {
        let raiz = try projetoComHooks()
        let dev = DevServer(root: raiz)
        try await dev.start(port: porta())
        defer { dev.stop() }
        let contexto = try #require(JSContext())
        let r = try await roda(dev, contexto: contexto)
        #expect(r.erro == nil, "o app quebrou: \(r.erro ?? "")")
        #expect(r.texto == "42", "o componente com useState não renderizou: \(r.texto)")
        #expect(
            contexto.evaluateScript("globalThis.__copiasDoReact")?.toInt32() == 1,
            "mais de uma cópia do React rodou"
        )

        // O React está no pacote de dependências, e só lá.
        let app = try await texto(dev.url.appending(path: "@odete/js/src/main.tsx"))
        let deps = try await texto(dev.url.appending(path: "@odete/deps.js"))
        #expect(!app.contains("REACT_MARCA") && deps.contains("REACT_MARCA"))
        #expect(app.contains("n * 2"), "o código do app saiu do bundle do app")
        let s = await stats(dev)
        #expect(s["lidosDePacote"] == 0, "o bundle do app leu arquivo de pacote: \(s)")
        #expect(s["depsBuilds"] == 1 && s["depsModulos"] == 3, "\(s)")

        // A folha que o pacote importa vem pelo link das dependências, antes da do app.
        let html = try await texto(dev.url)
        let linkDeps = try #require(html.range(of: "/@odete/deps.css"))
        let linkApp = try #require(html.range(of: "/@odete/css/src/main.tsx"))
        #expect(linkDeps.lowerBound < linkApp.lowerBound)
        #expect(try await texto(dev.url.appending(path: "@odete/deps.css")).contains("react-dom-falso"))
        let css = try await texto(dev.url.appending(path: "@odete/css/src/main.tsx"))
        #expect(css.contains("color: green") && !css.contains("react-dom-falso"))
    }

    /// `default` e nomeados como no Vite: CommonJS dá `module.exports` no default (ou o
    /// `default` dele, se tiver `__esModule`), e um pacote ESM dá o default de verdade —
    /// num projeto `"type": "module"`, que é o de todo Vite.
    @Test func defaultENomeadosDePacoteCommonJSEESM() async throws {
        let raiz = try projetoComHooks()
        try grava("""
        import fn, { nomeado } from "lib-cjs";
        import * as NS from "lib-cjs";
        import B, { outro } from "lib-babel";
        import E, { x } from "lib-esm";
        import React from "react";
        (globalThis as any).__resultado = [typeof fn, fn(), nomeado, NS.nomeado, typeof NS.default,
          B(), outro, E(), x, typeof React.useState].join(",");
        """, raiz, "src/main.tsx")
        try grava(#"{"name":"lib-cjs","main":"index.js"}"#, raiz, "node_modules/lib-cjs/package.json")
        try grava(
            "module.exports = function () { return 'fn'; }; module.exports.nomeado = 'nom';",
            raiz, "node_modules/lib-cjs/index.js"
        )
        try grava(#"{"name":"lib-babel","main":"index.js"}"#, raiz, "node_modules/lib-babel/package.json")
        try grava(
            "Object.defineProperty(exports, '__esModule', { value: true }); exports.default = function () { return 'babel'; }; exports.outro = 'out';",
            raiz, "node_modules/lib-babel/index.js"
        )
        try grava(#"{"name":"lib-esm","type":"module","main":"index.mjs"}"#, raiz, "node_modules/lib-esm/package.json")
        try grava(
            "export default function () { return 'esm'; }\nexport const x = 'xis';\n",
            raiz, "node_modules/lib-esm/index.mjs"
        )
        let dev = DevServer(root: raiz)
        try await dev.start(port: porta())
        defer { dev.stop() }
        let contexto = try #require(JSContext())
        let r = try await roda(dev, contexto: contexto)
        #expect(r.erro == nil, "\(r.erro ?? "")")
        #expect(
            contexto.evaluateScript("globalThis.__resultado")?.toString() == "function,fn,nom,nom,function,babel,out,esm,xis,function"
        )
        #expect(await stats(dev)["depsModulos"] == 4)
    }

    // MARK: - Cache

    @Test func cacheValeEntreServidoresEAberturasDoApp() async throws {
        let raiz = try projetoComHooks()
        let dev = DevServer(root: raiz)
        try await dev.start(port: porta())
        _ = try await roda(dev)
        #expect(await stats(dev)["depsBuilds"] == 1)
        dev.stop()
        let pasta = raiz.appending(path: "node_modules/.odete-deps")
        let guardados = try FileManager.default.contentsOfDirectory(atPath: pasta.path)
        #expect(
            guardados.contains { $0.hasSuffix(".js") } && guardados.contains { $0.hasSuffix(".json") },
            "\(guardados)"
        )

        // Motor novo, como o app reaberto: nada de build do pacote.
        let outro = DevServer(esbuild: Esbuild(root: raiz))
        try await outro.start(port: porta())
        defer { outro.stop() }
        let r = try await roda(outro)
        #expect(r.erro == nil && r.texto == "42", "\(r)")
        let s = await stats(outro)
        #expect(s["depsBuilds"] == 0 && s["depsDoDisco"] == 1, "o cache em disco não foi usado: \(s)")

        // O Rebuild esquece a memória, mas o disco continua valendo.
        await outro.invalidateNow()
        _ = try await texto(outro.url.appending(path: "@odete/js/src/main.tsx"))
        let depois = await stats(outro)
        #expect(depois["depsBuilds"] == 0 && depois["depsDoDisco"] == 2, "\(depois)")
    }

    @Test func lockfileNovoOuPacoteReinstaladoRefazemOPacote() async throws {
        let raiz = try projetoComHooks()
        let dev = DevServer(root: raiz)
        try await dev.start(port: porta())
        _ = try await roda(dev)
        dev.stop()

        // Lockfile diferente: a chave muda.
        try grava(
            #"{"name":"app","lockfileVersion":3,"packages":{"node_modules/react":{"version":"19.0.1"}}}"#,
            raiz,
            "package-lock.json"
        )
        let segundo = DevServer(esbuild: Esbuild(root: raiz))
        try await segundo.start(port: porta())
        _ = try await roda(segundo)
        #expect(await stats(segundo)["depsBuilds"] == 1, "lockfile mudou e o pacote velho foi usado")
        segundo.stop()

        // Mesmo lockfile, arquivo de pacote reescrito (reinstalado, editado à mão): a
        // conferência de tamanho e data derruba o cache.
        try grava(
            "exports.jsxDEV = function (t, p) { return { t: t, p: p, novo: 1 }; }; exports.Fragment = 'f';",
            raiz, "node_modules/react/jsx-dev-runtime.js"
        )
        let terceiro = DevServer(esbuild: Esbuild(root: raiz))
        try await terceiro.start(port: porta())
        defer { terceiro.stop() }
        _ = try await roda(terceiro)
        #expect(await stats(terceiro)["depsBuilds"] == 1, "pacote reescrito e o cache velho foi usado")
        #expect(try await texto(terceiro.url.appending(path: "@odete/deps.js")).contains("novo: 1"))
    }

    /// Com o servidor no ar, o lockfile muda (npm install): tudo do zero, e o pacote de
    /// dependências é refeito porque a chave mudou.
    @Test func lockfileMudandoComOServidorNoAr() async throws {
        let raiz = try projetoComHooks()
        let dev = DevServer(root: raiz)
        try await dev.start(port: porta())
        defer { dev.stop() }
        _ = try await roda(dev)
        try grava(
            #"{"name":"app","lockfileVersion":3,"packages":{"node_modules/react":{"version":"19.9.9"}}}"#,
            raiz,
            "package-lock.json"
        )
        let reacao = await dev.arquivosMudaram([raiz.appending(path: "package-lock.json").path])
        #expect(reacao == .reload)
        let r = try await roda(dev)
        #expect(r.erro == nil && r.texto == "42")
        #expect(await stats(dev)["depsBuilds"] == 2)
    }

    @Test func importDePacoteNovoRefazOPacoteERecarrega() async throws {
        let raiz = try projetoComHooks()
        let dev = DevServer(root: raiz)
        try await dev.start(port: porta())
        defer { dev.stop() }
        _ = try await roda(dev)
        let main = raiz.appending(path: "src/main.tsx")
        #expect(await ate { dev.arquivosVigiados.contains(main.path) })
        var fonte = try String(contentsOf: main, encoding: .utf8)
        fonte = "import { version } from \"react-dom\";\n(globalThis as any).__versao = version;\n" + fonte
        try fonte.write(to: main, atomically: true, encoding: .utf8)
        #expect(await ate { await stats(dev)["reload"] == 1 }, "import novo não recarregou")
        let s = await stats(dev)
        // Os três do começo, o `react-dom` novo e o `interno.js`, que já estava dentro.
        #expect(s["depsBuilds"] == 2 && s["depsModulos"] == 5, "\(s)")
        let contexto = try #require(JSContext())
        let r = try await roda(dev, contexto: contexto)
        #expect(r.erro == nil && r.texto == "42", "\(r)")
        #expect(contexto.evaluateScript("globalThis.__versao")?.toString() == "19.0.0-falso")
        #expect(contexto.evaluateScript("globalThis.__copiasDoReact")?.toInt32() == 1)

        // Refeito, o pacote registra tudo o que tem dentro: importar um arquivo que o
        // react-dom já usava não refaz nada, e o módulo é o mesmo que o react-dom usa.
        fonte = "import { marca } from \"react-dom/interno.js\";\n(globalThis as any).__marca = marca;\n" + fonte
        try fonte.write(to: main, atomically: true, encoding: .utf8)
        #expect(await ate { await stats(dev)["reload"] == 2 }, "o segundo import não recarregou")
        #expect(await stats(dev)["depsBuilds"] == 2, "import de arquivo que já estava no pacote refez o pacote")
        let outroContexto = try #require(JSContext())
        let r2 = try await roda(dev, contexto: outroContexto)
        #expect(r2.erro == nil && r2.texto == "42", "\(r2)")
        #expect(outroContexto.evaluateScript("globalThis.__marca")?.toString() == "interno-do-react-dom")

        // Servidor novo: o pacote com o import novo já está em disco.
        dev.stop()
        let outro = DevServer(esbuild: Esbuild(root: raiz))
        try await outro.start(port: porta())
        defer { outro.stop() }
        _ = try await roda(outro)
        #expect(await stats(outro)["depsBuilds"] == 0)
    }

    /// Editar o app refaz só o app: o pacote de dependências não é refeito nem lido, e o
    /// bundle do app não passa por node_modules.
    @Test func rebuildDoAppNaoEncostaNosPacotes() async throws {
        let raiz = try projetoComHooks()
        let dev = DevServer(root: raiz)
        try await dev.start(port: porta())
        defer { dev.stop() }
        _ = try await roda(dev)
        let dobro = raiz.appending(path: "src/dobro.ts")
        #expect(await ate { dev.arquivosVigiados.contains(dobro.path) })
        for i in 1 ... 2 {
            try "export const dobro = (n: number): number => n * 2 + \(i * 0);\n// \(i)\n".write(
                to: dobro, atomically: true, encoding: .utf8
            )
            _ = await ate { await stats(dev)["builds"] == 1 + i }
        }
        let s = await stats(dev)
        #expect(s["builds"] == 3 && s["depsBuilds"] == 1 && s["depsDoDisco"] == 0, "\(s)")
        #expect(s["lidosDePacote"] == 0)
        #expect(!dev.arquivosVigiados.contains { $0.contains("/node_modules") }, "\(dev.arquivosVigiados)")
        // Recarregar a página não manda o pacote de novo: a ETag responde.
        var pedido = URLRequest(url: dev.url.appending(path: "@odete/deps.js"))
        let (_, r1) = try await URLSession.shared.data(for: pedido)
        let etag = try #require((r1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "etag"))
        pedido.setValue(etag, forHTTPHeaderField: "If-None-Match")
        pedido.cachePolicy = .reloadIgnoringLocalCacheData
        let (corpo, r2) = try await URLSession.shared.data(for: pedido)
        #expect((r2 as? HTTPURLResponse)?.statusCode == 304 && corpo.isEmpty)
    }

    // MARK: - O resto continua igual

    /// O `vite build` não sabe de pacote de dependências: tudo vai no bundle.
    @Test func buildDeProducaoLevaTudoJunto() async throws {
        let raiz = try projetoComHooks()
        let es = Esbuild(root: raiz)
        let r = try await es.build(entries: ["src/main.tsx"], dev: false, minify: false)
        #expect(r.ok, "\(r.diagnostics)")
        let js = try #require(r.files.first { $0.path.hasSuffix(".js") }?.text)
        #expect(js.contains("REACT_MARCA") && js.contains("__copiasDoReact"))
        #expect(!js.contains("__odeteDep") && !js.contains("@odete/deps"))
    }

    /// Projeto do iCloud: o cache passa pelo atalho e mora em `node_modules.nosync`, que o
    /// iCloud não sincroniza. E gravar o cache não acorda o observador.
    @Test func cacheNoICloudFicaNoNosync() async throws {
        let raiz = try projetoComHooks()
        let fm = FileManager.default
        try fm.moveItem(at: raiz.appending(path: "node_modules"), to: raiz.appending(path: "node_modules.nosync"))
        try fm.createSymbolicLink(
            atPath: raiz.appending(path: "node_modules").path,
            withDestinationPath: "node_modules.nosync"
        )
        let dev = DevServer(root: raiz)
        try await dev.start(port: porta())
        defer { dev.stop() }
        let r = try await roda(dev)
        #expect(r.erro == nil && r.texto == "42", "\(r)")
        let real = raiz.appending(path: "node_modules.nosync/.odete-deps").path
        #expect(try fm.contentsOfDirectory(atPath: real).contains { $0.hasSuffix(".js") })
        try await Task.sleep(for: .seconds(2))
        let s = await stats(dev)
        #expect(s["reload"] == 0 && s["builds"] == 1, "gravar o cache fez o servidor refazer: \(s)")
    }

    /// Pacote que não cabe no pacote de dependências (ESM com `await` no topo não vira
    /// fábrica): os pacotes voltam para dentro do bundle do app, e o app funciona.
    @Test func pacoteQueNaoCabeVoltaParaOBundleDoApp() async throws {
        let raiz = try projetoComHooks()
        try grava(#"{"name":"lib-tla","type":"module","main":"index.js"}"#, raiz, "node_modules/lib-tla/package.json")
        try grava("export const pronto = await Promise.resolve('tla');\n", raiz, "node_modules/lib-tla/index.js")
        try grava("""
        import { pronto } from "lib-tla";
        document.getElementById("root").textContent = pronto;
        """, raiz, "src/main.tsx")
        let dev = DevServer(root: raiz)
        try await dev.start(port: porta())
        defer { dev.stop() }
        let js = try await texto(dev.url.appending(path: "@odete/js/src/main.tsx"))
        #expect(js.contains("Promise.resolve(\"tla\")"), "o pacote não voltou para o bundle do app")
        #expect(!js.contains("@odete/deps.js"))
        #expect(await stats(dev)["preEmpacota"] == 0)
        #expect(await dev.diagnostics().filter { $0.kind == .error }.isEmpty)
        // O Rebuild tenta de novo (e cai de novo, sem quebrar nada).
        await dev.invalidateNow()
        #expect(try await texto(dev.url.appending(path: "@odete/js/src/main.tsx")).contains("Promise.resolve(\"tla\")"))
    }

    /// Projeto sem pacote nenhum: o registro vazio responde, e nada é gravado.
    @Test func projetoSemPacotes() async throws {
        let raiz = FileManager.default.temporaryDirectory.appending(
            path: "odete-pre-vazio-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try grava("document.body.textContent = String(40 + 2);\n", raiz, "src/main.ts")
        try grava("<script type=\"module\" src=\"/src/main.ts\"></script>", raiz, "index.html")
        let dev = DevServer(root: raiz)
        try await dev.start(port: porta())
        defer { dev.stop() }
        let js = try await texto(dev.url.appending(path: "@odete/js/src/main.ts"))
        #expect(js.contains("40 + 2"))
        let deps = try await texto(dev.url.appending(path: "@odete/deps.js"))
        #expect(deps.contains("__odeteDep"))
        #expect(await stats(dev)["depsBuilds"] == 0)
        #expect(!FileManager.default.fileExists(atPath: raiz.appending(path: "node_modules").path))
    }
}
