import Foundation
import JavaScriptCore
import OdeteI18n
import Synchronization

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
    /// Quem quer os bytes crus de stdout/stderr (o terminal, para redirecionar binário para um
    /// arquivo e juntar `write`s parciais numa linha). Sem ele a saída vai por `output`, uma
    /// linha de cada vez, montada aqui.
    var saidaBruta: (@Sendable (OutputKind, Data) -> Void)?
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
    /// O transformador do módulo de entrada (async rebaixado, top-level await). Ver
    /// `TransformadorDeEntrada`.
    var transformEntrada: TransformadorDeEntrada?
    /// Identifica o transformador para o cache em disco; sem ela nada é guardado.
    var versaoDoTransformador: String?
    /// package.json e resoluções já vistos (ver `CacheDeModulos`); só na fila do runtime.
    let cacheDeModulos = CacheDeModulos()
    /// Onde o `fs` pode mexer. Nil: sem restrição (o motor do bundler, testes antigos).
    var confinamento: Confinamento?
    /// O stdin do processo (`echo x | node s.js`), inteiro; nil quando não há nada ligado.
    var entrada: Data?
    /// Um `node`/`npx` de verdade, e não o motor de longa vida do bundler: só aqui rejeição
    /// não tratada derruba o processo, e só aqui há `beforeExit`/`exit`.
    var modoProcesso = false
    /// Descritores abertos pelo `fs.openSync`, fechados quando o processo termina.
    var descritores: Set<Int32> = []
    /// Timers com `unref()`: vivos, mas sem segurar o processo (não contam em `pending`).
    private var semRef: Set<Int> = []
    private var ociosoAgendado = false
    private var linhaParcial: [OutputKind: Data] = [:]
    /// Ctrl+C num processo preso em JS síncrono: a fila não volta para rodar o `exit`, então
    /// a marca é lida de fora da fila. Com ela a saída para de ir à tela e as chamadas ao
    /// host lançam, o que derruba todo laço que escreve ou mexe em arquivo.
    let interrompido = Atomic<Bool>(false)
    /// Portas abertas (id do servidor → porta), legíveis de fora da fila: o terminal pergunta
    /// por elas enquanto o JS pode estar ocupado, e um `queue.sync` ali prendia o Ctrl+C.
    let portas = Mutex<[Int: Int]>([:])

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
                if semRef.remove(id) == nil {
                    endWork()
                }
            }
        }
        installHost()
    }

    // MARK: saída

    /// Uma linha inteira (console.log e as mensagens do próprio runtime).
    func emit(_ kind: OutputKind, _ text: String) {
        if interrompido.load(ordering: .relaxed) {
            return
        }
        if let bruta = saidaBruta {
            bruta(kind, Data((text + "\n").utf8))
            return
        }
        if let parcial = linhaParcial[kind], !parcial.isEmpty {
            // `process.stdout.write("a"); console.log("b")` é "ab", como no terminal.
            linhaParcial[kind] = nil
            output?(kind, Self.linhaNaTela(parcial) + text)
            return
        }
        output?(kind, text)
    }

    /// Bytes de `process.stdout.write`: não terminam linha sozinhos.
    func emitirBruto(_ kind: OutputKind, _ dados: Data) {
        if interrompido.load(ordering: .relaxed) || dados.isEmpty {
            return
        }
        if let bruta = saidaBruta {
            bruta(kind, dados)
            return
        }
        var acumulado = linhaParcial[kind] ?? Data()
        acumulado.append(dados)
        while let fim = acumulado.firstIndex(of: 0x0A) {
            let linha = acumulado[acumulado.startIndex ..< fim]
            output?(kind, Self.linhaNaTela(Data(linha)))
            acumulado = Data(acumulado[(fim + 1)...])
        }
        linhaParcial[kind] = acumulado
    }

    /// O que sobrou sem `\n` no fim vai como última linha.
    func despejarLinhas() {
        for kind in [OutputKind.out, .err] {
            if let resto = linhaParcial[kind], !resto.isEmpty {
                linhaParcial[kind] = nil
                if !interrompido.load(ordering: .relaxed) {
                    output?(kind, Self.linhaNaTela(resto))
                }
            }
        }
    }

    static func linhaNaTela(_ bytes: Data) -> String {
        LinhaDeTerminal.texto(bytes)
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
        host.setObject(modoProcesso, forKeyedSubscript: "modoProcesso" as NSString)
        host.setObject(entrada != nil, forKeyedSubscript: "temStdin" as NSString)
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

    /// Entra no JS por uma tarefa do laço (timer, requisição, fetch, o próprio main).
    ///
    /// Num processo a entrada passa por `__odete_entrar`, que roda a fila do `nextTick`
    /// antes de devolver — o JSC só roda as promises quando a chamada volta, e no Node o
    /// `nextTick` vem antes delas. Depois, com as promises já rodadas, `__odete_depoisDaTarefa`
    /// confere as rejeições que ninguém tratou, como o Node faz ao fim de cada tarefa.
    func call(_ name: String, _ args: [Any]) {
        if modoProcesso, let entrar = context.objectForKeyedSubscript("__odete_entrar"), entrar.isObject {
            entrar.call(withArguments: [name] + args)
            if !exited, let depois = context.objectForKeyedSubscript("__odete_depoisDaTarefa"), depois.isObject {
                depois.call(withArguments: [])
            }
            return
        }
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

    /// Quem espera o laço esvaziar é avisado na próxima volta da fila, nunca no meio de uma
    /// chamada ao JS: o `clearTimeout` de dentro de um callback deixava o processo terminar
    /// com o callback ainda rodando, e o `beforeExit` precisa chamar o JS de novo.
    func checkIdle() {
        guard pending <= 0, keepAlive <= 0, !idleWaiters.isEmpty, !ociosoAgendado else { return }
        ociosoAgendado = true
        queue.async { [weak self] in
            guard let self else { return }
            ociosoAgendado = false
            guard pending <= 0, keepAlive <= 0 else { return }
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
            if semRef.remove(id) == nil {
                endWork()
            }
        }
    }

    /// `timer.unref()`/`ref()`: um timer sem ref continua disparando, mas não segura o
    /// processo — o `setInterval(...).unref()` do node-cache deixava o `node` preso para
    /// sempre.
    func refTimer(_ id: Int, _ ref: Bool) {
        guard agenda.existe(id) else { return }
        if ref {
            if semRef.remove(id) != nil {
                beginWork()
            }
        } else if !semRef.contains(id) {
            semRef.insert(id)
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
        semRef.removeAll()
        pending = 0
        keepAlive = 0
        despejarLinhas()
        onExit?(code)
        checkIdle()
    }

    /// Solta o que prende o mundo de fora depois que o processo terminou: `onExit` (que
    /// segurava o próprio runtime), a saída (que segura a sessão do terminal), o transformador
    /// e os servidores. Sem isso cada `node`/`npx` deixava o contexto JS inteiro vivo.
    func encerrar() {
        despejarLinhas()
        onExit = nil
        idleWaiters.removeAll()
        output = nil
        saidaBruta = nil
        transform = nil
        transformEntrada = nil
        serversBox?.stopAll()
        portas.withLock { $0.removeAll() }
        for fd in descritores {
            Darwin.close(fd)
        }
        descritores.removeAll()
    }

    /// Um `Uint8Array` com a cópia de `dados`, para passar a `call`.
    func bytes(_ dados: Data) -> JSValue {
        HostBytes.valor(dados, em: context)
    }

    /// Num processo morto com Ctrl+C e preso em JS síncrono, a próxima chamada ao host lança
    /// um erro que o `runGuard` reconhece como saída (`__odeteExit`): o laço que escreve ou
    /// mexe em arquivo para ali, em vez de girar para sempre sem ninguém esperando.
    @discardableResult
    func lancarSeInterrompido() -> Bool {
        guard interrompido.load(ordering: .relaxed) else { return false }
        if let c = JSContext.current(), let e = JSValue(newErrorFromMessage: "process interrupted", in: c) {
            e.setValue(true, forProperty: "__odeteExit")
            c.exception = e
        }
        return true
    }

    // MARK: confinamento

    /// O caminho pode ser usado? Nil quando pode; o erro no formato do HostFs quando não.
    func foraDoProjeto(_ caminho: String, seguirUltimo: Bool = true) -> [String: Any]? {
        guard let c = confinamento, !c.permite(caminho, seguirUltimo: seguirUltimo) else { return nil }
        return HostFs.err("EACCES", caminho, tr("fora da pasta do projeto"))
    }
}

/// O transformador do módulo de entrada. Precisa de dois passos do esbuild que o de sempre
/// (`JSRuntime.transform`) não dá: rebaixar `async`/`await` para a Promise do runtime — só
/// assim um `main()` que rejeita sem `catch` é visto, porque a promise nativa de uma função
/// async não avisa ninguém — e tirar só os tipos (saída ESM), para achar os imports quando
/// o módulo usa top-level await, que o formato CJS não aceita.
public struct TransformadorDeEntrada: Sendable {
    /// ESM, TS ou CJS → CJS com async/await rebaixado.
    public var paraCJS: @Sendable (String, String) throws -> String
    /// ESM/TS → ESM sem tipos.
    public var paraESM: @Sendable (String, String) throws -> String

    public init(
        paraCJS: @escaping @Sendable (String, String) throws -> String,
        paraESM: @escaping @Sendable (String, String) throws -> String
    ) {
        self.paraCJS = paraCJS
        self.paraESM = paraESM
    }
}

/// Uma linha de saída como o terminal a mostra.
public enum LinhaDeTerminal {
    /// UTF-8 (byte inválido vira U+FFFD) e o `\r` de barra de progresso reescrevendo o
    /// começo da linha: "50%\r100%" aparece como "100%".
    public static func texto(_ bytes: some DataProtocol) -> String {
        let texto = String(decoding: bytes, as: UTF8.self)
        guard texto.contains("\r") else { return texto }
        var tela = ""
        for pedaco in texto.split(separator: "\r", omittingEmptySubsequences: false) where !pedaco.isEmpty {
            tela = String(pedaco) + String(tela.dropFirst(pedaco.count))
        }
        return tela
    }
}
