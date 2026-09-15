import Foundation
import OdeteCore
import OdeteI18n
import OdeteRuntime

public struct Diagnostic: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case error, warning, info }
    public var kind: Kind
    public var text: String
    public var file: String?
    public var line: Int?
    public var column: Int?
    public var lineText: String?
    public var source: String
    public var id: String {
        "\(source):\(file ?? ""):\(line ?? 0):\(column ?? 0):\(text)"
    }

    public init(
        kind: Kind,
        text: String,
        file: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        lineText: String? = nil,
        source: String
    ) {
        self.kind = kind; self.text = text; self.file = file; self.line = line; self.column = column; self
            .lineText = lineText; self.source = source
    }
}

public struct BuildResult: Sendable {
    public var ok: Bool
    public var files: [(path: String, text: String)]
    public var diagnostics: [Diagnostic]
}

/// Um JSEngine com o esbuild-wasm carregado. Um por projeto (o dev server vive nele) e um compartilhado
/// para transformações avulsas (`node x.ts`).
public final class Esbuild: @unchecked Sendable {
    public let engine: JSEngine
    public let root: URL
    private var initialized: Task<String, Error>?
    public var onOutput: (@Sendable (OutputKind, String) -> Void)?

    public static let version: String = {
        let u = Bundle.module.url(forResource: "esbuild", withExtension: nil)!.appending(path: "VERSION")
        return (try? String(contentsOf: u, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }()

    public init(root: URL, output: @escaping @Sendable (OutputKind, String) -> Void = { _, _ in }) {
        self.root = root
        engine = JSEngine(cwd: root, output: output)
    }

    /// Carrega o esbuild (uma vez; ~1-2 s).
    public func ready() async throws -> String {
        if let t = initialized {
            return try await t.value
        }
        let t = Task<String, Error> { [engine] in
            let res = Bundle.module.url(forResource: "esbuild", withExtension: nil)!
            let js = Bundle.module.url(forResource: "js", withExtension: nil)!
            try await engine.evaluate(
                String(contentsOf: js.appending(path: "bundler.js"), encoding: .utf8),
                name: "bundler.js"
            )
            let v = try await engine.call(
                "__esbuildInit",
                [res.appending(path: "browser.js").path, res.appending(path: "esbuild.wasm").path]
            )
            return v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        initialized = t
        return try await t.value
    }

    public func transform(_ code: String, loader: String, options: [String: Any] = [:]) async throws -> String {
        _ = try await ready()
        var o = options
        o["loader"] = loader
        let json = try await engine.call("__transform", [code, o])
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return (obj?["code"] as? String) ?? ""
    }

    /// Só sintaxe: diagnósticos do esbuild para um arquivo, sem gerar código.
    public func lint(_ code: String, file: String) async throws -> [Diagnostic] {
        _ = try await ready()
        let ext = (file as NSString).pathExtension.lowercased()
        let loader = ["ts": "ts", "mts": "ts", "cts": "ts", "tsx": "tsx", "jsx": "jsx", "css": "css",
                      "json": "json"][ext] ?? "js"
        let json = try await engine.call("__lint", [code, loader, file])
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
        func parse(_ key: String, _ kind: Diagnostic.Kind) -> [Diagnostic] {
            ((obj[key] as? [[String: Any]]) ?? []).map { m in
                Diagnostic(
                    kind: kind,
                    text: m["text"] as? String ?? "",
                    file: file,
                    line: m["line"] as? Int,
                    column: (m["column"] as? Int).map { $0 + 1 },
                    lineText: m["lineText"] as? String,
                    source: "esbuild"
                )
            }
        }
        return parse("errors", .error) + parse("warnings", .warning)
    }

    /// TS/ESM → CJS, bloqueante (para o `require` de outro runtime).
    public func transformCJSSync(_ code: String, file: String) throws -> String {
        let json = try engine.callSync("__transformCJS", [code, file])
        return try (JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? String) ?? ""
    }

    public func build(
        entries: [String],
        platform: String = "browser",
        format: String = "esm",
        dev: Bool = true,
        minify: Bool = false,
        define: [String: String] = [:]
    ) async throws -> BuildResult {
        _ = try await ready()
        let json = try await engine.call(
            "__build",
            [[
                "root": root.path,
                "entries": entries,
                "platform": platform,
                "format": format,
                "dev": dev,
                "minify": minify,
                "define": define,
                "outdir": "dist",
            ] as [String: Any]]
        )
        return try Self.parseBuild(json)
    }

    static func parseBuild(_ json: String) throws -> BuildResult {
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { throw RuntimeError(message: tr("build: resposta inválida")) }
        let files = ((obj["files"] as? [[String: Any]]) ?? []).map { (
            path: ($0["path"] as? String) ?? "",
            text: ($0["text"] as? String) ?? ""
        ) }
        func diags(_ key: String, _ kind: Diagnostic.Kind) -> [Diagnostic] {
            ((obj[key] as? [[String: Any]]) ?? []).map { Diagnostic(
                kind: kind,
                text: ($0["text"] as? String) ?? "",
                file: $0["file"] as? String,
                line: $0["line"] as? Int,
                column: $0["column"] as? Int,
                lineText: $0["lineText"] as? String,
                source: "esbuild"
            ) }
        }
        return BuildResult(
            ok: (obj["ok"] as? Bool) ?? false,
            files: files,
            diagnostics: diags("errors", .error) + diags("warnings", .warning)
        )
    }

    /// Transformador para injetar num `JSProcess`.
    public var cjsTransform: @Sendable (String, String) throws -> String {
        { [self] code, file in try transformCJSSync(code, file: file) }
    }
}
