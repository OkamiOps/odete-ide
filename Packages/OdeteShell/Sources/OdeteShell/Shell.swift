import Foundation
import OdeteBundler
import OdeteCore
import OdeteGit
import OdeteI18n
import OdeteNpm
import OdeteRuntime
import Synchronization

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
    /// Servidor de dev já no ar neste projeto, venha da aba que vier.
    public var servidorAtivo: (@Sendable () -> (porta: Int, comando: String)?)?

    public init(
        author: @escaping @Sendable () -> Signature = { Signature(name: "Odete", email: "odete@local") },
        credentials: @escaping @Sendable (String) -> Credentials? = { _ in nil },
        registry: any RegistryClient = HTTPRegistry(),
        onServer: @escaping @Sendable (Int, String) -> Void = { _, _ in },
        onDiagnostics: @escaping @Sendable ([Diagnostic]) -> Void = { _ in },
        onKillAll: (@Sendable () -> Void)? = nil,
        servidorAtivo: (@Sendable () -> (porta: Int, comando: String)?)? = nil
    ) {
        self.author = author; self.credentials = credentials; self.registry = registry; self.onServer = onServer; self
            .onDiagnostics = onDiagnostics
        self.onKillAll = onKillAll
        self.servidorAtivo = servidorAtivo
    }
}

/// Um job em segundo plano (servidor, `&`).
public final class Job: @unchecked Sendable, Identifiable {
    public let id: Int
    public let command: String
    public private(set) var ports: [Int] = []
    let stop: @Sendable () -> Void
    public private(set) var finished = false
    /// O cancelamento do job: `kill %N` o dispara, e o `node` de dentro morre junto.
    let cancelamento: Cancelamento
    /// Quem tira o job da lista quando ele acaba. O `stop` só desliga a coisa; sem isto
    /// o job continuava listado para sempre e o app dizia que o servidor estava no ar
    /// depois de o socket já ter morrido.
    var onFinish: (@Sendable (Job) -> Void)?
    private let trava = NSLock()

    init(id: Int, command: String, cancelamento: Cancelamento = Cancelamento(), stop: @escaping @Sendable () -> Void) {
        self.id = id; self.command = command; self.stop = stop; self.cancelamento = cancelamento
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
        cancelamento.cancelar()
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
    /// Os cancelamentos das linhas em primeiro plano agora (a do terminal e as de dentro
    /// dela, como o script de um `npm run`). O Ctrl+C dispara estes e só estes: os jobs em
    /// segundo plano têm o seu, que só o `kill` dispara.
    private let emPrimeiroPlano = Mutex<[ObjectIdentifier: Cancelamento]>([:])
    /// A pasta de antes do último `cd` (o `cd -`).
    public private(set) var cwdAnterior: URL?
    public var onJobsChanged: (@Sendable () -> Void)?
    /// Código de saída do último pipeline que terminou em primeiro plano neste terminal:
    /// o `$?`. Fica de uma linha para a outra, como no sh.
    public private(set) var ultimoCodigo: Int32 = 0

    /// Ligado enquanto a linha do terminal roda os comandos dela.
    ///
    /// O `npm run` roda o script chamando `run` de novo, de dentro do comando. Essa linha de
    /// dentro é o `sh -c` do script: tem o próprio `$?`, que começa em 0, e não pode mexer
    /// no do terminal — num job em segundo plano ela terminaria quando bem entendesse, no
    /// meio de outra linha.
    @TaskLocal static var dentroDeUmComando = false

    /// O cancelamento de quem está rodando esta linha: a de fora (terminal) ou um job. A linha
    /// de dentro de um comando cria o seu como filho deste.
    @TaskLocal static var cancelamentoAtual: Cancelamento?

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
            // Com o nome: `yarn` sozinho instala e `yarn dev` roda o script.
            return NpmCommand(chamadoComo: n)
        }
        return nil
    }

    // MARK: execução

    /// Ctrl+C: para o que roda em primeiro plano neste terminal — não os jobs.
    public func cancel() {
        let todos = emPrimeiroPlano.withLock { Array($0.values) }
        todos.forEach { $0.cancelar() }
    }

    /// Executa uma linha inteira. `sink` recebe a saída para a tela.
    @discardableResult
    public func run(_ line: String, sink: @escaping @Sendable (StreamKind, String) -> Void) async -> Int32 {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        let deDentro = Self.dentroDeUmComando
        if !deDentro {
            remember(trimmed)
        }
        // A linha do terminal tem cancelamento próprio, que o Ctrl+C alcança; a de dentro de
        // um comando (ou de um job) herda o de quem a chamou.
        let pai = deDentro ? Self.cancelamentoAtual : nil
        let cancelamento = Cancelamento(pai: pai)
        let chave = ObjectIdentifier(cancelamento)
        if pai == nil {
            emPrimeiroPlano.withLock { $0[chave] = cancelamento }
        }
        defer {
            if pai == nil {
                emPrimeiroPlano.withLock { _ = $0.removeValue(forKey: chave) }
            }
        }
        // O `$?` que esta linha enxerga: o da linha anterior, ou 0 no script de um comando.
        var status: Int32 = deDentro ? 0 : ultimoCodigo
        func anotar(_ codigo: Int32) {
            status = codigo
            if !deDentro {
                ultimoCodigo = codigo
            }
        }
        let linha: LinhaCrua
        do { linha = try Parser.separar(trimmed) } catch {
            sink(.err, "odete: \(error.localizedDescription)")
            anotar(2)
            return 2
        }
        var last: Int32 = 0
        // Um montador de linhas para a linha toda: `echo -n x; echo y` sai "xy".
        let montador = MontadorDeLinhas(sink)
        defer { montador.fechar() }
        await Self.$dentroDeUmComando.withValue(true) {
            await Self.$cancelamentoAtual.withValue(cancelamento) {
                for (link, crua) in linha.items {
                    if cancelamento.cancelado {
                        last = 130
                        break
                    }
                    switch link {
                    case .andThen where last != 0: continue
                    case .orElse where last == 0: continue
                    default: break
                    }
                    // Expandido agora, e não antes da linha: em `cmd; echo $?` o `$?` é o do `cmd`,
                    // e em `export X=1; echo $X` o `X` já é o novo. Os curingas (`*.ts`) também.
                    let pipeline = crua.expandido({ [self] in valor(de: $0, status: status) }, glob: { [self] in
                        expandirGlob($0)
                    })
                    if pipeline.background {
                        let text = pipeline.commands.map { $0.argv.joined(separator: " ") }.joined(separator: " | ")
                        startJob(text) { [self] in
                            let m = MontadorDeLinhas(sink)
                            defer { m.fechar() }
                            return await runPipeline(pipeline, sink: sink, montador: m)
                        }
                        last = 0 // como no sh: `cmd &` sai com 0 na hora
                    } else {
                        last = await runPipeline(pipeline, sink: sink, montador: montador)
                    }
                    anotar(last)
                }
            }
        }
        return last
    }

    /// O valor de `$nome` agora. `status` é o `$?` da linha que está expandindo.
    func valor(de nome: String, status: Int32) -> String {
        switch nome {
        case "?": String(status)
        // Não há processo por comando: tudo roda no processo do app, e o `$$` é o dele.
        case "$": String(ProcessInfo.processInfo.processIdentifier)
        // O terminal não recebe argumentos, então não há `$1`, `$2`…: `$#` é 0.
        case "#": "0"
        case "0": "odete"
        default: env[nome] ?? ""
        }
    }

    func runPipeline(
        _ p: CommandLine.Pipeline,
        sink: @escaping @Sendable (StreamKind, String) -> Void,
        montador: MontadorDeLinhas? = nil
    ) async -> Int32 {
        let montador = montador ?? MontadorDeLinhas(sink)
        var input: Data?
        var code: Int32 = 0
        for (i, simple) in p.commands.enumerated() {
            let isLast = i == p.commands.count - 1
            var stdin = input
            if let f = simple.stdinFile {
                if f == "/dev/null" {
                    stdin = Data()
                } else {
                    guard let u = arquivoDeRedirecionamento(f, sink: sink) else { return 1 }
                    guard let d = FileManager.default.contents(atPath: u.path) else {
                        sink(.err, tr("odete: %1$@: não existe", "\(f)")); return 1
                    }
                    stdin = d
                }
            }
            let capturing = !isLast || simple.stdoutFile != nil
            let io = CommandIO(stdinBytes: stdin, capturing: capturing, sink: sink, montador: montador)
            io.stderrToStdout = simple.stderrToStdout
            io.stdoutToStderr = simple.stdoutToStderr
            io.capturandoErro = simple.stderrFile != nil
            // Confere os destinos antes de rodar: um `> ../fora.txt` não roda o comando.
            var saida: URL?, erro: URL?
            if let f = simple.stdoutFile, f != "/dev/null" {
                guard let u = arquivoDeRedirecionamento(f, sink: sink) else { return 1 }
                saida = u
            }
            if let f = simple.stderrFile, f != "/dev/null" {
                guard let u = arquivoDeRedirecionamento(f, sink: sink) else { return 1 }
                erro = u
            }
            code = await runSimple(simple.argv, io: io)
            if let erro, !escrever(io.stderrCapturado, em: erro, anexar: simple.stderrAppend) {
                sink(.err, tr("odete: não consegui escrever %1$@", simple.stderrFile ?? "")); return 1
            }
            if simple.stdoutFile != nil {
                if let saida, !escrever(io.capturedData, em: saida, anexar: simple.append) {
                    sink(.err, tr("odete: não consegui escrever %1$@", simple.stdoutFile ?? "")); return 1
                }
                input = nil
            } else {
                input = capturing ? io.capturedData : nil
            }
        }
        return code
    }

    /// O arquivo de um `>`, `2>` ou `<`, dentro do projeto; fora, avisa e devolve nil.
    func arquivoDeRedirecionamento(_ f: String, sink: @Sendable (StreamKind, String) -> Void) -> URL? {
        let u = caminhoCru(f)
        guard Confinamento(raiz: root).permite(u.path) else {
            sink(.err, tr("odete: %1$@: fora da pasta do projeto", f))
            return nil
        }
        return u
    }

    /// Bytes no arquivo, do jeito que vieram (binário inclusive).
    func escrever(_ dados: Data, em u: URL, anexar: Bool) -> Bool {
        if !anexar {
            HistoricoDeArquivos.guardar(u, raiz: root, origem: .terminal)
        }
        let flags = O_WRONLY | O_CREAT | O_CLOEXEC | (anexar ? O_APPEND : O_TRUNC)
        let fd = open(u.path, flags, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var feito = 0
        return dados.withUnsafeBytes { b -> Bool in
            while feito < b.count, let base = b.baseAddress {
                let r = write(fd, base + feito, b.count - feito)
                if r < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                feito += r
            }
            return true
        }
    }

    /// `A=1` sozinho define a variável do shell; `A=1 cmd` só para o `cmd`, como no sh.
    /// Antes os dois davam "comando não encontrado: A=1" — inclusive nos scripts do npm.
    static func atribuicao(_ palavra: String) -> (String, String)? {
        guard let i = palavra.firstIndex(of: "="), i != palavra.startIndex else { return nil }
        let nome = palavra[..<i]
        guard let primeiro = nome.first, primeiro == "_" || primeiro.isLetter,
              nome.allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber }) else { return nil }
        return (String(nome), String(palavra[palavra.index(after: i)...]))
    }

    func runSimple(_ argvCompleto: [String], io: CommandIO) async -> Int32 {
        var argv = argvCompleto
        var extras: [String: String] = [:]
        while let primeiro = argv.first, let (k, v) = Self.atribuicao(primeiro) {
            extras[k] = v
            argv.removeFirst()
        }
        guard let name = argv.first else {
            for (k, v) in extras {
                env[k] = v
            }
            return 0
        }
        let cancelamento = Self.cancelamentoAtual ?? Cancelamento()
        let ctx = CommandContext(
            cwd: cwd,
            root: root,
            env: env.merging(extras) { _, novo in novo },
            io: io,
            shell: self,
            isCancelled: { cancelamento.cancelado || Task.isCancelled },
            cancelamento: cancelamento
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
            io.err(tr("odete: comando não encontrado: %1$@. Rode npm install primeiro.", "\(name)"))
        } else {
            io.err(tr("odete: comando não encontrado: %1$@. Digite help.", "\(name)"))
        }
        return 127
    }

    // MARK: glob

    /// Os caminhos que casam com o padrão, relativos como foram escritos, em ordem. Arquivo
    /// oculto só casa com padrão que começa por ponto; nada fora do projeto entra.
    func expandirGlob(_ padrao: String) -> [String] {
        var base: URL
        var prefixo: String
        var resto = padrao
        if resto.hasPrefix("/") {
            base = root; prefixo = "/"; resto.removeFirst()
        } else if resto.hasPrefix("~/") {
            base = root; prefixo = "~/"; resto.removeFirst(2)
        } else {
            base = cwd; prefixo = ""
        }
        let partes = resto.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !partes.isEmpty else { return [] }
        var candidatos: [(URL, String)] = [(base, prefixo)]
        let conf = Confinamento(raiz: root)
        for (n, parte) in partes.enumerated() {
            let ultima = n == partes.count - 1
            var proximos: [(URL, String)] = []
            let temCuringa = parte.contains(where: { $0 == "*" || $0 == "?" || $0 == "[" })
            for (dir, texto) in candidatos {
                if !temCuringa {
                    let literal = Self.semEscapes(parte)
                    let u = dir.appending(path: literal)
                    if ultima ? FileManager.default.fileExists(atPath: u.path) : Self.ehPasta(u) {
                        proximos.append((u, texto + literal + (ultima ? "" : "/")))
                    }
                    continue
                }
                guard let nomes = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
                for nome in nomes.sorted() {
                    if nome.hasPrefix("."), !parte.hasPrefix(".") {
                        continue
                    }
                    guard fnmatch(parte, nome, 0) == 0 else { continue }
                    let u = dir.appending(path: nome)
                    if !ultima, !Self.ehPasta(u) {
                        continue
                    }
                    proximos.append((u, texto + nome + (ultima ? "" : "/")))
                }
            }
            candidatos = proximos
            if candidatos.isEmpty {
                return []
            }
        }
        return candidatos.filter { conf.permite($0.0.path, seguirUltimo: false) }.map(\.1)
    }

    static func semEscapes(_ s: String) -> String {
        var r = ""
        var escapando = false
        for c in s {
            if c == "\\", !escapando {
                escapando = true; continue
            }
            escapando = false
            r.append(c)
        }
        return r
    }

    static func ehPasta(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }

    // MARK: jobs

    func startJob(_ text: String, _ body: @escaping @Sendable () async -> Int32) {
        let id = nextJob
        nextJob += 1
        let box = TaskBox()
        // Cancelamento próprio, sem pai: o Ctrl+C da linha em primeiro plano não chega aqui,
        // só o `kill`.
        let cancelamento = Cancelamento()
        let job = Job(id: id, command: text, cancelamento: cancelamento) { box.cancel() }
        job.onFinish = { [weak self] j in self?.removeJob(j) }
        lock.lock(); jobs.append(job); lock.unlock()
        onJobsChanged?()
        box.task = Task { [weak self] in
            _ = await Self.$cancelamentoAtual.withValue(cancelamento) {
                await body()
            }
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
        let job = Job(id: id, command: text, cancelamento: Cancelamento(), stop: stop)
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

    /// O caminho do jeito do shell (`/` e `~` são a raiz do projeto), sem conferir.
    func caminhoCru(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return root.appending(path: String(path.dropFirst())).standardizedFileURL
        }
        if path == "~" {
            return root
        }
        if path.hasPrefix("~/") {
            return root.appending(path: String(path.dropFirst(2))).standardizedFileURL
        }
        return cwd.appending(path: path).standardizedFileURL
    }

    /// O caminho resolvido; se sair do projeto (por `..` ou por link), um lugar onde nada
    /// existe nem pode ser criado (`CommandContext.foraDoProjeto`).
    public func resolvePath(_ path: String) -> URL {
        let u = caminhoCru(path)
        return Confinamento(raiz: root).permite(u.path) ? u : CommandContext.foraDoProjeto
    }

    /// Muda de pasta, só dentro do projeto. Antes o prefixo era comparado sem a `/`: `cd
    /// ../proj2` passava porque "/x/proj2" começa com "/x/proj".
    func setCwd(_ url: URL) -> Bool {
        let std = url.standardizedFileURL
        guard Self.ehPasta(std), Confinamento(raiz: root).permite(std.path) else { return false }
        if std.path != cwd.path {
            cwdAnterior = cwd
        }
        cwd = std
        env["PWD"] = std.path
        if let a = cwdAnterior {
            env["OLDPWD"] = a.path
        }
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

    /// O esbuild do projeto — o mesmo para todas as abas, o dev server e o lint do editor.
    ///
    /// Antes cada aba criava o seu, e cada um compila o módulo de 14 MB e segura a memória
    /// do Go dele. A aba guarda a referência forte: enquanto houver aba aberta no projeto, o
    /// motor não some entre um comando e outro.
    func esbuildEngine() -> Esbuild {
        lock.lock(); defer { lock.unlock() }
        if let e = esbuild {
            return e
        }
        let e = Esbuild.doProjeto(root)
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
