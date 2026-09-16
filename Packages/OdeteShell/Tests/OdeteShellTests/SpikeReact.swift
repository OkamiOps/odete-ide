import Foundation
import OdeteBundler
import OdeteNpm
import OdeteRuntime
import Testing

/// Sonda: o React consegue renderizar HTML dentro do motor JS do iPad?
///
/// Todo o plano de Next depende disso. `react-dom/server` é JS puro, mas usa coisas que
/// nem todo motor tem. Se não rodar aqui, não adianta escrever roteador nenhum.
struct SpikeReactSSR {
    @Test func reactRenderizaNoMotorDaOdete() async throws {
        let raiz = FileManager.default.temporaryDirectory
            .appending(path: "spike-react-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
        try #"{"name":"spike","dependencies":{"react":"19.2.0","react-dom":"19.2.0"}}"#
            .write(to: raiz.appending(path: "package.json"), atomically: true, encoding: .utf8)

        // Depende do registro: sem rede não há o que provar, e falhar aqui seria ruído.
        guard let rep = try? await Installer(project: raiz, registry: HTTPRegistry()).install(),
              !rep.installed.isEmpty
        else { return }

        let esb = Esbuild(root: raiz)
        _ = try await esb.ready()
        let js = """
        (function () {
          try {
            const React = require("react");
            const S = require("react-dom/server");
            const el = React.createElement("h1", { className: "t" }, "oi do React");
            return JSON.stringify({ ok: true, html: S.renderToString(el), tem: Object.keys(S).slice(0, 8) });
          } catch (e) {
            return JSON.stringify({ ok: false, erro: String(e && e.message || e), pilha: String(e && e.stack || "") });
          }
        })()
        """
        let saida = try await esb.engine.evaluate(js, name: "spike.js")
        #expect(saida.contains("\"ok\":true"), "React não rodou: \(saida.prefix(600))")
        #expect(saida.contains("oi do React"), "renderToString não produziu HTML: \(saida.prefix(600))")
    }
}
