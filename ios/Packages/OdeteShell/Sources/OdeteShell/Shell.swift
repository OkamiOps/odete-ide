import Foundation
import OdeteBundler
import OdeteCore
import OdeteGit
import OdeteNpm
import OdeteRuntime

/// Serviços que o app injeta: git (autor, credenciais), npm (registro) e a saída.
public struct ShellServices: Sendable {
    public var author: @Sendable () -> Signature
    public var credentials: @Sendable (String) -> Credentials?
    public var registry: any RegistryClient
    public var onServer: @Sendable (Int, String) -> Void // porta aberta por um job (porta, comando)
    public var onDiagnostics: @Sendable ([Diagnostic]) -> Void
    /// Para tudo do projeto, não só desta aba. O servidor sobe numa aba e a pessoa
    /// tenta pará-lo de outra; sem isto o `kill` de lá não achava job nenhum.
    public var onKillAll: (@Sendable () -> Void)?

    public init(
        author: @escaping @Sendable () -> Signature = { Signature(name: "Odete", email: "odete@local") },
        credentials: @escaping @Sendable (String) -> Credentials? = { _ in nil },
        registry: any RegistryClient = HTTPRegistry(),
        onServer: @escaping @Sendable (Int, String) -> Void = { _, _ in },
        onDiagnostics: @escaping @Sendable ([Diagnostic]) -> Void = { _ in },
        onKillAll: (@Sendable () -> Void)? = nil
    ) {
        self.author = author; self.credentials = credentials; self.registry = registry; self.onServer = onServer; self
            .onDiagnostics = onDiagnostics
        self.onKillAll = onKillAll
    }
}

/// Um job em segundo plano (servidor, `&`).
public final class Job: @unchecked Sendable, Identifiable {
    public let id: Int
    public let command: String
    public private(set) var ports: [Int] = []
    let stop: @Sendable () -> Void
    public private(set) var finished = false
    /// Quem tira o job da lista quando ele acaba. O `stop` só desliga a coisa; sem isto
    /// o job continuava listado para sempre e o app dizia que o servidor estava no ar
    /// depois de o socket já ter morrido.
    var onFinish: (@Sendable (Job) -> Void)?
    private let trava = NSLock()

    init(id: Int, command: String, stop: @escaping @Sendable () -> Void) {
        self.id = id; self.command = command; self.stop = stop
    }

    func setPorts(_ p: [Int]) {
        ports = p
    }

    func finish() {
        trava.lock()
        if finished {
            trava.unlock(); return
        }
        finished = true
        trava.unlock()
        onFinish?(self)
    }

    /// Para o job. Dois `kill` seguidos no mesmo job não fazem o trabalho duas vezes.
    public func kill() {
        trava.lock()
        if finished {
            trava.unlock(); return
        }
        finished = true
        trava.unlock()
        stop()
        onFinish?(self)
    }
}

/// O shell da Odete: um por aba de terminal, todos sobre a mesma raiz de projeto.
public final class Shell: @unchecked Sendable {
    public let root: URL
    public private(set) var cwd: URL
    public var env: [String: String]
    public let services: ShellServices
    public private(set) var history: [String] = []
    public private(set) var jobs: [Job] = []
    private var nextJob = 1
    private let lock = NSLock()
    /// Esbuild compartilhado do projeto (carregado sob demanda).
    private var esbuild: Esbuild?
    public var devServer: DevServer?
    private var cancelFlag = false
    public var onJobsChanged: (@Sendable () -> Void)?

    public init(root: URL, services: ShellServices = ShellServices()) {
        self.root = root
        cwd = root
        self.services = services
        env = [
            "PATH": "/node_modules/.bin:/usr/local/bin",
            "HOME": root.path,
            "PWD": root.path,
            "USER": "odete",
            "SHELL": "/bin/odete",
            "TERM": "odete",
            "NODE_ENV": "development",
            "npm_config_registry": "https://registry.npmjs.org",
            "ODETE": "1",
        ]
        loadHistory()
    }

    public var commands: [ShellCommand] {
        Builtins.all + [GitCommand(), NpmCommand(), NodeCommand(), BinCommand()]
    }

    func command(named n: String) -> ShellCommand? {
        if let c = commands.first(where: { $0.name == n }) {
            return c
        }
        if n == "pnpm" || n == "yarn" || n == "bun" {
            return NpmCommand()
        }
        return nil
    }

    // MARK: execução

    public func cancel() {
        cancelFlag = true
    }

    /// Executa uma linha inteira. `sink` recebe a saída para a tela.
    @discardableResult
    public func run(_ line: String, sink: @escaping @Sendable (StreamKind, String) -> Void) async -> Int32 {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        remember(trimmed)
        cancelFlag = false
        let parsed: CommandLine
        do { parsed = try Parser.parse(trimmed, env: env) } catch { sink(
            .err,
            "odete: \(error.localizedDescription)"
        ); return 2 }
        var last: Int32 = 0
        for (link, pipeline) in parsed.items {
            switch link {
            case .andThen where last != 0: continue
            case .orElse where last == 0: continue
            default: break
            }
            if pipeline.background {
                let text = pipeline.commands.map { $0.argv.joined(separator: " ") }.joined(separator: " | ")
                startJob(text) { [self] in await runPipeline(pipeline, sink: sink) }
                last = 0
            } else {
                last = await runPipeline(pipeline, sink: sink)
            }
        }
        return last
    }

    func runPipeline(_ p: CommandLine.Pipeline, sink: @escaping @Sendable (StreamKind, String) -> Void) async -> Int32 {
        var input: String?
        var code: Int32 = 0
        for (i, simple) in p.commands.enumerated() {
            let isLast = i == p.commands.count - 1
            var stdin = input
            if let f = simple.stdinFile {
                let u = resolvePath(f)
                guard let s = try? String(contentsOf: u, encoding: .utf8) else { sink(
                    .err,
                    "odete: \(f): não existe"
                ); return 1 }
                stdin = s
            }
            let capturing = !isLast || simple.stdoutFile != nil
            let io = CommandIO(stdin: stdin, capturing: capturing, sink: sink)
            io.stderrToStdout = simple.stderrToStdout
            code = await runSimple(simple.argv, io: io)
            if let f = simple.stdoutFile {
                let u = resolvePath(f)
                do {
                    if simple.append,
                       let fh = FileHandle(forWritingAtPath: u.path)
                    {
                        try fh.seekToEnd(); try fh.write(contentsOf: Data(io.captured.utf8)); try fh.close()
                    } else {
                        try io.captured.write(to: u, atomically: true, encoding: .utf8)
                    }
                } catch { sink(.err, "odete: não consegui escrever \(f)"); return 1 }
                input = nil
            } else {
                input = capturing ? String(io.captured.dropLast(io.captured.hasSuffix("\n") ? 1 : 0)) : nil
            }
        }
        return code
    }

    func runSimple(_ argv: [String], io: CommandIO) async -> Int32 {
        guard let name = argv.first else { return 0 }
        let ctx = CommandContext(
            cwd: cwd,
            root: root,
            env: env,
            io: io,
            shell: self,
            isCancelled: { [weak self] in self?.cancelFlag ?? true }
        )
        if let c = command(named: name) {
            return await c.run(Array(argv.dropFirst()), ctx)
        }
        // arquivo .js/.ts direto ou binário de node_modules/.bin
        if name.hasSuffix(".js") || name.hasSuffix(".mjs") || name.hasSuffix(".cjs") || name.hasSuffix(".ts") || name
            .hasSuffix(".tsx")
        {
            return await NodeCommand().run(argv, ctx)
        }
        if BinCommand.binPath(name, root: root) != nil || BinCommand.substituidos.contains(name) {
            return await BinCommand().run(argv, ctx)
        }
        let temPacote = FileManager.default.fileExists(atPath: root.appending(path: "package.json").path)
        let temModulos = FileManager.default.fileExists(atPath: root.appending(path: "node_modules").path)
        if temPacote, !temModulos {
            io.err("odete: comando não encontrado: \(name). Rode npm install primeiro.")
        } else {
            io.err("odete: comando não encontrado: \(name). Digite help.")
        }
        return 127
    }

    // MARK: jobs

    func startJob(_ text: String, _ body: @escaping @Sendable () async -> Int32) {
        let id = nextJob
        nextJob += 1
        let box = TaskBox()
        let job = Job(id: id, command: text) { box.cancel() }
        job.onFinish = { [weak self] j in self?.removeJob(j) }
        lock.lock(); jobs.append(job); lock.unlock()
        onJobsChanged?()
        box.task = Task { [weak self] in
            _ = await body()
            job.finish()
            self?.removeJob(job)
        }
    }

    func removeJob(_ job: Job) {
        lock.lock(); jobs.removeAll { $0.id == job.id }; lock.unlock()
        onJobsChanged?()
    }

    /// Registra um processo de longa duração (servidor) como job já em execução.
    func registerJob(_ text: String, ports: [Int], stop: @escaping @Sendable () -> Void) -> Job {
        let id = nextJob
        nextJob += 1
        let job = Job(id: id, command: text, stop: stop)
        job.onFinish = { [weak self] j in self?.removeJob(j) }
        job.setPorts(ports)
        lock.lock(); jobs.append(job); lock.unlock()
        onJobsChanged?()
        for p in ports {
            services.onServer(p, text)
        }
        return job
    }

    public func killAll() {
        lock.lock(); let js = jobs; lock.unlock()
        for j in js {
            j.kill()
        }
        devServer?.stop(); devServer = nil
        onJobsChanged?()
    }

    // MARK: utilidades

    public func resolvePath(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return root.appending(path: String(path.dropFirst()))
        }
        if path == "~" {
            return root
        }
        if path.hasPrefix("~/") {
            return root.appending(path: String(path.dropFirst(2)))
        }
        return cwd.appending(path: path).standardizedFileURL
    }

    func setCwd(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let std = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: std.path, isDirectory: &isDir), isDir.boolValue,
              std.path.hasPrefix(root.standardizedFileURL.path) else { return false }
        cwd = std
        env["PWD"] = std.path
        return true
    }

    public var prompt: String {
        let r = cwd.standardizedFileURL.path, base = root.standardizedFileURL.path
        return r == base ? "~" : "~/" + String(r.dropFirst(base.count + 1))
    }

    /// Esbuild do projeto, para quem precisa transformar/lintar fora do terminal.
    public var bundler: Esbuild {
        esbuildEngine()
    }

    func esbuildEngine() -> Esbuild {
        lock.lock(); defer { lock.unlock() }
        if let e = esbuild {
            return e
        }
        let e = Esbuild(root: root)
        esbuild = e
        return e
    }

    private func remember(_ line: String) {
        if history.last != line {
            history.append(line)
        }
        if history.count > 500 {
            history.removeFirst(history.count - 500)
        }
        let u = root.appending(path: ".odete/history")
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? history.suffix(200).joined(separator: "\n").write(to: u, atomically: true, encoding: .utf8)
    }

    private func loadHistory() {
        if let s = try? String(contentsOf: root.appending(path: ".odete/history"), encoding: .utf8) {
            history = s.split(separator: "\n").map(String.init)
        }
    }

    /// Completa um caminho parcial (para o Tab).
    public func complete(_ partial: String) -> [String] {
        let dirPart = partial.contains("/") ? String(partial[...partial.lastIndex(of: "/")!]) : ""
        let prefix = String(partial.dropFirst(dirPart.count))
        let dir = dirPart.isEmpty ? cwd : resolvePath(dirPart)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return items.filter { $0.hasPrefix(prefix) && !$0.hasPrefix(".") }.sorted().map { name in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: dir.appending(path: name).path, isDirectory: &isDir)
            return dirPart + name + (isDir.boolValue ? "/" : "")
        }
    }
}

final class TaskBox: @unchecked Sendable {
    var task: Task<Void, Never>?
    func cancel() {
        task?.cancel()
    }
}
