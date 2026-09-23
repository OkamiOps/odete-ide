import Foundation
import OdeteI18n
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

    /// As variáveis ficam anotadas na palavra e só viram texto na hora de rodar; aspas
    /// simples e `\$` continuam deixando o cifrão como texto.
    @Test func variaveisFicamParaDepois() throws {
        func palavras(_ linha: String) throws -> [Palavra] {
            try Parser.separar(linha).items[0].pipeline.commands[0].argv
        }
        #expect(try palavras("echo $? ${?}x \"c=$?\"") == [
            Palavra(pedacos: [.texto("echo")]),
            Palavra(pedacos: [.variavel("?")]),
            Palavra(pedacos: [.variavel("?"), .texto("x")]),
            // Texto entre aspas fica marcado como citado: não vira padrão de glob.
            Palavra(pedacos: [.citado("c="), .variavel("?")]),
        ])
        #expect(try palavras(#"echo '$?' \$? "\$?" a$ "$""#).map { $0.expandida { _ in "X" } }
            == ["echo", "$?", "$?", "$?", "a$", "$"])
        // Especiais e posicionais têm um caractere só, como no sh.
        #expect(try palavras("echo $?1 $10 $$ $# $HOME_x").map { $0.expandida { "<\($0)>" } }
            == ["echo", "<?>1", "<1>0", "<$>", "<#>", "<HOME_x>"])
        // Sem `}` o cifrão é texto, como era.
        #expect(try palavras("echo ${x").map { $0.expandida { _ in "X" } } == ["echo", "${x"])
        // Redirecionamento também expande na hora.
        let s = try Parser.separar("cat < $A > ${B}.txt").items[0].pipeline.commands[0]
        #expect(s.stdinFile == Palavra(pedacos: [.variavel("A")]))
        #expect(s.stdoutFile == Palavra(pedacos: [.variavel("B"), .texto(".txt")]))
    }

    /// `git push -u origin minha-branch`: contando pela posição crua, a branch virava
    /// "origin" e o push ia para o lugar errado.
    @Test func posicionaisDoPushIgnoramAsOpcoes() {
        let g = GitCommand()
        #expect(g.posicionais(["-u", "origin", "minha-branch"]) == ["origin", "minha-branch"])
        #expect(g.posicionais(["origin", "main"]) == ["origin", "main"])
        #expect(g.posicionais(["--force"]) == [])
        #expect(g.posicionais([]) == [])
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
    /// Os testes conferem a frase exata que está no código, que é o português. Sem
    /// travar o idioma, o mesmo teste passa no Mac e falha no simulador em inglês.
    init() {
        Texto.escolher(.ptBR)
    }

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

    /// Remoto bare dentro do próprio projeto: o jeito de testar push sem servidor no
    /// iPad. E `git restore` de arquivo não rastreado recusa em vez de apagar de vez.
    @Test func remotoLocalERestoreSemApagar() async throws {
        Texto.escolher(.ptBR)
        let root = try project()
        let sh = Shell(root: root)
        let o = Out()
        #expect(await sh.run(
            "git init && git add . && git commit -m \"primeiro\" && git init --bare .odete/remoto.git",
            sink: o.sink
        ) == 0)
        #expect(o.out.contains("bare"))
        #expect(await sh.run("git remote add origin .odete/remoto.git && git push origin main", sink: o.sink) == 0)
        #expect(await sh.run("git remote -v", sink: o.sink) == 0)
        #expect(o.out.contains("file://"))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: ".odete/remoto.git/refs/heads/main").path))

        try "trabalho\n".write(to: root.appending(path: "novo.txt"), atomically: true, encoding: .utf8)
        #expect(await sh.run("git restore novo.txt", sink: o.sink) == 1)
        #expect(o.err.contains("não é rastreado"))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "novo.txt").path))
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

    /// `npx vitest run; echo fim $?` imprimia `fim $?`: o `$?` não era reconhecido e, pior,
    /// a linha inteira se expandia antes do primeiro comando rodar.
    @Test func codigoDeSaida() async throws {
        let sh = try Shell(root: project())
        func saida(_ linha: String) async -> String {
            let o = Out()
            _ = await sh.run(linha, sink: o.sink)
            return o.out
        }
        #expect(await saida("false; echo $?") == "1")
        #expect(await saida("true && echo $?") == "0")
        #expect(await saida("false || echo $?") == "1")
        #expect(await saida("echo '$?'") == "$?")
        #expect(await saida(#"echo \$?"#) == "$?")
        #expect(await saida(#"node -e "process.exit(2)"; echo "c=$?""#) == "c=2")
        #expect(await saida("nao-existe; echo $?") == "127")
        // Um `&&` pulado não mexe no `$?`: continua o do último que rodou.
        #expect(await saida("false && echo nunca; echo $?") == "1")
        // Cada `$?` é o do pipeline de antes, não o do começo da linha.
        #expect(await saida("false; echo $?; echo $?") == "1\n0")
        // De uma linha para a outra do mesmo terminal, e com chaves.
        _ = await saida("false")
        #expect(sh.ultimoCodigo == 1)
        #expect(await saida("echo ${?}") == "1")
        #expect(await saida("echo $?") == "0")
        // Erro de sintaxe sai com 2, como no sh.
        #expect(await sh.run("echo \"sem fechar", sink: Out().sink) == 2)
        #expect(await saida("echo \"c=$?\"") == "c=2")
        // Job em segundo plano: `$?` é 0 na hora.
        #expect(await saida("false; true & echo $?") == "0")
        // O resto também expande na hora: o `export` do começo da linha já vale no fim.
        #expect(await saida("export COR=azul; echo $COR") == "azul")
        #expect(await saida("export A=1 && echo $A") == "1")
        #expect(await saida("export A=2 && echo \"a=${A}\"") == "a=2")
        #expect(await saida("echo $$ $#") == "\(ProcessInfo.processInfo.processIdentifier) 0")
    }

    /// O script do `npm run` é um `sh -c`: tem o próprio `$?`, que começa em 0, e não mexe
    /// no do terminal; quem fica no `$?` do terminal é o código do `npm`.
    @Test func codigoDeSaidaDoScript() async throws {
        let root = try project()
        try #"{"name":"p","scripts":{"mostra":"echo dentro=$?","falha":"false; true; false"}}"#.write(
            to: root.appending(path: "package.json"),
            atomically: true,
            encoding: .utf8
        )
        let sh = Shell(root: root)
        let o = Out()
        _ = await sh.run("false; npm run mostra; echo fora=$?", sink: o.sink)
        #expect(o.out.contains("dentro=0") && o.out.contains("fora=0"))
        let o2 = Out()
        _ = await sh.run("npm run falha; echo fora=$?", sink: o2.sink)
        #expect(o2.out.contains("fora=1"))
        #expect(sh.ultimoCodigo == 0)
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
