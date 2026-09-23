import Foundation
import JavaScriptCore

/// Contexto JS de vida longa (bundler, dev server): avalia scripts e chama funções assíncronas.
public final class JSEngine: @unchecked Sendable {
    let rt: JSRuntime
    public let cwd: URL
    private var booted = false

    public init(cwd: URL, env: [String: String] = [:], output: @escaping @Sendable (OutputKind, String) -> Void) {
        self.cwd = cwd
        var e = env
        e["HOME"] = cwd.path
        e["ODETE"] = "1"
        rt = JSRuntime(cwd: cwd, env: e, argv: [])
        rt.output = output
        ModuleLoader.install(rt)
        // O motor é o do bundler: o que ele empacota para o navegador resolve como navegador.
        ResolucaoDoNavegador.install(rt)
    }

    public func setTransform(_ t: @escaping @Sendable (String, String) throws -> String) {
        rt.queue.sync { rt.transform = t }
    }

    /// Avalia código (síncrono no JS) e devolve `String(result)`.
    @discardableResult
    public func evaluate(_ code: String, name: String = "engine.js") async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            rt.queue.async { [rt] in
                do {
                    if !self.booted {
                        try rt.boot(); self.booted = true
                    }
                    let v = try rt.evaluate(code, url: URL(string: "odete://engine/\(name)"))
                    cont.resume(returning: v?.toString() ?? "")
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Chama `globalThis[fn](...args)`; a função pode devolver uma promessa. Resultado vem como JSON.
    public func call(_ fn: String, _ args: [Any] = []) async throws -> String {
        let argsJSON = try String(
            decoding: JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
            as: UTF8.self
        )
        return try await callJSON(fn, argsJSON: argsJSON)
    }

    public func callJSON(_ fn: String, argsJSON: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            rt.queue.async { [rt] in
                do {
                    if !self.booted {
                        try rt.boot(); self.booted = true
                    }
                    let id = rt.nextAsync
                    rt.nextAsync += 1
                    rt.asyncCalls[id] = cont
                    rt.beginWork()
                    rt.call("__odete_callAsync", [id, fn, argsJSON])
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Versão bloqueante de `call`, para quem precisa de resultado síncrono numa outra fila.
    public func callSync(_ fn: String, _ args: [Any] = []) throws -> String {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let engine = self
        let argsJSON = try String(
            decoding: JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
            as: UTF8.self
        )
        Task.detached {
            do { try await box.set(.success(engine.callJSON(fn, argsJSON: argsJSON))) } catch {
                box.set(.failure(error))
            }
            sem.signal()
        }
        sem.wait()
        return try box.get()
    }

    /// Manda um evento a todos os clientes WebSocket dos servidores deste engine.
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

    public var ports: [Int] {
        rt.queue.sync { rt.serversBox?.servers.values.map { Int($0.actualPort) } ?? [] }
    }

    public func stop() {
        rt.queue.async { [rt] in
            rt.serversBox?.stopAll()
            rt.exit(0)
        }
    }
}

final class ResultBox: @unchecked Sendable {
    private var value: Result<String, Error>?
    private let lock = NSLock()
    func set(_ v: Result<String, Error>) {
        lock.lock(); value = v; lock.unlock()
    }

    func get() throws -> String {
        lock.lock(); defer { lock.unlock() }; return try value!.get()
    }
}
