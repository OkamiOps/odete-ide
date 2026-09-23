import Foundation
@testable import OdeteRuntime
import Synchronization
import Testing

final class Capture: Sendable {
    let out = Mutex<[String]>([])
    let err = Mutex<[String]>([])
    var handler: @Sendable (OutputKind, String) -> Void {
        { kind, text in
            if kind == .out {
                self.out.withLock { $0.append(text) }
            } else {
                self.err.withLock { $0.append(text) }
            } }
    }

    var stdout: String {
        out.withLock { $0.joined(separator: "\n") }
    }

    var stderr: String {
        err.withLock { $0.joined(separator: "\n") }
    }
}

func tmp() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appending(
        path: "odete-rt-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// Roda com limite de tempo: se passar de 8 s, mata o processo e devolve -99.
func run(_ code: String, cwd: URL? = nil, argv: [String] = []) async throws -> (Int32, Capture) {
    let dir = try cwd ?? tmp()
    let cap = Capture()
    let p = JSProcess(cwd: dir, argv: argv, output: cap.handler)
    let watchdog = Task { try? await Task.sleep(for: .seconds(8)); p.kill() }
    let code = await p.run(code: code)
    watchdog.cancel()
    return (code, cap)
}

struct RuntimeTests {
    @Test func consoleAndBasics() async throws {
        let (code, c) = try await run("""
        console.log("olá", 1 + 1, { a: [1, 2] });
        console.error("erro %s", "x");
        const b = Buffer.from("olá mundo");
        console.log(b.length, b.toString("base64"), Buffer.from(b.toString("hex"), "hex").toString());
        console.log(typeof setTimeout, typeof fetch, typeof TextEncoder, crypto.randomUUID().length);
        """)
        #expect(code == 0)
        #expect(c.stdout.contains("olá 2 { a: [ 1, 2 ] }"))
        #expect(c.stdout.contains("10 b2zDoSBtdW5kbw== olá mundo"))
        #expect(c.stdout.contains("function function function 36"))
        #expect(c.stderr.contains("erro x"))
    }

    /// Esquema especial com uma barra só (ou nenhuma, ou contrabarra) é o que o WHATWG
    /// aceita: o `@astrojs/rss` monta `https:/site/` e o RSS do blog do Astro dava 500.
    @Test func urlComBarrasDoWhatwg() async throws {
        let (code, c) = try await run("""
        console.log(new URL("https:/example.com/a").href);
        console.log(new URL("https:example.com").href);
        console.log(new URL("http:\\\\\\\\x.com\\\\y").host);
        console.log(new URL("https:rel", "https://base.com/d/").href);
        console.log(new URL("file:///tmp/x").pathname);
        """)
        #expect(code == 0, "\(c.stderr)")
        #expect(c.stdout == "https://example.com/a\nhttps://example.com/\nx.com\nhttps://base.com/d/rel\n/tmp/x", "saiu: [\(c.stdout)]")
    }

    @Test func timersAndPromises() async throws {
        let (code, c) = try await run("""
        const t0 = Date.now();
        setTimeout(() => console.log("t1"), 30);
        const iv = setInterval(() => { console.log("tick"); clearInterval(iv); }, 10);
        Promise.resolve().then(() => console.log("micro"));
        (async () => { await new Promise(r => setTimeout(r, 50)); console.log("done", Date.now() - t0 >= 45); })();
        """)
        #expect(code == 0)
        let lines = c.stdout.split(separator: "\n").map(String.init)
        #expect(lines.first == "micro")
        #expect(lines.contains("tick") && lines.contains("t1") && lines.last == "done true")
    }

    @Test func fsPathAndRequire() async throws {
        let dir = try tmp()
        let (code, c) = try await run("""
        const fs = require("fs"), path = require("path"), os = require("os");
        fs.mkdirSync("src/lib", { recursive: true });
        fs.writeFileSync("src/lib/soma.js", "module.exports = (a, b) => a + b; exports.nome = 'soma';");
        fs.writeFileSync("src/dados.json", JSON.stringify({ x: 41 }));
        const soma = require("./src/lib/soma.js");
        const dados = require("./src/dados.json");
        console.log(soma(dados.x, 1), path.join("a", "..", "b", "c.txt"), path.extname("x.tsx"));
        console.log(fs.readdirSync("src").join(","), fs.statSync("src").isDirectory(), fs.existsSync("nope"));
        fs.appendFileSync("log.txt", "a\\n"); fs.appendFileSync("log.txt", "b\\n");
        console.log(JSON.stringify(fs.readFileSync("log.txt", "utf8")));
        fs.renameSync("log.txt", "log2.txt"); fs.rmSync("log2.txt");
        console.log(fs.existsSync("log2.txt"), os.platform(), path.resolve("x") === process.cwd() + "/x");
        require("fs/promises").readFile("src/dados.json", "utf8").then(t => console.log("promises", t));
        try { require("nao-existe"); } catch (e) { console.log(e.code); }
        """, cwd: dir)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(c.stdout.contains("42 b/c.txt .tsx"))
        #expect(c.stdout.contains("dados.json,lib true false"))
        #expect(c.stdout.contains("\"a\\nb\\n\""))
        #expect(c.stdout.contains("false darwin true"))
        #expect(c.stdout.contains("promises {\"x\":41}"))
        #expect(c.stdout.contains("MODULE_NOT_FOUND"))
    }

    @Test func nodeModulesWithExports() async throws {
        let dir = try tmp()
        let pkg = dir.appending(path: "node_modules/@acme/util")
        try FileManager.default.createDirectory(at: pkg.appending(path: "dist"), withIntermediateDirectories: true)
        try #"{"name":"@acme/util","exports":{".":{"require":"./dist/index.cjs","import":"./dist/index.mjs"},"./extra":"./dist/extra.js"}}"#
            .write(
                to: pkg.appending(path: "package.json"),
                atomically: true,
                encoding: .utf8
            )
        try "module.exports = { v: 'cjs' };".write(
            to: pkg.appending(path: "dist/index.cjs"),
            atomically: true,
            encoding: .utf8
        )
        try "export const v = 'esm';".write(
            to: pkg.appending(path: "dist/index.mjs"),
            atomically: true,
            encoding: .utf8
        )
        try "module.exports = 'extra';".write(
            to: pkg.appending(path: "dist/extra.js"),
            atomically: true,
            encoding: .utf8
        )
        let simple = dir.appending(path: "node_modules/simple")
        try FileManager.default.createDirectory(at: simple, withIntermediateDirectories: true)
        try #"{"name":"simple","main":"lib.js"}"#.write(
            to: simple.appending(path: "package.json"),
            atomically: true,
            encoding: .utf8
        )
        try "module.exports = require('@acme/util/extra') + '!';".write(
            to: simple.appending(path: "lib.js"),
            atomically: true,
            encoding: .utf8
        )
        try "console.log(require('@acme/util').v, require('simple'), require('node:events').EventEmitter.name);".write(
            to: dir.appending(path: "main.js"),
            atomically: true,
            encoding: .utf8
        )
        let cap = Capture()
        let p = JSProcess(cwd: dir, argv: ["main.js"], output: cap.handler)
        let code = await p.run(file: dir.appending(path: "main.js"))
        #expect(code == 0, Comment(rawValue: cap.stderr))
        #expect(cap.stdout == "cjs extra! EventEmitter")
    }

    @Test func esmNeedsTransformUntilBundler() async throws {
        let dir = try tmp()
        try "import x from './y.js'; console.log(x);".write(
            to: dir.appending(path: "m.js"),
            atomically: true,
            encoding: .utf8
        )
        let cap = Capture()
        let p = JSProcess(cwd: dir, output: cap.handler)
        let code = await p.run(file: dir.appending(path: "m.js"))
        #expect(code == 1)
        #expect(cap.stderr.contains("esbuild"))
        // com transformador injetado (finge um esbuild trivial)
        let cap2 = Capture()
        let p2 = JSProcess(cwd: dir, output: cap2.handler)
        p2.setTransform { src, _ in src.replacingOccurrences(
            of: "import x from './y.js';",
            with: "const x = require('./y.js');"
        ) }
        try "module.exports = 'via transform';".write(
            to: dir.appending(path: "y.js"),
            atomically: true,
            encoding: .utf8
        )
        let code2 = await p2.run(file: dir.appending(path: "m.js"))
        #expect(code2 == 0 && cap2.stdout == "via transform")
    }

    /// Módulo ES que declara as variáveis do embrulho CJS, como o vite faz: antes era
    /// SyntaxError ("Cannot declare a const variable twice: '__dirname'"). (`require`,
    /// `module` e `exports` o próprio esbuild renomeia quando gera CJS; `__dirname` e
    /// `__filename` ele deixa.)
    @Test func moduloESDeclaraDirname() async throws {
        let dir = try tmp()
        try """
        #!/usr/bin/env node
        import path from "node:path";
        const __filename = new URL(import.meta.url).pathname;
        const __dirname = path.dirname(__filename);
        console.log(__dirname === process.cwd(), path.basename(__filename), this === exports);
        """.write(to: dir.appending(path: "m.mjs"), atomically: true, encoding: .utf8)
        let cap = Capture()
        let p = JSProcess(cwd: dir, output: cap.handler)
        // Finge o esbuild: troca o import por require e import.meta.url pela URL do arquivo,
        // e deixa o `#!` no topo, como o esbuild deixa.
        p.setTransform { src, file in
            src.replacingOccurrences(
                of: #"import path from "node:path";"#,
                with: #"const path = require("node:path");"#
            )
            .replacingOccurrences(of: "import.meta.url", with: "\"file://\(file)\"")
        }
        let code = await p.run(file: dir.appending(path: "m.mjs"))
        #expect(code == 0 && cap.stdout == "true m.mjs true", Comment(rawValue: cap.stdout + cap.stderr))
    }

    /// `import "./a.js"` com `a.ts` no disco (o estilo do TypeScript com nodenext); um `.js`
    /// que existe de verdade continua ganhando.
    @Test func importComJsAchaOFonteTypeScript() async throws {
        let dir = try tmp()
        try "exports.v = 'do ts';".write(to: dir.appending(path: "a.ts"), atomically: true, encoding: .utf8)
        try "exports.v = 'do tsx';".write(to: dir.appending(path: "c.tsx"), atomically: true, encoding: .utf8)
        try "exports.v = 'do js';".write(to: dir.appending(path: "b.js"), atomically: true, encoding: .utf8)
        try "exports.v = 'do ts errado';".write(to: dir.appending(path: "b.ts"), atomically: true, encoding: .utf8)
        let cap = Capture()
        let p = JSProcess(cwd: dir, output: cap.handler)
        p.setTransform { src, _ in src }
        let code = await p.run(code: """
        console.log(require("./a.js").v, require("./b.js").v, require("./c.js").v);
        try { require("./nada.js"); } catch (e) { console.log(e.code); }
        """)
        #expect(
            code == 0 && cap.stdout == "do ts do js do tsx\nMODULE_NOT_FOUND",
            Comment(rawValue: cap.stdout + cap.stderr)
        )
    }

    /// `console.error(e)` mostra o nome e a mensagem, não só a pilha do JSC.
    @Test func consoleDeErroMostraAMensagem() async throws {
        let (code, c) = try await run("""
        function f() { throw new TypeError("sem binário nativo"); }
        try { f(); } catch (e) { console.error(e); console.log(require("util").inspect({ e: 1 })); }
        """)
        #expect(code == 0)
        #expect(c.stderr.hasPrefix("TypeError: sem binário nativo\n    at f"), Comment(rawValue: c.stderr))
        #expect(c.stdout == "{ e: 1 }")
    }

    @Test func exitCodesAndErrors() async throws {
        let (a, _) = try await run("process.exitCode = 3; setTimeout(() => {}, 5);")
        #expect(a == 3)
        let (b, cb) = try await run("console.log('antes'); process.exit(7); console.log('depois');")
        #expect(b == 7 && cb.stdout == "antes")
        let (c, cc) = try await run("setTimeout(() => { throw new Error('boom'); }, 1);")
        #expect(c == 1 && cc.stderr.contains("boom"))
        let (
            d,
            cd
        ) =
            try await run(
                "process.on('uncaughtException', e => { console.log('pego', e.message); }); setTimeout(() => { throw new Error('x'); }, 1); setTimeout(() => console.log('segue'), 20);"
            )
        #expect(d == 0 && cd.stdout.contains("pego x") && cd.stdout.contains("segue"))
    }

    @Test func eventsStreamsUtil() async throws {
        let (code, c) = try await run("""
        const { EventEmitter } = require("events"), { Readable, Transform } = require("stream"), util = require("util"), assert = require("assert"), zlib = require("zlib");
        const e = new EventEmitter(); e.once("x", (v) => console.log("x", v)); e.emit("x", 1); e.emit("x", 2);
        const up = new Transform({ transform(c, _, cb) { cb(null, c.toString().toUpperCase()); } });
        let out = ""; up.on("data", (d) => { out += d; }); up.on("end", () => console.log("stream", out));
        Readable.from(["a", "b"]).pipe(up);
        console.log(util.format("%s=%d %j", "n", 5, { k: 1 }), util.inspect(new Map([[1, 2]])));
        assert.deepStrictEqual({ a: [1] }, { a: [1] }); try { assert.strictEqual(1, 2); } catch (err) { console.log(err.name); }
        const gz = zlib.gzipSync("hello hello hello"); console.log(zlib.gunzipSync(gz).toString(), gz[0] === 0x1f);
        const p = util.promisify((x, cb) => cb(null, x * 2)); p(21).then((v) => console.log("promisify", v));
        console.log(require("crypto").createHash("sha256").update("abc").digest("hex").slice(0, 12));
        """)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(c.stdout.contains("x 1") && !c.stdout.contains("x 2"))
        #expect(c.stdout.contains("stream AB"))
        #expect(c.stdout.contains("n=5 {\"k\":1} Map(1) { 1 => 2 }"))
        #expect(c.stdout.contains("AssertionError"))
        #expect(c.stdout.contains("hello hello hello true"))
        #expect(c.stdout.contains("promisify 42"))
        #expect(c.stdout.contains("ba7816bf8f01"))
    }

    @Test func httpServerAndFetch() async throws {
        let (code, c) = try await run("""
        const http = require("http");
        const srv = http.createServer((req, res) => {
          let body = ""; req.on("data", (d) => { body += d; }); req.on("end", () => {
            res.setHeader("x-odete", "1");
            if (req.url === "/json") { res.writeHead(200, { "content-type": "application/json" }); res.end(JSON.stringify({ m: req.method, b: body })); }
            else { res.statusCode = 404; res.end("nada"); }
          });
        });
        srv.listen(0, async () => { try {
          const port = srv.address().port;
          const r = await fetch(`http://127.0.0.1:${port}/json`, { method: "POST", body: "oi" });
          console.log(r.status, r.headers.get("x-odete"), JSON.stringify(await r.json()));
          const r2 = await fetch(`http://127.0.0.1:${port}/x`);
          console.log(r2.status, await r2.text());
          http.get(`http://127.0.0.1:${port}/json`, (res) => {
            let d = "";
            res.on("data", (x) => d += x);
            res.on("end", () => {
              console.log("client", res.statusCode, d);
              srv.close(() => console.log("fechou"));
            });
          });
        } catch (e) { console.log("ERR", e.message, e.cause && e.cause.message); srv.close(); } });
        """)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(c.stdout.contains("200 1 {\"m\":\"POST\",\"b\":\"oi\"}"))
        #expect(c.stdout.contains("404 nada"))
        #expect(c.stdout.contains("client 200 {\"m\":\"GET\",\"b\":\"\"}"))
        #expect(c.stdout.contains("fechou"))
    }

    @Test func killStopsServer() async throws {
        let dir = try tmp()
        let cap = Capture()
        let p = JSProcess(cwd: dir, output: cap.handler)
        let task = Task {
            await p
                .run(code: "require('http').createServer((q, s) => s.end('x')).listen(4321, () => console.log('up'));")
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(p.ports == [4321])
        p.kill()
        let code = await task.value
        #expect(code == 130 && cap.stdout == "up")
    }
}
