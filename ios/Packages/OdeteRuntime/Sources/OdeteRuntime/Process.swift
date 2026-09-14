import Foundation
import JavaScriptCore

/// Um processo JavaScript: `node arquivo.js` ou um script inline.
public final class JSProcess: @unchecked Sendable {
    let rt: JSRuntime
    public let cwd: URL
    private var exitContinuation: CheckedContinuation<Int32, Never>?

    public init(
        cwd: URL,
        env: [String: String] = [:],
        argv: [String] = [],
        output: @escaping @Sendable (OutputKind, String) -> Void
    ) {
        self.cwd = cwd
        var e = env
        e["HOME"] = cwd.path
        e["PWD"] = cwd.path
        e["NODE_ENV"] = e["NODE_ENV"] ?? "development"
        e["ODETE"] = "1"
        rt = JSRuntime(cwd: cwd, env: e, argv: argv)
        rt.output = output
        ModuleLoader.install(rt)
    }

    /// Transformador TS/ESM → CJS (esbuild) injetado pelo bundler.
    public func setTransform(_ t: @escaping @Sendable (String, String) throws -> String) {
        rt.queue.sync { rt.transform = t }
    }

    /// Roda um arquivo como módulo principal e espera o event loop esvaziar (ou `process.exit`).
    public func run(file: URL) async -> Int32 {
        await start { rt in
            try rt.boot()
            rt.call("__odete_runMain", [file.path])
        }
    }

    /// Roda código inline.
    public func run(code: String, filename: String = "[eval]") async -> Int32 {
        await start { rt in
            try rt.boot()
            rt.call("__odete_runCode", [code, (rt.cwd.path as NSString).appendingPathComponent(filename)])
        }
    }

    private func start(_ body: @escaping @Sendable (JSRuntime) throws -> Void) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            rt.queue.async { [rt] in
                var finished = false
                let finish: () -> Void = {
                    guard !finished else { return }
                    finished = true
                    cont.resume(returning: rt.exitCode)
                }
                rt.onExit = { _ in rt.queue.async { finish() } }
                do {
                    try body(rt)
                } catch let e as RuntimeError {
                    rt.emit(.err, e.message)
                    rt.exit(1)
                    finish()
                    return
                } catch {
                    rt.emit(.err, error.localizedDescription)
                    rt.exit(1)
                    finish()
                    return
                }
                if rt.exited {
                    finish(); return
                }
                if rt.pending <= 0, rt.keepAlive <= 0 {
                    rt.exit(rt.scriptExitCode)
                    finish()
                } else {
                    rt.idleWaiters.append { rt.exit(rt.scriptExitCode); finish() }
                }
            }
        }
    }

    /// Encerra à força (Ctrl+C).
    public func kill() {
        rt.queue.async { [rt] in
            rt.serversBox?.stopAll()
            rt.exit(130)
        }
    }

    /// Portas HTTP abertas por este processo.
    public var ports: [Int] {
        rt.queue.sync { rt.serversBox?.servers.values.map { Int($0.actualPort) } ?? [] }
    }

    /// Manda um evento de reload para todos os clientes WebSocket (dev server).
    public func broadcast(_ text: String) {
        rt.queue.async { [rt] in
            for s in Array(rt.serversBox?.servers.values ?? [:].values) {
                for (rid, _) in s.wsClients {
                    s.wsSend(
                        rid,
                        text: text
                    )
                }
            }
        }
    }
}
