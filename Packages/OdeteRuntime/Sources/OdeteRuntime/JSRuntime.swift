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
    private let agenda: AgendaDeTimers
    private(set) var exited = false
    private(set) var exitCode: Int32 = 0
    var keepAlive = 0 // servidores abertos
    var serversBox: ServersBox?
    var asyncCalls: [Int: CheckedContinuation<String, Error>] = [:]
    var lastError: RuntimeError?
    var nextAsync = 1
    var transform: (@Sendable (String, String) throws -> String)? // (código, caminho) → CJS

    init(cwd: URL, env: [String: String], argv: [String]) {
        // `.workItem`: os JSValue que a ponte ObjC deixa no autorelease morrem ao fim de cada
        // bloco, e não quando a thread do GCD resolver esvaziar o pool — sem isso um contexto
        // encerrado podia ficar vivo por um tempo indeterminado.
        queue = DispatchQueue(
            label: tr("odete.js.%1$@", "\(UUID().uuidString.prefix(6))"),
            qos: .userInitiated,
            autoreleaseFrequency: .workItem
        )
        agenda = AgendaDeTimers(queue: queue)
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
        agenda.aoDisparar = { [weak self] id, terminou in
            guard let self, !exited else { return }
            call("__odete_fireTimer", [id])
            // `exit` dentro do callback já zerou o trabalho pendente.
            if terminou, !exited {
                endWork()
            }
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
        HostBytes.install(self)
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

    /// O atraso chega já normalizado pelo bootstrap.js (piso de 1 ms nos intervalos); `0` roda
    /// na próxima volta do laço. Ver `AgendaDeTimers`.
    func addTimer(ms: Double, repeats: Bool) -> Int {
        let id = agenda.agendar(ms: ms, repete: repeats)
        beginWork()
        return id
    }

    func clearTimer(_ id: Int) {
        if agenda.cancelar(id) {
            endWork()
        }
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
        agenda.cancelarTodos()
        pending = 0
        keepAlive = 0
        onExit?(code)
        checkIdle()
    }

    /// Solta o que prende o mundo de fora depois que o processo terminou: `onExit` (que
    /// segurava o próprio runtime), a saída (que segura a sessão do terminal), o transformador
    /// e os servidores. Sem isso cada `node`/`npx` deixava o contexto JS inteiro vivo.
    func encerrar() {
        onExit = nil
        idleWaiters.removeAll()
        output = nil
        transform = nil
        serversBox?.stopAll()
    }

    /// Um `Uint8Array` com a cópia de `dados`, para passar a `call`.
    func bytes(_ dados: Data) -> JSValue {
        HostBytes.valor(dados, em: context)
    }
}
