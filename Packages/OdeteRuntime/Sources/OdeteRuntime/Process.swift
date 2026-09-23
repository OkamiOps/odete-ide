import Foundation
import JavaScriptCore
import Synchronization

/// Um processo JavaScript: `node arquivo.js` ou um script inline.
public final class JSProcess: @unchecked Sendable {
    /// O runtime enquanto o processo não terminou. Ao terminar ele é solto: o contexto JS
    /// (dezenas de MB) e o closure de saída (que prende a sessão do terminal) não sobrevivem
    /// ao processo, mesmo que alguém ainda segure o `JSProcess` — um job na lista do shell,
    /// por exemplo. Antes o `onExit` guardado no próprio runtime o prendia para sempre.
    private let atual: Mutex<JSRuntime?>
    public let cwd: URL
    /// Quem espera o `run` voltar. Fica aqui, e não na fila do runtime, porque o Ctrl+C
    /// precisa soltar o terminal mesmo com a fila presa num laço síncrono.
    private let espera = Mutex<CheckedContinuation<Int32, Never>?>(nil)
    private let concluido = Mutex<Int32?>(nil)

    /// O runtime vivo, ou nil depois que o processo terminou.
    var rt: JSRuntime? {
        atual.withLock { $0 }
    }

    /// - Parameters:
    ///   - raiz: a pasta do projeto. Com ela o `fs` (e o `require`) só mexe ali dentro, na
    ///     pasta temporária do app e nos recursos do runtime; sem ela, em todo lugar.
    ///   - stdin: o que chega pelo pipe (`echo x | node s.js`).
    public init(
        cwd: URL,
        env: [String: String] = [:],
        argv: [String] = [],
        raiz: URL? = nil,
        stdin: Data? = nil,
        output: @escaping @Sendable (OutputKind, String) -> Void
    ) {
        self.cwd = cwd
        var e = env
        e["HOME"] = cwd.path
        e["PWD"] = cwd.path
        e["NODE_ENV"] = e["NODE_ENV"] ?? "development"
        e["ODETE"] = "1"
        // O terminal da Odete mostra texto puro: escapes ANSI viram lixo na tela. O stdout
        // diz que é TTY (há CLIs que só escrevem progresso num TTY), então quem decide cor
        // pelo TTY — o `tsc`, por exemplo — precisa do aviso de https://no-color.org.
        e["NO_COLOR"] = e["NO_COLOR"] ?? "1"
        let rt = JSRuntime(cwd: cwd, env: e, argv: argv)
        rt.output = output
        rt.modoProcesso = true
        rt.entrada = stdin
        if let raiz {
            // Além do projeto, a pasta temporária do app (o `os.tmpdir()`), os recursos do
            // próprio runtime (o executor de testes embutido é um script de lá) e o cache do
            // `npx -y`, de onde roda o que não está instalado no projeto.
            let npx = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "odete-npx", directoryHint: .isDirectory)
            rt.confinamento = Confinamento(
                raiz: raiz,
                extras: [FileManager.default.temporaryDirectory, Bundle.module.bundleURL, npx]
            )
        }
        ModuleLoader.install(rt)
        atual = Mutex(rt)
    }

    /// Transformador TS/ESM → CJS (esbuild) injetado pelo bundler. `versao` identifica o
    /// transformador para o cache em disco da saída (sem ela nada é guardado).
    public func setTransform(_ t: @escaping @Sendable (String, String) throws -> String, versao: String? = nil) {
        guard let rt else { return }
        rt.queue.sync {
            rt.transform = t
            rt.versaoDoTransformador = versao
        }
    }

    /// O transformador do módulo de entrada (async rebaixado e top-level await).
    public func setTransformDaEntrada(_ t: TransformadorDeEntrada) {
        guard let rt else { return }
        rt.queue.sync { rt.transformEntrada = t }
    }

    /// Recebe stdout/stderr em bytes crus, sem montar linhas: para quem redireciona para
    /// arquivo (binário inteiro) e junta os `write`s parciais do jeito dele.
    public func setSaidaBruta(_ s: @escaping @Sendable (OutputKind, Data) -> Void) {
        guard let rt else { return }
        rt.queue.sync { rt.saidaBruta = s }
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

    /// Solta quem espera no `run`, uma vez só, de qualquer thread.
    private func concluir(_ codigo: Int32) {
        let c = espera.withLock { e -> CheckedContinuation<Int32, Never>? in
            defer { e = nil }
            return e
        }
        concluido.withLock { if $0 == nil { $0 = codigo } }
        c?.resume(returning: codigo)
    }

    private func start(_ body: @escaping @Sendable (JSRuntime) throws -> Void) async -> Int32 {
        guard let rt else { return concluido.withLock { $0 } ?? 1 } // já terminou: roda uma vez só
        return await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let jaMorto = concluido.withLock { $0 }
            if let jaMorto {
                cont.resume(returning: jaMorto); return
            }
            espera.withLock { $0 = cont }
            rt.queue.async { [weak self, rt] in
                var finished = false
                let finish: () -> Void = {
                    guard !finished else { return }
                    finished = true
                    let codigo = rt.exitCode
                    // Quebra o ciclo runtime → onExit → finish → runtime e solta o runtime.
                    rt.encerrar()
                    self?.atual.withLock { $0 = nil }
                    self?.concluir(codigo)
                }
                rt.onExit = { _ in rt.queue.async { finish() } }
                if rt.interrompido.load(ordering: .relaxed) {
                    rt.exit(130); finish(); return
                }
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
                Self.quandoOcioso(rt, finish)
            }
        }
    }

    /// O laço esvaziou: `beforeExit` (que pode agendar mais trabalho e adiar a saída), depois
    /// `exit`, como no Node. Roda na fila do runtime, fora de qualquer chamada ao JS.
    private static func quandoOcioso(_ rt: JSRuntime, _ finish: @escaping () -> Void) {
        if rt.exited {
            finish(); return
        }
        if rt.pending > 0 || rt.keepAlive > 0 {
            rt.idleWaiters.append { quandoOcioso(rt, finish) }
            return
        }
        rt.call("__odete_antesDeSair", [])
        if rt.exited {
            finish(); return
        }
        if rt.pending > 0 || rt.keepAlive > 0 {
            rt.idleWaiters.append { quandoOcioso(rt, finish) }
            return
        }
        rt.call("__odete_aoSair", [rt.scriptExitCode])
        rt.exit(rt.scriptExitCode)
        finish()
    }

    /// Encerra à força (Ctrl+C, `kill %1`). O terminal é solto na hora com 130, mesmo que o
    /// JS esteja preso num laço síncrono — a fila dele não voltaria para rodar o `exit`. A
    /// marca `interrompido` corta a saída e faz toda chamada ao host lançar, o que derruba o
    /// laço que escreve ou mexe em arquivo; o `exit` de verdade roda quando a fila voltar.
    public func kill() {
        guard let rt else { return }
        rt.interrompido.store(true, ordering: .relaxed)
        concluir(130)
        rt.portas.withLock { $0.removeAll() }
        rt.queue.async { [weak self, rt] in
            rt.serversBox?.stopAll()
            rt.exit(130)
            rt.encerrar()
            self?.atual.withLock { $0 = nil }
        }
    }

    /// Portas HTTP abertas por este processo.
    public var ports: [Int] {
        guard let rt else { return [] }
        return rt.portas.withLock { $0.sorted { $0.key < $1.key }.map(\.value) }
    }

    /// Manda um evento de reload para todos os clientes WebSocket (dev server).
    public func broadcast(_ text: String) {
        guard let rt else { return }
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
