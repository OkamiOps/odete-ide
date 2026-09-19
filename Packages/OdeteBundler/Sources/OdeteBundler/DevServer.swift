import Foundation
import OdeteCore
import OdeteRuntime

/// Servidor de desenvolvimento em `127.0.0.1:porta`, com esbuild e reload.
public final class DevServer: @unchecked Sendable {
    public enum Preset: String, Sendable { case plain, vite, astro, next }
    public let esbuild: Esbuild
    public let root: URL
    public private(set) var port = 0
    public var onDiagnostics: (@Sendable ([Diagnostic]) -> Void)?
    private var observador: ObservadorDeArquivos?

    public init(root: URL, output: @escaping @Sendable (OutputKind, String) -> Void = { _, _ in }) {
        self.root = root
        esbuild = Esbuild(root: root, output: output)
    }

    public var url: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    public func start(port: Int = 5173, preset: Preset = .vite) async throws {
        _ = try await esbuild.ready()
        let js = Bundle.module.url(forResource: "js", withExtension: nil)!
        // O compilador de .astro vem antes: o servidor chama `__astroCompila` ao servir
        // uma rota de `src/pages`.
        // O runtime das ilhas não roda aqui: ele é o texto que vai ser empacotado para o
        // navegador quando uma rota tiver componente de cliente.
        let ilhas = try String(contentsOf: js.appending(path: "ilhas-cliente.js"), encoding: .utf8)
        try await esbuild.engine.evaluate(
            "globalThis.__ilhasClienteJS = \(Self.comoLiteralJS(ilhas));",
            name: "ilhas-cliente-fonte.js"
        )
        for arquivo in ["astro.js", "next.js", "devserver.js"] {
            try await esbuild.engine.evaluate(
                String(contentsOf: js.appending(path: arquivo), encoding: .utf8),
                name: arquivo
            )
        }
        let json = try await esbuild.engine.call("__devStart", [root.path, port, preset.rawValue])
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        self.port = (obj?["port"] as? Int) ?? port
        let obs = ObservadorDeArquivos(raiz: root) { [weak self] in self?.invalidate() }
        obs.comecar()
        observador = obs
    }

    /// Texto virando literal de JS, sem depender de escape à mão.
    static func comoLiteralJS(_ s: String) -> String {
        let dados = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let json = dados.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }

    /// Limpa o cache de bundles e manda reload aos clientes.
    public func invalidate() {
        Task { await invalidateNow() }
    }

    public func invalidateNow() async {
        _ = try? await esbuild.engine.call("__devInvalidate")
        if let d = try? await esbuild.engine.call("__devDiagnostics"),
           let list = try? Self.parseDiagnostics(d)
        {
            onDiagnostics?(list)
        }
    }

    public func diagnostics() async -> [Diagnostic] {
        await (try? esbuild.engine.call("__devDiagnostics")).flatMap { try? Self.parseDiagnostics($0) } ?? []
    }

    static func parseDiagnostics(_ json: String) throws -> [Diagnostic] {
        let arr = try (JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
        return arr.map { Diagnostic(
            kind: ($0["kind"] as? String) == "warning" ? .warning : .error,
            text: ($0["text"] as? String) ?? "",
            file: $0["file"] as? String,
            line: $0["line"] as? Int,
            column: $0["column"] as? Int,
            lineText: $0["lineText"] as? String,
            source: "esbuild"
        ) }
    }

    public func stop() {
        observador?.parar()
        observador = nil
        esbuild.engine.stop()
    }
}
