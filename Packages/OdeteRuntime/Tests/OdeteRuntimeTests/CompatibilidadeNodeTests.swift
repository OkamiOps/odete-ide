import Foundation
@testable import OdeteRuntime
import Synchronization
import Testing

/// Escreve vários arquivos de uma vez sob `dir` (caminho relativo → conteúdo).
func escrever(_ arquivos: [String: String], em dir: URL) throws {
    for (caminho, texto) in arquivos {
        let u = dir.appending(path: caminho)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try texto.write(to: u, atomically: true, encoding: .utf8)
    }
}

/// Roda `main.js` (ou o arquivo dado) de `dir` como `node main.js`, com limite de tempo.
func rodarArquivo(
    _ dir: URL,
    _ arquivo: String = "main.js",
    raiz: URL? = nil,
    stdin: Data? = nil,
    limite: Duration = .seconds(8)
) async -> (Int32, Capture) {
    let cap = Capture()
    let p = JSProcess(
        cwd: dir,
        argv: [dir.appending(path: arquivo).path],
        raiz: raiz,
        stdin: stdin,
        output: cap.handler
    )
    let vigia = Task { try? await Task.sleep(for: limite); p.kill() }
    let code = await p.run(file: dir.appending(path: arquivo))
    vigia.cancel()
    return (code, cap)
}

/// O carregamento de pacotes reais que falhava (análise de 23/09/2026: zod 4, yargs 17,
/// readable-stream 4, chalk 5, express, prettier, eslint) reduzido ao mecanismo que quebrava.
struct CarregamentoDeModulosTests {
    /// `require` relativo em ciclo acumulava `./` no caminho: cada volta era um módulo novo
    /// (carregado de novo) e o caminho crescia até estourar — o zod 4 não carregava.
    @Test func cicloDeRequireCarregaUmaVezSo() async throws {
        let dir = try tmp()
        try escrever([
            "main.js": "const a = require('./lib/a.js'); console.log(a.nome, a.b.nome, globalThis.cargas, require('./lib/./b.js') === a.b);",
            "lib/a.js": "globalThis.cargas = (globalThis.cargas || 0) + 1; exports.nome = 'a'; exports.b = require('./././b.js');",
            "lib/b.js": "globalThis.cargas++; exports.nome = 'b'; exports.a = require('../lib/./a.js'); exports.caminho = __filename;",
        ], em: dir)
        let (code, c) = await rodarArquivo(dir)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(c.stdout == "a b 2 true", Comment(rawValue: c.stdout))
    }

    /// `#subpath` pelo campo `imports` do package.json (o chalk 5 importa `#ansi-styles`).
    @Test func campoImportsDoPackageJson() async throws {
        let dir = try tmp()
        try escrever([
            "node_modules/pac/package.json": ##"{"name":"pac","main":"index.js","imports":{"#interno":"./src/interno.js","#dep":"outro","#util/*":"./util/*.js","#cond":{"node":"./cond-node.js","default":"./cond.js"}}}"##,
            "node_modules/pac/index.js": "module.exports = [require('#interno'), require('#dep'), require('#util/x'), require('#cond')].join(',');",
            "node_modules/pac/src/interno.js": "module.exports = 'interno';",
            "node_modules/pac/util/x.js": "module.exports = 'util-x';",
            "node_modules/pac/cond-node.js": "module.exports = 'cond-node';",
            "node_modules/outro/package.json": #"{"name":"outro","main":"i.js"}"#,
            "node_modules/outro/i.js": "module.exports = 'outro';",
            "main.js": "console.log(require('pac')); try { require('#nada'); } catch (e) { console.log(e.code); }",
        ], em: dir)
        let (code, c) = await rodarArquivo(dir)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(c.stdout == "interno,outro,util-x,cond-node\nMODULE_NOT_FOUND", Comment(rawValue: c.stdout))
    }

    /// `import()` fora do esbuild — CJS cru e `new Function("return import(x)")`, como no
    /// bin do prettier e no carregador de config do eslint — rejeitava calado. Texto com
    /// "import(" em string e regex não muda.
    @Test func importDinamicoEmCodigoCJS() async throws {
        let dir = try tmp()
        try escrever([
            "x.js": "exports.v = 'x'; exports.default = 'padrão';",
            "y.js": "module.exports = function y() { return 'y'; };",
            "main.js": """
            const texto = "não mexer: import('z')", re = /import\\(/;
            import('./x.js').then((m) => console.log(m.v, m.default));
            const carregar = new Function("m", "return import(m)");
            carregar('./y.js').then((m) => console.log(typeof m.default, m.default()));
            import('file://' + __dirname + '/x.js?t=123').then((m) => console.log('url', m.v));
            import('node:path').then((m) => console.log('builtin', typeof m.join, typeof m.default.join));
            console.log(texto, re.test('import('));
            """,
        ], em: dir)
        let (code, c) = await rodarArquivo(dir)
        #expect(code == 0, Comment(rawValue: c.stderr))
        let linhas = c.stdout.split(separator: "\n").map(String.init)
        #expect(linhas.first == "não mexer: import('z') true", Comment(rawValue: c.stdout))
        // CJS importado: `default` é o `module.exports` inteiro, como no Node.
        #expect(Set(linhas.dropFirst()) == [
            "x { v: 'x', default: 'padrão' }",
            "function y",
            "url x",
            "builtin function function",
        ])
    }

    @Test func reescritaDeImportRespeitaStringsComentariosERegex() {
        let fonte = """
        const a = "import(x)"; // import(y)
        /* import(z) */ const r = /import\\(w/g, t = `import(${import('q')})`;
        obj.import(1); class K { import(v) { return v; } }
        await import ( "m" ); const n = x / import('d') / 2;
        """
        let r = ReescritaDeImport.reescrever(fonte) ?? ""
        #expect(r.contains(#""import(x)""#) && r.contains("// import(y)") && r.contains("/* import(z) */"))
        #expect(r.contains("/import\\(w/g") && r.contains("${__odete_import('q')}") && r.contains("`import("))
        #expect(r.contains("obj.import(1)") && r.contains("import(v) {"))
        #expect(r.contains(#"await __odete_import ( "m" )"#) && r.contains("x / __odete_import('d') / 2"))
        #expect(ReescritaDeImport.reescrever("const x = 1;") == nil)
    }
}

/// O express não carregava: o depd pede a pilha como CallSites do V8, e o EventEmitter e o
/// Stream eram classes ES (sem `EventEmitter.call(this)`).
struct ApiDoV8EHerancaTests {
    @Test func pilhaNoFormatoDoV8() async throws {
        let (code, c) = try await run("""
        function lugar() {
          const antes = Error.prepareStackTrace;
          Error.prepareStackTrace = (_, pilha) => pilha;
          const o = {}; Error.captureStackTrace(o, lugar);
          const pilha = o.stack; Error.prepareStackTrace = antes;
          return pilha;
        }
        function chamador() { return lugar(); }
        const q = chamador()[0];
        console.log(typeof q.getFileName(), q.getFunctionName(), q.getLineNumber() > 0, typeof q.isNative());
        const e = new Error("boom");
        console.log(e.stack.split("\\n")[0], /\\n    at /.test(e.stack));
        class MeuErro extends Error { constructor(m) { super(m); this.name = "MeuErro"; } }
        console.log(new MeuErro("x").stack.split("\\n")[0], new MeuErro("x") instanceof Error, TypeError("t") instanceof TypeError);
        try { null.x; } catch (err) { console.log(err instanceof TypeError, err.constructor === TypeError); }
        Error.stackTraceLimit = 0; console.log(JSON.stringify(new Error("sem").stack));
        """)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(
            c
                .stdout ==
                "string chamador true boolean\nError: boom true\nMeuErro: x true true\ntrue true\n\"Error: sem\"",
            Comment(rawValue: c.stdout)
        )
    }

    @Test func eventEmitterEStreamComoFuncao() async throws {
        let (code, c) = try await run("""
        const EE = require("events"), util = require("util"), Stream = require("stream");
        function Foo() { EE.call(this); }
        util.inherits(Foo, EE);
        const f = new Foo(); f.on("x", (v) => console.log("recebi", v)); f.emit("x", 1);
        const o = {}; Object.assign(o, EE.prototype);
        EE.prototype.on.call(o, "y", () => console.log("mixin ok")); EE.prototype.emit.call(o, "y");
        function Velho() { Stream.call(this); }
        util.inherits(Velho, Stream);
        console.log("stream", typeof new Velho().pipe, new Velho() instanceof EE);
        function R() { Stream.Readable.call(this, { objectMode: true }); }
        util.inherits(R, Stream.Readable);
        R.prototype._read = function () { this.push("a"); this.push(null); };
        new R().on("data", (d) => console.log("dado", d)).on("end", () => console.log("fim"));
        EE.defaultMaxListeners = 20; console.log(EE.defaultMaxListeners, typeof EE.errorMonitor);
        """)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(
            c.stdout == "recebi 1\nmixin ok\nstream function true\n20 symbol\ndado a\nfim",
            Comment(rawValue: c.stdout)
        )
    }
}

/// Erro que ninguém trata tem de derrubar o processo com 1, como no Node.
struct ErrosNaoTratadosTests {
    @Test func rejeicaoNaoTratadaSaiComUm() async throws {
        let (code, c) = try await run("""
        Promise.reject(new Error("rejeitada-sem-catch"));
        setTimeout(() => console.log("depois"), 20);
        """)
        #expect(code == 1)
        #expect(c.stderr.contains("rejeitada-sem-catch") && !c.stdout.contains("depois"), Comment(rawValue: c.stderr))
    }

    @Test func rejeicaoTratadaDepoisOuPorOuvinteNaoDerruba() async throws {
        let (code, c) = try await run("""
        const p = Promise.reject(new Error("x")); p.catch((e) => console.log("pego", e.message));
        new Promise((_, rej) => rej("texto")).then(null, (m) => console.log("then2", m));
        (async () => { try { await Promise.reject(new Error("await")); } catch (e) { console.log("try", e.message); } })();
        """)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(c.stdout.contains("pego x") && c.stdout.contains("then2 texto") && c.stdout.contains("try await"))
        let (code2, c2) = try await run("""
        process.on("unhandledRejection", (r) => console.log("ouvinte", r.message));
        Promise.reject(new Error("y"));
        """)
        #expect(code2 == 0 && c2.stdout == "ouvinte y", Comment(rawValue: c2.stdout + c2.stderr))
    }

    @Test func erroNoNextTickSaiComUm() async throws {
        let (code, c) = try await run("""
        process.nextTick(() => { throw new Error("erro-no-tick"); });
        setTimeout(() => console.log("continuou"), 20);
        """)
        #expect(
            code == 1 && c.stderr.contains("erro-no-tick") && c.stdout.isEmpty,
            Comment(rawValue: c.stdout + c.stderr)
        )
        let (code2, c2) = try await run("queueMicrotask(() => { throw new Error('micro'); });")
        #expect(code2 == 1 && c2.stderr.contains("micro"))
    }

    @Test func nextTickAntesDasPromises() async throws {
        let (code, c) = try await run("""
        Promise.resolve().then(() => console.log("promise"));
        process.nextTick(() => console.log("nextTick"));
        setTimeout(() => console.log("timeout"), 0);
        """)
        #expect(code == 0 && c.stdout == "nextTick\npromise\ntimeout", Comment(rawValue: c.stdout))
    }

    @Test func eventosExitEBeforeExit() async throws {
        let (code, c) = try await run("""
        let voltas = 0;
        process.on("beforeExit", () => { if (voltas++ < 1) setTimeout(() => console.log("mais trabalho"), 1); else console.log("beforeExit"); });
        process.on("exit", (codigo) => console.log("exit", codigo));
        console.log("corpo");
        """)
        #expect(code == 0 && c.stdout == "corpo\nmais trabalho\nbeforeExit\nexit 0", Comment(rawValue: c.stdout))
        let (code2, c2) = try await run("process.on('exit', (c) => console.log('saindo', c)); process.exitCode = 4;")
        #expect(code2 == 4 && c2.stdout == "saindo 4")
        let (code3, c3) = try await run("process.on('exit', (c) => console.log('saindo', c)); process.exit(3);")
        #expect(code3 == 3 && c3.stdout == "saindo 3")
    }
}

struct LacoDeEventosTests {
    /// `setInterval(...).unref()` não segura o processo (o node-cache deixava o `node`
    /// preso para sempre); `ref()` volta a segurar.
    @Test func unrefSoltaOProcesso() async throws {
        let t0 = ContinuousClock.now
        let (code, c) = try await run("setInterval(() => {}, 1000).unref(); console.log('fim');")
        #expect(code == 0 && c.stdout == "fim")
        // Folga para subir o motor num simulador lento; preso de verdade seria para sempre.
        #expect(ContinuousClock.now - t0 < .seconds(6))
        let (code2, c2) = try await run("""
        const t = setTimeout(() => console.log("rodou"), 30); t.unref(); t.ref();
        console.log(t.hasRef());
        """)
        #expect(code2 == 0 && c2.stdout == "true\nrodou")
    }

    @Test func apisQueFaltavam() async throws {
        let (code, c) = try await run("""
        const { promisify } = require("util"), crypto = require("crypto");
        (async () => {
          await promisify(setTimeout)(5);
          console.log("dormiu");
          console.log();
          console.log(crypto.randomFillSync(Buffer.alloc(8)).length, crypto.randomInt(10) < 10);
          console.log(crypto.createHash("sha3-256").update("abc").digest("hex"));
          try { crypto.createHash("nao-existe"); } catch (e) { console.log("recusou", e.message); }
          console.log(crypto.createHmac("sha256", "chave").update("dado").digest("hex").slice(0, 16));
          console.log(crypto.pbkdf2Sync("senha", "sal", 1000, 16, "sha256").toString("hex"));
          const c = structuredClone({ d: new Date(0), m: new Map([[1, 2]]), u: undefined, s: new Set([1]), r: /a/g });
          console.log(c.d instanceof Date, c.m.get(1), "u" in c, c.s.has(1), c.r.flags);
          const k = await crypto.subtle.importKey("raw", new TextEncoder().encode("k"), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
          const sig = new Uint8Array(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode("m")));
          console.log(sig.length, Buffer.from(sig).toString("hex") === crypto.createHmac("sha256", "k").update("m").digest("hex"));
        })();
        """)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(c.stdout == """
        dormiu

        8 true
        3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532
        recusou Digest method not supported
        d3c1ef19cd4eb5c4
        a0c40ca97663b9f2696261f28b3d7cc9
        true 2 true true g
        32 true
        """, Comment(rawValue: c.stdout))
    }

    @Test func stdoutJuntaPedacosEStdinChega() async throws {
        let dir = try tmp()
        try escrever([
            "main.js": """
            process.stdout.write("a"); process.stdout.write("b\\n"); process.stdout.write("50%\\r"); process.stdout.write("100%\\n");
            process.stdout.write("sem fim");
            """,
            "le.js": """
            let tudo = "";
            process.stdin.on("data", (d) => { tudo += d; });
            process.stdin.on("end", () => console.log("stdin:", tudo.trim(), require("fs").readFileSync(0, "utf8").trim()));
            """,
        ], em: dir)
        let (code, c) = await rodarArquivo(dir)
        #expect(code == 0 && c.stdout == "ab\n100%\nsem fim", Comment(rawValue: c.stdout))
        let (code2, c2) = await rodarArquivo(dir, "le.js", stdin: Data("olá\n".utf8))
        #expect(code2 == 0 && c2.stdout == "stdin: olá olá", Comment(rawValue: c2.stdout + c2.stderr))
    }

    /// `readline` lê as linhas do stdin que veio pelo pipe; sem pipe, `question` responde
    /// vazio na hora (o teclado ainda não chega ao processo).
    @Test func readlineComESemStdin() async throws {
        let dir = try tmp()
        try escrever(["main.js": """
        const rl = require("readline").createInterface({ input: process.stdin });
        (async () => { const l = []; for await (const x of rl) l.push(x); console.log(l.join("|")); })();
        """, "pergunta.js": """
        const rl = require("readline").createInterface({ input: process.stdin, output: process.stdout });
        rl.question("nome? ", (r) => { console.log("[" + r + "]"); rl.close(); });
        """], em: dir)
        let (code, c) = await rodarArquivo(dir, stdin: Data("a\nb\r\nc".utf8))
        #expect(code == 0 && c.stdout == "a|b|c", Comment(rawValue: c.stdout + c.stderr))
        let (code2, c2) = await rodarArquivo(dir, "pergunta.js")
        #expect(code2 == 0 && c2.stdout == "nome? []", Comment(rawValue: c2.stdout + c2.stderr))
    }

    /// Binário pelo stdout chega inteiro a quem pede os bytes crus (o terminal redirecionando
    /// para arquivo). Antes passava por UTF-8 e o 0xFF engolia os bytes seguintes.
    @Test func stdoutBinarioChegaInteiro() async throws {
        let dir = try tmp()
        try escrever(
            ["main.js": "process.stdout.write(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0xff, 0x00, 0x41]));"],
            em: dir
        )
        let bytes = Mutex(Data())
        let p = JSProcess(cwd: dir, output: { _, _ in })
        p.setSaidaBruta {
            k, d in if k == .out {
                bytes.withLock { $0.append(d) }
            }
        }
        let code = await p.run(file: dir.appending(path: "main.js"))
        #expect(code == 0)
        #expect(bytes.withLock { $0 } == Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0x00, 0x41]))
        let (_, c) = try await run("console.log(Buffer.from([0xff, 0x41, 0x42, 0x43]).toString())")
        #expect(c.stdout == "\u{FFFD}ABC")
    }

    @Test func statELstatDeLink() async throws {
        let (code, c) = try await run("""
        const fs = require("fs");
        fs.writeFileSync("alvo.txt", "0123456789"); fs.symlinkSync("alvo.txt", "link.txt");
        const s = fs.statSync("link.txt"), l = fs.lstatSync("link.txt");
        console.log(s.isSymbolicLink(), s.size, l.isSymbolicLink(), s.isFile());
        fs.symlinkSync("nao-existe.txt", "quebrado.txt");
        console.log(fs.lstatSync("quebrado.txt").isSymbolicLink(), fs.existsSync("quebrado.txt"), fs.readlinkSync("quebrado.txt"));
        const d = fs.readdirSync(".", { withFileTypes: true }).map((e) => e.name + ":" + (e.isSymbolicLink() ? "l" : e.isFile() ? "f" : "d"));
        console.log(d.join(","));
        const fd = fs.openSync("alvo.txt", "r"); const b = Buffer.alloc(4);
        console.log(fs.readSync(fd, b, 0, 4, 3), b.toString(), fs.readSync(fd, b, 0, 2, null), b.toString()); fs.closeSync(fd);
        """)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(
            c
                .stdout ==
                "false 10 true true\ntrue false nao-existe.txt\nalvo.txt:f,link.txt:l,quebrado.txt:l\n4 3456 2 0156",
            Comment(rawValue: c.stdout)
        )
    }
}

/// O `fs` de um processo com raiz não sai do projeto, e `rename` nunca apaga pasta.
struct ConfinamentoDoFsTests {
    /// Uma pasta fora do tmp do app: o tmp é liberado para o processo, e a raiz de teste
    /// dentro dele liberaria o vizinho junto.
    func foraDoTmp() throws -> URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "odete-conf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func fsNaoSaiDaRaiz() async throws {
        let base = try foraDoTmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let raiz = base.appending(path: "proj")
        let vizinho = base.appending(path: "proj2")
        try escrever(["importante.txt": "vizinho"], em: vizinho)
        try escrever(["main.js": """
        const fs = require("fs");
        const tenta = (n, f) => { try { f(); console.log(n, "passou"); } catch (e) { console.log(n, e.code); } };
        tenta("ler", () => fs.readFileSync("../proj2/importante.txt", "utf8"));
        tenta("escrever", () => fs.writeFileSync("../proj2/novo.txt", "x"));
        tenta("apagar", () => fs.rmSync("../proj2", { recursive: true, force: true }));
        tenta("absoluto", () => fs.readdirSync("/"));
        fs.symlinkSync("../proj2", "atalho");
        tenta("pelo link", () => fs.writeFileSync("atalho/pelo-link.txt", "x"));
        tenta("apaga o link", () => fs.unlinkSync("atalho"));
        tenta("tmp", () => fs.writeFileSync(require("os").tmpdir() + "/odete-conf-" + process.pid + ".txt", "x"));
        tenta("aqui", () => fs.writeFileSync("ok.txt", "x"));
        """], em: raiz)
        let (code, c) = await rodarArquivo(raiz, raiz: raiz)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(c.stdout == """
        ler EACCES
        escrever EACCES
        apagar EACCES
        absoluto EACCES
        pelo link EACCES
        apaga o link passou
        tmp passou
        aqui passou
        """, Comment(rawValue: c.stdout))
        #expect(FileManager.default.fileExists(atPath: vizinho.appending(path: "importante.txt").path))
        #expect(!FileManager.default.fileExists(atPath: vizinho.appending(path: "novo.txt").path))
    }

    @Test func renameNaoApagaPasta() async throws {
        let (code, c) = try await run("""
        const fs = require("fs");
        fs.mkdirSync("dir/sub", { recursive: true }); fs.writeFileSync("dir/keep.txt", "importante"); fs.writeFileSync("a.txt", "a");
        try { fs.renameSync("a.txt", "dir"); console.log("rename passou"); } catch (e) { console.log("arquivo sobre pasta", e.code); }
        fs.mkdirSync("outra"); fs.writeFileSync("outra/x.txt", "x");
        try { fs.renameSync("outra", "dir"); } catch (e) { console.log("pasta sobre pasta cheia", e.code); }
        try { fs.copyFileSync("a.txt", "dir"); } catch (e) { console.log("copy sobre pasta", e.code); }
        fs.cpSync("outra", "dir", { recursive: true });
        console.log(fs.existsSync("dir/keep.txt"), fs.existsSync("dir/x.txt"), fs.existsSync("dir/sub"));
        fs.writeFileSync("b.txt", "b"); fs.renameSync("b.txt", "a.txt"); console.log(fs.readFileSync("a.txt", "utf8"));
        """)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(c.stdout == """
        arquivo sobre pasta EISDIR
        pasta sobre pasta cheia ENOTEMPTY
        copy sobre pasta EISDIR
        true true true
        b
        """, Comment(rawValue: c.stdout))
    }

    @Test func confinamentoResolveLinksEDotDot() throws {
        let base = try tmp()
        let raiz = base.appending(path: "proj")
        try FileManager.default.createDirectory(at: raiz.appending(path: "src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appending(path: "proj2"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: raiz.appending(path: "fora").path,
            withDestinationPath: "../proj2"
        )
        try FileManager.default.createSymbolicLink(
            atPath: raiz.appending(path: "quebrado").path,
            withDestinationPath: "../proj2/novo"
        )
        let c = Confinamento(raiz: raiz)
        #expect(c.permite(raiz.path) && c.permite(raiz.appending(path: "src/../x.txt").path))
        #expect(c.permite(raiz.appending(path: "novo/fundo/arquivo").path))
        #expect(!c.permite(raiz.appending(path: "../proj2").path))
        #expect(!c.permite(raiz.appending(path: "src/../../proj2/x").path))
        #expect(!c.permite(raiz.appending(path: "fora/x.txt").path))
        #expect(!c.permite(raiz.appending(path: "quebrado").path))
        #expect(c.permite(raiz.appending(path: "fora").path, seguirUltimo: false))
        #expect(Confinamento.normalizar("/a/./b/../c//d/") == "/a/c/d" && Confinamento
            .normalizar("../x/./y") == "../x/y")
    }
}

/// A saída do esbuild é guardada em disco: o mesmo arquivo não é transformado de novo, e
/// mudar o arquivo (ou a versão do transformador) invalida.
struct CacheDeTransformacaoTests {
    @Test func segundaVezNaoTransforma() async throws {
        let dir = try tmp()
        try escrever(["m.mjs": "export const x = 1; console.log('m', " + "\(UUID().uuidString.count));"], em: dir)
        let chamadas = Mutex(0)
        let versao = "teste \(UUID().uuidString)"
        func roda() async -> Capture {
            let cap = Capture()
            let p = JSProcess(cwd: dir, output: cap.handler)
            p.setTransform({ src, _ in
                chamadas.withLock { $0 += 1 }
                return src.replacingOccurrences(of: "export const x = 1;", with: "exports.x = 1;")
            }, versao: versao)
            _ = await p.run(file: dir.appending(path: "m.mjs"))
            return cap
        }
        #expect(await roda().stdout == "m 36")
        #expect(await roda().stdout == "m 36")
        #expect(chamadas.withLock { $0 } == 1)
        try await Task.sleep(for: .milliseconds(20))
        try escrever(["m.mjs": "export const x = 1; console.log('mudou');"], em: dir)
        #expect(await roda().stdout == "mudou")
        #expect(chamadas.withLock { $0 } == 2)
    }
}

/// Ctrl+C num processo preso em JS síncrono solta quem espera na hora.
struct InterrupcaoTests {
    @Test func killSoltaLacoSincrono() async throws {
        let dir = try tmp()
        let cap = Capture()
        let p = JSProcess(cwd: dir, output: cap.handler)
        let tarefa = Task { await p.run(code: "const fs = require('fs'); for (;;) { fs.existsSync('x'); }") }
        try await Task.sleep(for: .milliseconds(300))
        // Mede do kill em diante: subir o motor num simulador lento passa de 2 s sozinho,
        // e o que o teste garante é que o kill solta quem espera na hora.
        let t0 = ContinuousClock.now
        p.kill()
        let code = await tarefa.value
        #expect(code == 130)
        #expect(ContinuousClock.now - t0 < .seconds(2))
    }
}
