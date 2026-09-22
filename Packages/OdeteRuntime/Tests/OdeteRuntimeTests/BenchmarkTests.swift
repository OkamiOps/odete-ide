import Foundation
@testable import OdeteRuntime
import Testing

/// Medidas de desempenho dos caminhos quentes da ponte (leitura binária, UTF-8, base64).
///
/// Só roda com `ODETE_BENCH=1` no ambiente do executor de testes (no xcodebuild:
/// `TEST_RUNNER_ODETE_BENCH=1`), porque sem JIT (`TEST_RUNNER_JSC_useJIT=false`, o que o iPad
/// de verdade impõe a apps de terceiros) o caminho antigo leva segundos. Imprime linhas `BENCH`.
struct BenchmarkTests {
    static let ligado = ProcessInfo.processInfo.environment["ODETE_BENCH"] == "1"

    /// O esbuild.wasm do pacote do bundler, lido pelo caminho absoluto do repositório.
    static var wasm: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // OdeteRuntimeTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // OdeteRuntime
            .deletingLastPathComponent() // Packages
            .appending(path: "OdeteBundler/Sources/OdeteBundler/Resources/esbuild/esbuild.wasm")
            .path
    }

    /// Um build do esbuild-wasm de 100 módulos com plugin de sistema de arquivos (o que o
    /// bundler.js faz), e o mesmo build com o piso de 1 ms do Node imposto ao `setTimeout(fn)` sem
    /// atraso — que o browser.js do esbuild usa para mandar cada mensagem ao Go. Mostra por que o
    /// bootstrap.js deixa o setTimeout de 0 na próxima volta do laço.
    @Test(.enabled(if: ligado)) func esbuildComPlugin() async throws {
        let dir = try tmp()
        let cap = Capture()
        let p = JSProcess(cwd: dir, output: cap.handler)
        let watchdog = Task { try? await Task.sleep(for: .seconds(600)); p.kill() }
        let browser = (Self.wasm as NSString).deletingLastPathComponent + "/browser.js"
        let code = await p.run(code: """
        const fs = require("fs"), path = require("path");
        const agora = () => performance.now();
        (async () => {
          (0, eval)(fs.readFileSync(\(browser.debugDescription), "utf8"));
          let t = agora();
          const mod = new WebAssembly.Module(fs.readFileSync(\(Self.wasm.debugDescription)));
          await esbuild.initialize({ wasmModule: mod, worker: false });
          console.log("BENCH esbuild-init " + (agora() - t).toFixed(0) + " ms");
          fs.mkdirSync("src", { recursive: true });
          let idx = "";
          for (let i = 0; i < 100; i++) { fs.writeFileSync(`src/m${i}.js`, `export const v${i} = ${i};`); idx += `import { v${i} } from "./m${i}.js"; console.log(v${i});\\n`; }
          fs.writeFileSync("src/index.js", idx);
          const plugin = { name: "fs", setup(b) {
            b.onResolve({ filter: /.*/ }, (a) => ({ path: path.resolve(a.resolveDir || process.cwd(), a.path) }));
            b.onLoad({ filter: /.*/ }, (a) => ({ contents: fs.readFileSync(a.path, "utf8"), loader: "js" }));
          } };
          const build = () => esbuild.build({ entryPoints: [path.resolve("src/index.js")], bundle: true, write: false, format: "esm", plugins: [plugin], logLevel: "silent" });
          await build();
          // Alterna as duas variantes (a máquina é compartilhada) e fica com a mediana de 7.
          const original = globalThis.setTimeout;
          const pisoDoNode = (fn, ms, ...a) => original(fn, Number(ms) >= 1 ? ms : 1, ...a);
          const tempos = { padrao: [], node: [] };
          for (let i = 0; i < 7; i++) for (const v of ["padrao", "node"]) {
            globalThis.setTimeout = v === "padrao" ? original : pisoDoNode;
            const t0 = agora(); const r = await build(); tempos[v].push(agora() - t0);
            if (!r.outputFiles[0].text.includes("v99")) throw new Error("build incompleto");
          }
          globalThis.setTimeout = original;
          const mediana = (a) => a.sort((x, y) => x - y)[a.length >> 1].toFixed(0);
          console.log("BENCH esbuild-build-100-modulos " + mediana(tempos.padrao) + " ms (mediana de 7)");
          console.log("BENCH esbuild-build-100-modulos-piso-1ms-do-node " + mediana(tempos.node) + " ms (mediana de 7)");
          process.exit(0);
        })().catch((e) => { console.error(e && e.stack || String(e)); process.exit(1); });
        """)
        watchdog.cancel()
        #expect(code == 0, Comment(rawValue: cap.stderr))
        for linha in cap.stdout.split(separator: "\n") where linha.hasPrefix("BENCH") {
            print(linha)
        }
    }

    @Test(.enabled(if: ligado)) func pontesQuentes() async throws {
        let dir = try tmp()
        let cap = Capture()
        let p = JSProcess(cwd: dir, output: cap.handler)
        let watchdog = Task { try? await Task.sleep(for: .seconds(600)); p.kill() }
        let code = await p.run(code: """
        const fs = require("fs");
        const agora = () => performance.now();
        const mede = (nome, fn, vezes = 3) => {
          let melhor = Infinity, r;
          for (let i = 0; i < vezes; i++) { const t = agora(); r = fn(); melhor = Math.min(melhor, agora() - t); }
          console.log("BENCH " + nome + " " + melhor.toFixed(1) + " ms");
          return r;
        };
        // calibração: um laço puro, para ver se o JIT está ligado
        mede("laco-10M", () => { let x = 0; for (let i = 0; i < 1e7; i++) x = (x + i) | 0; return x; }, 1);
        const wasm = mede("readFileSync-esbuild.wasm", () => fs.readFileSync(\(Self.wasm.debugDescription)));
        console.log("BENCH tamanho-wasm " + wasm.length);
        const cinco = 5 * 1024 * 1024;
        const enc = new TextEncoder(), dec = new TextDecoder();
        const pedaco = "olá mundo, ação! 日本語 🎉 abc123\\n";
        const razao = enc.encode(pedaco).length / pedaco.length; // bytes por unidade UTF-16
        const misto = pedaco.repeat(Math.ceil(cinco / razao / pedaco.length));
        const ascii = "const x = require('y'); // comentario ascii\\n".repeat(Math.ceil(cinco / 44)).slice(0, cinco);
        const bMisto = mede("TextEncoder.encode-5MB-misto", () => enc.encode(misto));
        const bAscii = mede("TextEncoder.encode-5MB-ascii", () => enc.encode(ascii));
        console.log("BENCH bytes-misto " + bMisto.length + " bytes-ascii " + bAscii.length);
        const sMisto = mede("TextDecoder.decode-5MB-misto", () => dec.decode(bMisto));
        const sAscii = mede("TextDecoder.decode-5MB-ascii", () => dec.decode(bAscii));
        console.log("BENCH confere " + (sMisto === misto) + " " + (sAscii === ascii));
        const b64 = mede("Buffer.toString-base64-5MB", () => Buffer.from(bAscii.buffer, bAscii.byteOffset, bAscii.length).toString("base64"));
        mede("Buffer.from-base64-5MB", () => Buffer.from(b64, "base64"));
        mede("writeFileSync-5MB", () => fs.writeFileSync("saida.bin", bMisto));
        const pequeno = "olá";
        mede("encode+decode-curto-x10000", () => { let n = 0; for (let i = 0; i < 10000; i++) n += dec.decode(enc.encode(pequeno + i)).length; return n; });
        // Limiar entre o laço JS e a ponte nativa (NATIVO no bootstrap.js): custo por chamada.
        const H = globalThis.__odete;
        if (H.utf8Decode) {
          // Cópias dos laços JS do bootstrap.js, para medir o caminho que fica abaixo do limiar.
          const decJS = (b) => {
            let s = "", i = 0;
            const n = b.length;
            while (i < n) {
              const c = b[i++];
              if (c < 0x80) { s += String.fromCharCode(c); continue; }
              if (c < 0xc2) { s += "\\ufffd"; continue; }
              if (c < 0xe0) { if (i >= n) { s += "\\ufffd"; break; } s += String.fromCharCode(((c & 31) << 6) | (b[i++] & 63)); continue; }
              if (c < 0xf0) { if (i + 1 >= n) { s += "\\ufffd"; break; } s += String.fromCharCode(((c & 15) << 12) | ((b[i++] & 63) << 6) | (b[i++] & 63)); continue; }
              if (i + 2 >= n) { s += "\\ufffd"; break; }
              const cp = ((c & 7) << 18) | ((b[i++] & 63) << 12) | ((b[i++] & 63) << 6) | (b[i++] & 63);
              s += cp > 0x10ffff ? "\\ufffd" : String.fromCodePoint(cp);
            }
            return s;
          };
          const encJS = (str) => {
            const out = [];
            for (let i = 0; i < str.length; i++) {
              let c = str.charCodeAt(i);
              if (c >= 0xd800 && c < 0xdc00 && i + 1 < str.length) { const d = str.charCodeAt(i + 1); if (d >= 0xdc00 && d < 0xe000) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; } }
              if (c < 0x80) out.push(c);
              else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
              else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
              else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
            }
            return new Uint8Array(out);
          };
          const N = 20000;
          for (const tam of [8, 16, 32, 48, 64, 96, 128, 256]) {
            const s = "abcdefghijklmnopqrstuvwxyz0123456789".repeat(10).slice(0, tam);
            const b = encJS(s);
            const us = (fn) => { const t = agora(); for (let i = 0; i < N; i++) fn(); return ((agora() - t) * 1000 / N).toFixed(2); };
            console.log(`BENCH limiar-${tam} decode js ${us(() => decJS(b))} nativo ${us(() => H.utf8Decode(b))} | encode js ${us(() => encJS(s))} nativo ${us(() => H.utf8Encode(s))} µs`);
          }
        }
        """)
        watchdog.cancel()
        #expect(code == 0, Comment(rawValue: cap.stderr))
        for linha in cap.stdout.split(separator: "\n") where linha.hasPrefix("BENCH") {
            print(linha)
        }
    }
}
