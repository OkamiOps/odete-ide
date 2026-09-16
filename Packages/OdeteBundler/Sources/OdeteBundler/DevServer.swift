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
    private var watcher: DirectoryWatcherLite?

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
        for arquivo in ["astro.js", "devserver.js"] {
            try await esbuild.engine.evaluate(
                String(contentsOf: js.appending(path: arquivo), encoding: .utf8),
                name: arquivo
            )
        }
        let json = try await esbuild.engine.call("__devStart", [root.path, port, preset.rawValue])
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        self.port = (obj?["port"] as? Int) ?? port
        watcher = DirectoryWatcherLite(url: root) { [weak self] in self?.invalidate() }
        watcher?.start()
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
        watcher?.stop()
        watcher = nil
        esbuild.engine.stop()
    }
}

/// Watcher simples por polling de mtimes (o de OdeteFiles vive noutro pacote).
final class DirectoryWatcherLite: @unchecked Sendable {
    let url: URL
    let onChange: @Sendable () -> Void
    private var timer: DispatchSourceTimer?
    private var last = 0
    private let queue = DispatchQueue(label: "odete.devwatch")

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url; self.onChange = onChange
    }

    func start() {
        last = signature()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let s = signature()
            if s != last {
                last = s; onChange()
            }
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel(); timer = nil
    }

    private func signature() -> Int {
        var h = Hasher()
        guard let e = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let item as URL in e {
            let name = item.lastPathComponent
            if name == "node_modules" || name == "dist" || name == ".git" {
                e.skipDescendants(); continue
            }
            if let v = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
               v.isDirectory != true
            {
                h.combine(item.path); h.combine(v.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        return h.finalize()
    }
}
