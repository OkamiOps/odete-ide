import Foundation
@testable import OdeteShell
import Synchronization
import Testing

struct ParserTests {
    @Test func words() throws {
        let c = try Parser.parse(#"echo "olá mundo" 'a b' c\ d $HOME ${USER}x"#, env: ["HOME": "/h", "USER": "u"])
        #expect(c.items[0].pipeline.commands[0].argv == ["echo", "olá mundo", "a b", "c d", "/h", "ux"])
    }

    @Test func pipesAndRedirects() throws {
        let c = try Parser.parse("cat a.txt | grep x > out.txt; ls >> log 2>&1 && echo ok || echo falhou & ")
        #expect(c.items.count == 4)
        let p0 = c.items[0].pipeline
        #expect(p0.commands.count == 2 && p0.commands[1].stdoutFile == "out.txt" && !p0.commands[1].append)
        #expect(c.items[1].link == .always && c.items[1].pipeline.commands[0].append && c.items[1].pipeline.commands[0]
            .stderrToStdout)
        #expect(c.items[2].link == .andThen && c.items[3].link == .orElse && c.items[3].pipeline.background)
    }

    @Test func errors() throws {
        #expect(throws: ParseError.unterminatedQuote) { try Parser.parse("echo \"x") }
        #expect(throws: ParseError.emptyCommand) { try Parser.parse("| x") }
        // O que não existe precisa falhar alto: passando como texto, um
        // `git commit -m "$(cat <<'EOF' … EOF)"` virava commit com a sopa na mensagem.
        #expect(throws: ParseError.semSubstituicao) { try Parser.parse("echo $(date)") }
        #expect(throws: ParseError.semSubstituicao) { try Parser.parse("echo \"hoje: $(date)\"") }
        #expect(throws: ParseError.semSubstituicao) { try Parser.parse("echo `date`") }
        #expect(throws: ParseError.semHeredoc) { try Parser.parse("cat <<'EOF'") }
        // Dentro de aspas simples continua sendo texto, como em qualquer shell.
        #expect(try Parser.parse("echo '$(date)'").items[0].pipeline.commands[0].argv == ["echo", "$(date)"])
        let empty = try Parser.parse("   # só comentário")
        #expect(empty.items.isEmpty)
    }
}

final class Out: Sendable {
    let lines = Mutex<[(StreamKind, String)]>([])
    var sink: @Sendable (StreamKind, String) -> Void {
        { k, t in self.lines.withLock { $0.append((k, t)) } }
    }

    var out: String {
        lines.withLock { $0.filter { $0.0 == .out }.map(\.1).joined(separator: "\n") }
    }

    var err: String {
        lines.withLock { $0.filter { $0.0 == .err }.map(\.1).joined(separator: "\n") }
    }
}

func project() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appending(
        path: "odete-sh-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: u.appending(path: "src"), withIntermediateDirectories: true)
    try "linha um\nlinha dois\nfoo bar\n".write(to: u.appending(path: "a.txt"), atomically: true, encoding: .utf8)
    try "console.log('oi', process.argv.slice(2).join(','));".write(
        to: u.appending(path: "src/hi.js"),
        atomically: true,
        encoding: .utf8
    )
    return u
}

@Suite(.serialized) struct ShellTests {
    @Test func builtinsPipesRedirects() async throws {
        let root = try project()
        let sh = Shell(root: root)
        let o = Out()
        #expect(await sh.run("pwd; ls; cat a.txt | grep -n linha; wc -l a.txt", sink: o.sink) == 0)
        #expect(o.out.contains("~") && o.out.contains("a.txt  src/") && o.out.contains("1:linha um") && o.out
            .contains("2:linha dois"))
        #expect(o.out.contains("3 a.txt"))
        _ = await sh.run(
            "echo primeira > n.txt && echo segunda >> n.txt && cat n.txt | tail -n 1 && mkdir -p x/y && cd x/y && pwd && cd && pwd",
            sink: o.sink
        )
        #expect(o.out.hasSuffix("segunda\n~/x/y\n~"))
        let o2 = Out()
        #expect(await sh.run("nao-existe", sink: o2.sink) == 127)
        #expect(o2.err.contains("não encontrado"))
        #expect(await sh.run("false || echo caiu", sink: o2.sink) == 0 && o2.out.contains("caiu"))
        #expect(await sh.run("cd /etc", sink: o2.sink) == 1)
        _ = await sh.run("cp a.txt b.txt && mv b.txt c.txt && rm c.txt && ls", sink: o2.sink)
        #expect(!o2.out.contains("c.txt"))
        #expect(sh.history.count >= 5)
        #expect(sh.complete("a.").contains("a.txt") && sh.complete("s") == ["src/"])
    }

    @Test func gitThroughShell() async throws {
        let root = try project()
        let sh = Shell(root: root)
        let o = Out()
        #expect(await sh.run("git status", sink: o.sink) == 128)
        #expect(await sh.run(
            "git init && git add . && git commit -m \"primeiro\" && git log --oneline && git status",
            sink: o.sink
        ) == 0)
        #expect(o.out.contains("primeiro") && o.out.contains("working tree limpa"))
        _ = await sh.run("echo x >> a.txt && git status && git diff a.txt", sink: o.sink)
        #expect(o.out.contains("M  a.txt") && o.out.contains("+x"))
        _ = await sh.run("git checkout -b feat && git branch", sink: o.sink)
        #expect(o.out.contains("* feat"))
    }

    @Test func nodeAndScripts() async throws {
        let root = try project()
        let sh = Shell(root: root)
        let o = Out()
        #expect(await sh.run("node src/hi.js a b", sink: o.sink) == 0)
        #expect(o.out.contains("oi a,b"))
        _ = await sh.run(
            "node -e \"console.log(require('fs').readFileSync('a.txt','utf8').split('\\\\n').length)\"",
            sink: o.sink
        )
        #expect(o.out.contains("4"))
        try #"{"name":"p","scripts":{"hello":"node src/hi.js do-script","chain":"echo a && echo b"}}"#.write(
            to: root.appending(path: "package.json"),
            atomically: true,
            encoding: .utf8
        )
        let o2 = Out()
        #expect(await sh.run("npm run hello && npm run chain && npm run nada", sink: o2.sink) == 1)
        #expect(o2.out.contains("oi do-script") && o2.out.contains("a\nb") && o2.err.contains("não existe"))
    }

    @Test func serverBecomesJob() async throws {
        let root = try project()
        try "require('http').createServer((q, s) => s.end('pong')).listen(4611, () => console.log('ouvindo'));".write(
            to: root.appending(path: "srv.js"),
            atomically: true,
            encoding: .utf8
        )
        let ports = Mutex<[Int]>([])
        let sh = Shell(root: root, services: ShellServices(onServer: { p, _ in ports.withLock { $0.append(p) } }))
        let o = Out()
        #expect(await sh.run("node srv.js", sink: o.sink) == 0)
        #expect(sh.jobs.count == 1 && sh.jobs[0].ports == [4611] && ports.withLock { $0 } == [4611])
        #expect(o.out.contains("job 1"))
        let (d, _) = try await URLSession.shared.data(from: #require(URL(string: "http://127.0.0.1:4611/")))
        #expect(String(decoding: d, as: UTF8.self) == "pong")
        _ = await sh.run("jobs && kill %1", sink: o.sink)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sh.jobs.isEmpty && o.out.contains("[1] node srv.js"))
    }

    @MainActor
    @Test func sessionLinesAndHistory() async throws {
        let root = try project()
        let s = TerminalSession(shell: Shell(root: root))
        s.input = "echo olá"
        s.submit()
        while s.running != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(s.lines.map(\.text).contains("olá") && s.lines.first?.kind == .system)
        s.historyUp()
        #expect(s.input == "echo olá")
        s.historyDown()
        #expect(s.input == "")
        s.input = "cat a."
        s.tab()
        #expect(s.input == "cat a.txt")
    }
}

/// Ciclo de vida do job de servidor. Um job que continua na lista depois de morto faz o
/// app inteiro mentir: chip de "1 job", porta no rodapé e preview de uma página que já
/// não é servida.
struct JobTests {
    func shell() -> Shell {
        let raiz = FileManager.default.temporaryDirectory.appending(path: "odete-job-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
        return Shell(root: raiz)
    }

    @Test func matarTiraODaLista() {
        let sh = shell()
        let parado = Mutex(false)
        let job = sh.registerJob("vite", ports: [5173]) { parado.withLock { $0 = true } }
        #expect(sh.jobs.count == 1)
        job.kill()
        #expect(parado.withLock { $0 })
        #expect(job.finished)
        #expect(sh.jobs.isEmpty)
    }

    @Test func doisKillsNaoParamDuasVezes() {
        let sh = shell()
        let vezes = Mutex(0)
        let job = sh.registerJob("vite", ports: [5173]) { vezes.withLock { $0 += 1 } }
        job.kill()
        job.kill()
        #expect(vezes.withLock { $0 } == 1)
    }

    @Test func killAllLimpaTudoEAvisa() {
        let sh = shell()
        let avisos = Mutex(0)
        sh.onJobsChanged = { avisos.withLock { $0 += 1 } }
        _ = sh.registerJob("vite", ports: [5173]) {}
        _ = sh.registerJob("node", ports: [3000]) {}
        sh.killAll()
        #expect(sh.jobs.isEmpty)
        #expect(avisos.withLock { $0 } > 0)
    }
}
