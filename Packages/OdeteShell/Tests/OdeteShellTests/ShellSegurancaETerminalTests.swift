import Foundation
import OdeteI18n
@testable import OdeteShell
import Synchronization
import Testing

/// Um projeto e um vizinho lado a lado (`base/proj` e `base/proj2`), fora do tmp do app —
/// o tmp é liberado para o `node`, e o vizinho dentro dele passaria.
func projetoComVizinho() throws -> (raiz: URL, vizinho: URL) {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "odete-sh-\(UUID().uuidString)", directoryHint: .isDirectory)
    let raiz = base.appending(path: "proj"), vizinho = base.appending(path: "proj2")
    try FileManager.default.createDirectory(at: raiz.appending(path: "sub"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vizinho, withIntermediateDirectories: true)
    try "vizinho".write(to: vizinho.appending(path: "importante.txt"), atomically: true, encoding: .utf8)
    try "linha um\nlinha dois\nfoo bar\n".write(to: raiz.appending(path: "a.txt"), atomically: true, encoding: .utf8)
    return (raiz, vizinho)
}

/// Roda uma linha e devolve (código, stdout, stderr).
func linha(_ sh: Shell, _ l: String) async -> (Int32, String, String) {
    let o = Out()
    let c = await sh.run(l, sink: o.sink)
    return (c, o.out, o.err)
}

/// O shell não mexe fora do projeto (prova de 23/09/2026: `rm -rf ../OutroProjeto` apagou
/// outro projeto e `cd ../proj2` saía da raiz).
@Suite(.serialized) struct ShellSegurancaTests {
    init() {
        Texto.escolher(.ptBR)
    }

    @Test func naoSaiDoProjeto() async throws {
        let (raiz, vizinho) = try projetoComVizinho()
        defer { try? FileManager.default.removeItem(at: raiz.deletingLastPathComponent()) }
        let sh = Shell(root: raiz)
        let fm = FileManager.default
        for l in ["rm -rf ../proj2", "rm ../proj2/importante.txt", "cat ../proj2/importante.txt", "cp a.txt ../proj2/",
                  "mv a.txt ../proj2/", "mkdir ../proj2/novo", "touch ../proj2/novo.txt", "ls ..",
                  "grep x ../proj2/importante.txt",
                  "echo x > ../proj2/novo.txt", "cat < ../proj2/importante.txt", "node ../proj2/x.js", "find .."]
        {
            let (c, _, e) = await linha(sh, l)
            #expect(c != 0 && e.contains("fora da pasta do projeto"), Comment(rawValue: "\(l) → \(c) \(e)"))
        }
        #expect(fm.fileExists(atPath: vizinho.appending(path: "importante.txt").path))
        #expect(try fm.contentsOfDirectory(atPath: vizinho.path) == ["importante.txt"])
        #expect(fm.fileExists(atPath: raiz.appending(path: "a.txt").path))
        // `cd ../proj2`: o prefixo "…/proj" não pode valer para "…/proj2".
        let (c, _, e) = await linha(sh, "cd ../proj2")
        #expect(c == 1 && e.contains("não é uma pasta do projeto") && sh.cwd.path == raiz.path)
        #expect(await linha(sh, "cd sub/../..").0 == 1)
        // Link do projeto que aponta para fora: seguir não pode; apagar o link pode.
        try fm.createSymbolicLink(atPath: raiz.appending(path: "atalho").path, withDestinationPath: "../proj2")
        #expect(await linha(sh, "cat atalho/importante.txt").0 != 0)
        #expect(await linha(sh, "rm -rf atalho/").0 != 0)
        #expect(await linha(sh, "rm atalho").0 == 0)
        #expect(fm.fileExists(atPath: vizinho.appending(path: "importante.txt").path))
        #expect(await linha(sh, "rm -rf .").2.contains("raiz do projeto"))
    }

    /// `mv`/`cp` apagavam a pasta de destino antes de mover ou copiar por cima.
    @Test func mvECpNaoApagamPasta() async throws {
        let (raiz, _) = try projetoComVizinho()
        defer { try? FileManager.default.removeItem(at: raiz.deletingLastPathComponent()) }
        let sh = Shell(root: raiz)
        _ = await linha(sh, "mkdir -p d/x && echo guardado > d/x/keep.txt && mkdir -p e/x && echo novo > e/x/n.txt")
        #expect(await linha(sh, "cp -r e/x d").0 == 0)
        #expect(await linha(sh, "cat d/x/keep.txt d/x/n.txt").1 == "guardado\nnovo")
        #expect(await linha(sh, "mv e/x d").0 != 0) // d/x existe e não está vazia
        #expect(await linha(sh, "cat d/x/keep.txt").1 == "guardado")
        #expect(await linha(sh, "mv a.txt b.txt && ls").1.contains("b.txt"))
    }
}

@Suite(.serialized) struct ShellSintaxeTests {
    init() {
        Texto.escolher(.ptBR)
    }

    @Test func redirecionamentosDeErro() async throws {
        let raiz = try project()
        let sh = Shell(root: raiz)
        let (c, o, e) = await linha(sh, #"node -e "console.error('E'); console.log('O')" 2> err.txt"#)
        #expect(c == 0 && o == "O" && e.isEmpty, Comment(rawValue: e))
        #expect(try String(contentsOf: raiz.appending(path: "err.txt"), encoding: .utf8) == "E\n")
        let (_, o2, e2) = await linha(sh, "echo x >&2; echo y 1>&2; echo z 2>/dev/null")
        #expect(e2 == "x\ny" && o2 == "z")
        _ = await linha(sh, "ls nada 2>> err.txt; ls nada &> tudo.txt")
        #expect(try String(contentsOf: raiz.appending(path: "err.txt"), encoding: .utf8).contains("nada"))
        #expect(try String(contentsOf: raiz.appending(path: "tudo.txt"), encoding: .utf8).contains("nada"))
        let p = try Parser.parse("cmd 2>e.txt 2>>f.txt >&2 1>o.txt")
        let s = p.items[0].pipeline.commands[0]
        #expect(s.argv == ["cmd"] && s.stderrFile == "f.txt" && s.stderrAppend && s.stdoutToStderr && s
            .stdoutFile == "o.txt")
    }

    @Test func atribuicaoAntesDoComando() async throws {
        let raiz = try project()
        try #"{"name":"p","scripts":{"env":"FOO=do-script node -e \"console.log(process.env.FOO)\""}}"#.write(
            to: raiz.appending(path: "package.json"), atomically: true, encoding: .utf8
        )
        let sh = Shell(root: raiz)
        #expect(await linha(sh, #"FOO=bar node -e "console.log(process.env.FOO)""#).1 == "bar")
        #expect(await linha(sh, "echo [$FOO]").1 == "[]")
        #expect(await linha(sh, "npm run env").1.contains("do-script"))
        #expect(await linha(sh, "X=1; echo $X; A=1 B=2 env").1.contains("B=2"))
        #expect(sh.env["X"] == "1" && sh.env["B"] == nil)
    }

    @Test func aspasDuplasGuardamABarra() throws {
        let c = try Parser.parse(#"echo "a\nb" "c\"d" "e\\f" "g\$h" 'i\nj' k\*l"#)
        #expect(c.items[0].pipeline.commands[0].argv == ["echo", #"a\nb"#, #"c"d"#, #"e\f"#, "g$h", #"i\nj"#, "k*l"])
    }

    @Test func globECdMenos() async throws {
        let raiz = try project()
        let sh = Shell(root: raiz)
        _ = await linha(sh, "touch b.txt .oculto.txt src/c.ts src/d.ts")
        #expect(await linha(sh, "ls *.txt").1 == "a.txt\nb.txt")
        #expect(await linha(sh, "echo src/*.ts").1 == "src/c.ts src/d.ts")
        #expect(await linha(sh, "echo '*.txt' \\*.txt nada*").1 == "*.txt *.txt nada*")
        #expect(await linha(sh, "echo ?.txt").1 == "a.txt b.txt")
        _ = await linha(sh, "cd src")
        #expect(await linha(sh, "echo *").1 == "c.ts d.ts hi.js")
        #expect(await linha(sh, "cd - && pwd").1 == "~\n~")
        #expect(await linha(sh, "cd - && pwd").1 == "~/src\n~/src")
    }

    @Test func embutidosComOpcoes() async throws {
        let raiz = try project()
        try "foo\n\nbar\nfoobar\n".write(to: raiz.appending(path: "t.txt"), atomically: true, encoding: .utf8)
        let sh = Shell(root: raiz)
        #expect(await linha(sh, "grep -v foo t.txt").1 == "\nbar")
        #expect(await linha(sh, #"grep -E "^(bar|foo)$" t.txt"#).1 == "foo\nbar")
        #expect(await linha(sh, "grep -c foo t.txt").1 == "2")
        #expect(await linha(sh, "wc -l t.txt").1.hasSuffix("4 t.txt"))
        #expect(await linha(sh, #"echo -e "a\tb\nc""#).1 == "a\tb\nc")
        #expect(await linha(sh, "echo -n x; echo y").1 == "xy")
        #expect(await linha(sh, "find . -type f -name '*.js'").1 == "~/src/hi.js")
        #expect(await linha(sh, "find . -type d").1 == ".\n~/src")
        let (c, _, e) = await linha(sh, "grep -z foo t.txt")
        #expect(c == 2 && e.contains("opção desconhecida"))
        #expect(await linha(sh, "ls -Z").0 == 2)
        #expect(await linha(sh, "find . -newer x").0 == 2)
    }
}

/// Jobs e Ctrl+C: cada linha e cada job com o seu cancelamento.
@Suite(.serialized) struct ShellJobsTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func ticks(_ u: URL) -> Int {
        (try? Data(contentsOf: u))?.count ?? 0
    }

    func espera(_ prazo: Duration = .seconds(15), ate condicao: () -> Bool) async {
        let fim = ContinuousClock.now + prazo
        while ContinuousClock.now < fim, !condicao() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func killDoJobMataONode() async throws {
        let raiz = try project()
        let sh = Shell(root: raiz)
        let tick = raiz.appending(path: "tick.txt")
        _ = await linha(sh, #"node -e "setInterval(() => require('fs').appendFileSync('tick.txt', 'x'), 20)" &"#)
        // Espera o node começar a escrever: num simulador lento subir o motor passa de 700 ms.
        await espera(ate: { ticks(tick) > 0 })
        #expect(sh.jobs.count == 1 && ticks(tick) > 0)
        _ = await linha(sh, "kill %1")
        try await Task.sleep(for: .milliseconds(300))
        let n = ticks(tick)
        try await Task.sleep(for: .milliseconds(500))
        #expect(ticks(tick) == n && sh.jobs.isEmpty)
    }

    @Test func ctrlCNoPrimeiroPlanoNaoMataOJob() async throws {
        let raiz = try project()
        let sh = Shell(root: raiz)
        let tick = raiz.appending(path: "tick.txt")
        _ = await linha(sh, #"node -e "setInterval(() => require('fs').appendFileSync('tick.txt', 'x'), 20)" &"#)
        await espera(ate: { ticks(tick) > 0 })
        let fg = Task { await linha(sh, #"node -e "setTimeout(() => {}, 5000)""#) }
        try await Task.sleep(for: .milliseconds(500))
        sh.cancel()
        let t0 = ContinuousClock.now
        #expect(await fg.value.0 == 130)
        #expect(ContinuousClock.now - t0 < .seconds(1))
        let n = ticks(tick)
        try await Task.sleep(for: .milliseconds(400))
        #expect(ticks(tick) > n && sh.jobs.count == 1)
        sh.killAll()
    }

    /// Ctrl+C num laço síncrono solta o prompt (o terminal esperava o `task.value`).
    @Test func ctrlCSoltaLacoSincrono() async throws {
        let sh = try Shell(root: project())
        let fg = Task { await linha(sh, #"node -e "const fs = require('fs'); for (;;) fs.existsSync('x')""#) }
        try await Task.sleep(for: .milliseconds(800))
        let t0 = ContinuousClock.now
        sh.cancel()
        #expect(await fg.value.0 == 130)
        #expect(ContinuousClock.now - t0 < .seconds(1))
    }
}

/// O `node` do terminal: stdin, stdout em bytes e erros que derrubam.
@Suite(.serialized) struct NodeNoTerminalTests {
    init() {
        Texto.escolher(.ptBR)
    }

    @Test func stdinChegaAoNode() async throws {
        let raiz = try project()
        try """
        let t = ""; process.stdin.on("data", (d) => t += d); process.stdin.on("end", () => console.log("stdin:" + t.trim()));
        """.write(to: raiz.appending(path: "le.js"), atomically: true, encoding: .utf8)
        let sh = Shell(root: raiz)
        #expect(await linha(sh, "echo ola | node le.js").1 == "stdin:ola")
        #expect(await linha(
            sh,
            #"cat a.txt | node -e "console.log(require('fs').readFileSync(0, 'utf8').split('\n').length)""#
        ).1 == "4")
    }

    @Test func stdoutBinarioEPedacos() async throws {
        let raiz = try project()
        try "process.stdout.write(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0xff, 0x00, 0x41]));"
            .write(to: raiz.appending(path: "bin.js"), atomically: true, encoding: .utf8)
        try #"process.stdout.write("a"); process.stdout.write("b\n"); process.stdout.write("c"); console.log(); process.stdout.write("50%\r"); process.stdout.write("100%\n");"#
            .write(to: raiz.appending(path: "pedacos.js"), atomically: true, encoding: .utf8)
        let sh = Shell(root: raiz)
        _ = await linha(sh, "node bin.js > bin.out")
        #expect(try Data(contentsOf: raiz.appending(path: "bin.out")) == Data([
            0x89,
            0x50,
            0x4E,
            0x47,
            0xFF,
            0x00,
            0x41,
        ]))
        #expect(await linha(sh, "node pedacos.js").1 == "ab\nc\n100%")
        #expect(await linha(sh, #"node -e "console.log()""#).1 == "")
    }

    /// `main()` async que lança sem catch e top-level await (com o esbuild de verdade).
    @Test func asyncSemCatchETopLevelAwait() async throws {
        let raiz = try project()
        try "async function main() { await null; throw new Error('erro-em-async-main'); }\nmain();"
            .write(to: raiz.appending(path: "a.js"), atomically: true, encoding: .utf8)
        try "const x = await Promise.resolve(5);\nconsole.log('tla', x);"
            .write(to: raiz.appending(path: "t.mjs"), atomically: true, encoding: .utf8)
        try "import path from 'node:path';\nconst n: number = await Promise.resolve(2);\nconsole.log('ts', path.basename('a/b.txt'), n);"
            .write(to: raiz.appending(path: "t.ts"), atomically: true, encoding: .utf8)
        let sh = Shell(root: raiz)
        let (c, _, e) = await linha(sh, "node a.js")
        #expect(c == 1 && e.contains("erro-em-async-main"), Comment(rawValue: e))
        let (c2, o2, e2) = await linha(sh, "node t.mjs")
        #expect(c2 == 0 && o2 == "tla 5", Comment(rawValue: e2))
        let (c3, o3, e3) = await linha(sh, "node t.ts")
        #expect(c3 == 0 && o3 == "ts b.txt 2", Comment(rawValue: e3))
    }

    /// `require` de módulo ES que exporta `"module.exports"` (o yargs 18 faz isso) devolve
    /// esse valor, como no Node 22.12+; sem ele vem o namespace. O `import` segue igual.
    @Test func requireDeModuloESComModuleExports() async throws {
        let raiz = try project()
        let arquivos = [
            "node_modules/fab/package.json": #"{"name":"fab","type":"module","exports":{".":"./index.mjs","./sub":"./index.mjs"}}"#,
            "node_modules/fab/index.mjs": "const f = (x) => 'fab ' + x; export default f; export { f as 'module.exports' };",
            "node_modules/ns/package.json": #"{"name":"ns","type":"module","main":"i.js"}"#,
            "node_modules/ns/i.js": "export default 1; export const a = 2;",
            "main.js": """
            const f = require('fab/sub'), ns = require('ns');
            console.log(typeof f, f('ok'), typeof ns, ns.a, ns.default);
            import('fab').then((m) => console.log(typeof m.default, m.default('imp')));
            """,
        ]
        for (caminho, texto) in arquivos {
            let u = raiz.appending(path: caminho)
            try FileManager.default.createDirectory(
                at: u.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try texto.write(to: u, atomically: true, encoding: .utf8)
        }
        let (c, o, e) = await linha(Shell(root: raiz), "node main.js")
        #expect(c == 0, Comment(rawValue: e))
        #expect(o == "function fab ok object 2 1\nfunction fab imp", Comment(rawValue: o))
    }
}
