import Foundation
import JavaScriptCore
import OdeteI18n

/// Um contexto JavaScriptCore numa fila serial, com o objeto host `__odete` e o event loop.
/// Tudo que toca `context` roda em `queue`.
final class JSRuntime: @unchecked Sendable {
    let queue: DispatchQueue
    let context: JSContext
    let host: JSValue
    let cwd: URL
    let env: [String: String]
    let argv: [String]
    var output: (@Sendable (OutputKind, String) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?
    private(set) var pending = 0 // trabalho assíncrono vivo (timers, fetch, servidores)
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var nextTimer = 1
    private(set) var exited = false
    private(set) var exitCode: Int32 = 0
    var keepAlive = 0 // servidores abertos
    var serversBox: ServersBox?
    var asyncCalls: [Int: CheckedContinuation<String, Error>] = [:]
    var lastError: RuntimeError?
    var nextAsync = 1
    var transform: (@Sendable (String, String) throws -> String)? // (código, caminho) → CJS

    init(cwd: URL, env: [String: String], argv: [String]) {
        queue = DispatchQueue(label: tr("odete.js.%1$@", "\(UUID().uuidString.prefix(6))"), qos: .userInitiated)
        context = JSContext()!
        host = JSValue(newObjectIn: context)
        self.cwd = cwd
        self.env = env
        self.argv = argv
        context.name = "Odete"
        context.setObject(host, forKeyedSubscript: "__odete" as NSString)
        context.exceptionHandler = { [weak self] _, exc in
            guard let self, let exc else { return }
            let msg = exc.toString() ?? "erro"
            let stack = exc.objectForKeyedSubscript("stack")?.toString() ?? ""
            let text = stack.isEmpty ? msg : msg + "\n    " + stack.replacingOccurrences(of: "\n", with: "\n    ")
            lastError = RuntimeError(message: text)
            emit(.err, text)
        }
        installHost()
    }

    // MARK: saída

    func emit(_ kind: OutputKind, _ text: String) {
        output?(kind, text)
    }

    // MARK: host base

    private func installHost() {
        HostCore.install(self)
        HostFs.install(self)
        HostFetch.install(self)
        HostHttp.install(self)
    }

    /// Avalia o bootstrap (globals + módulos) e devolve.
    func boot() throws {
        let dir = Bundle.module.url(forResource: "node", withExtension: nil)!
        let order = [
            "bootstrap",
            "events",
            "buffer",
            "path",
            "util",
            "stream",
            "fs",
            "os",
            "url",
            "querystring",
            "string_decoder",
            "assert",
            "zlib",
            "child_process",
            "http",
            "process",
            "loader",
        ]
        for name in order {
            let file = dir.appending(path: "\(name).js")
            guard let src = try? String(contentsOf: file, encoding: .utf8) else { continue }
            lastError = nil
            context.evaluateScript(src, withSourceURL: URL(string: "odete://node/\(name).js"))
            if let e = lastError {
                lastError = nil; throw RuntimeError(message: tr("bootstrap %1$@: %2$@", "\(name)", "\(e.message)"))
            }
        }
    }

    /// Avalia código e lança se houver exceção.
    @discardableResult
    func evaluate(_ code: String, url: URL?) throws -> JSValue? {
        lastError = nil
        let v = context.evaluateScript(code, withSourceURL: url)
        if let e = lastError {
            lastError = nil; throw e
        }
        return v
    }

    func call(_ name: String, _ args: [Any]) {
        guard let fn = context.objectForKeyedSubscript(name), fn.isObject else { return }
        fn.call(withArguments: args)
    }

    // MARK: event loop

    func beginWork() {
        pending += 1
    }

    func endWork() {
        pending -= 1; checkIdle()
    }

    var idleWaiters: [() -> Void] = []
    func checkIdle() {
        if pending <= 0, keepAlive <= 0, !idleWaiters.isEmpty {
            let w = idleWaiters
            idleWaiters = []
            w.forEach { $0() }
        }
    }

    func addTimer(ms: Double, repeats: Bool) -> Int {
        let id = nextTimer
        nextTimer += 1
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(max(Int(ms), 0))
        if repeats {
            t.schedule(deadline: .now() + interval, repeating: interval)
        } else {
            t.schedule(deadline: .now() + interval)
        }
        t.setEventHandler { [weak self] in
            guard let self, !exited else { return }
            call("__odete_fireTimer", [id])
            if !repeats {
                clearTimer(id)
            }
        }
        timers[id] = t
        beginWork()
        t.resume()
        return id
    }

    func clearTimer(_ id: Int) {
        guard let t = timers.removeValue(forKey: id) else { return }
        t.cancel()
        endWork()
    }

    /// `process.exitCode` definido pelo script, se houver.
    var scriptExitCode: Int32 {
        guard let v = context.evaluateScript("(globalThis.process && globalThis.process.exitCode) || 0"),
              v.isNumber else { return 0 }
        return v.toInt32()
    }

    func exit(_ code: Int32) {
        guard !exited else { return }
        exited = true
        exitCode = code
        for (_, t) in timers {
            t.cancel()
        }
        timers.removeAll()
        pending = 0
        keepAlive = 0
        onExit?(code)
        checkIdle()
    }
}
