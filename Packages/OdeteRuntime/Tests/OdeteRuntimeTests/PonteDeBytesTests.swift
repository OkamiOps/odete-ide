import CryptoKit
import Foundation
@testable import OdeteRuntime
import Testing

/// O codificador, o decodificador e o base64 de referência em JS: o nativo tem de dar
/// exatamente o mesmo resultado. O base64 é o do bootstrap.js de antes das funções nativas;
/// o UTF-8 é o do Node (TextEncoder/Buffer): substituto solto vira U+FFFD na ida, e na volta
/// cada byte fora de uma sequência válida (Tabela 3-7 do Unicode) vira um U+FFFD — o
/// decodificador antigo engolia os bytes seguintes a um 0xFF.
private let jsAntigo = """
function antigoEncode(str) {
  const out = [];
  for (let i = 0; i < str.length; i++) {
    let c = str.charCodeAt(i);
    if (c >= 0xd800 && c < 0xdc00 && i + 1 < str.length) { const d = str.charCodeAt(i + 1); if (d >= 0xdc00 && d < 0xe000) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; } }
    if (c >= 0xd800 && c < 0xe000) c = 0xfffd;
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  return new Uint8Array(out);
}
function antigoDecode(b) {
  // Faixas válidas do segundo byte por líder (Tabela 3-7); os demais de continuação são 80–BF.
  const segundo = (c) => c === 0xe0 ? [0xa0, 0xbf] : c === 0xed ? [0x80, 0x9f] : c === 0xf0 ? [0x90, 0xbf] : c === 0xf4 ? [0x80, 0x8f] : [0x80, 0xbf];
  let s = "", i = 0;
  const n = b.length;
  while (i < n) {
    const c = b[i];
    const tam = c < 0x80 ? 1 : c >= 0xc2 && c <= 0xdf ? 2 : c >= 0xe0 && c <= 0xef ? 3 : c >= 0xf0 && c <= 0xf4 ? 4 : 0;
    if (tam === 1) { s += String.fromCharCode(c); i++; continue; }
    if (tam === 0) { s += "\\ufffd"; i++; continue; }
    let k = 1, cp = c & (tam === 2 ? 0x1f : tam === 3 ? 0x0f : 0x07);
    for (; k < tam && i + k < n; k++) {
      const [lo, hi] = k === 1 ? segundo(c) : [0x80, 0xbf];
      if (b[i + k] < lo || b[i + k] > hi) break;
      cp = (cp << 6) | (b[i + k] & 63);
    }
    if (k < tam) { s += "\\ufffd"; i += k; continue; } // parte máxima inválida: um U+FFFD só
    s += String.fromCodePoint(cp); i += tam;
  }
  return s;
}
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function antigoB64Enc(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i], b = bytes[i + 1], c = bytes[i + 2];
    s += B64[a >> 2] + B64[((a & 3) << 4) | (b >> 4)] + (b === undefined ? "=" : B64[((b & 15) << 2) | (c >> 6)]) + (c === undefined ? "=" : B64[c & 63]);
  }
  return s;
}
function antigoB64Dec(str) {
  const clean = String(str).replace(/[^A-Za-z0-9+/]/g, "");
  const out = [];
  for (let i = 0; i < clean.length; i += 4) {
    const n = [0, 1, 2, 3].map((k) => B64.indexOf(clean[i + k] || "A"));
    out.push((n[0] << 2) | (n[1] >> 4));
    if (clean[i + 2] !== undefined) out.push(((n[1] & 15) << 4) | (n[2] >> 2));
    if (clean[i + 3] !== undefined) out.push(((n[2] & 3) << 6) | n[3]);
  }
  return new Uint8Array(out);
}
// Aleatório com semente, para a varredura ser sempre a mesma.
let semente = 0x9e3779b9;
const aleatorio = () => { semente ^= semente << 13; semente ^= semente >>> 17; semente ^= semente << 5; return (semente >>> 0) / 4294967296; };
const iguais = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
const H = globalThis.__odete;
const falhas = [];
const falha = (o) => { if (falhas.length < 20) falhas.push(o); };
"""

struct PonteDeBytesTests {
    /// Roda JS que termina imprimindo `falhas` em JSON; devolve (código, falhas, saída).
    private func verifica(_ corpo: String, cwd: URL? = nil) async throws -> (Int32, String, Capture) {
        let (code, c) = try await run(jsAntigo + corpo + "\nconsole.log('FALHAS ' + JSON.stringify(falhas));", cwd: cwd)
        let linha = c.stdout.split(separator: "\n").last { $0.hasPrefix("FALHAS ") } ?? "FALHAS ?"
        return (code, String(linha.dropFirst(7)), c)
    }

    @Test func utf8IgualAoNode() async throws {
        let (code, falhas, c) = try await verifica("""
        const casos = ["", "a", "abc", "olá, ação, coração", "日本語のテキスト", "한국어", "🎉👍🏽 família 👨‍👩‍👧",
          "\\u0000\\u0001\\u007f\\u0080\\u07ff\\u0800\\uffff", "\\ud800", "a\\udc00b", "\\ud83d", "x\\ud83d\\ude00y",
          "\\udbff\\udfff", "\\ud800\\ud800\\udc00", "\\ufeffcom BOM"];
        // três tamanhos: laço JS (< 16), laço Swift (< 256) e conversor do CoreFoundation (≥ 256)
        for (const base of casos) for (const s of [base, base.repeat(40), base.repeat(300)]) {
          const velho = antigoEncode(s);
          if (!iguais(H.utf8Encode(s), velho)) falha({ encode: s.slice(0, 20) });
          if (!iguais(new TextEncoder().encode(s), velho)) falha({ textEncoder: s.slice(0, 20) });
          if (H.utf8Length(s) !== velho.length || Buffer.byteLength(s) !== velho.length) falha({ tamanho: s.slice(0, 20) });
          if (H.utf8Decode(velho) !== antigoDecode(velho)) falha({ decode: s.slice(0, 20) });
          if (Buffer.from(s).toString() !== antigoDecode(velho)) falha({ buffer: s.slice(0, 20) });
        }
        // bytes inválidos: continuação solta, líder sem continuação, sequência cortada no fim,
        // overlong, substituto codificado, acima de U+10FFFF, líder 0xF8–0xFF
        const invalidos = [[0x80], [0xbf, 0x41], [0xc0, 0x80], [0xc1, 0xbf], [0xc2], [0x41, 0xc3], [0xe2, 0x82], [0xe2, 0x28, 0xa1],
          [0xf0, 0x9f, 0x98], [0xf0, 0x9f], [0xed, 0xa0, 0x80], [0xed, 0xbf, 0xbf, 0x41], [0xf4, 0x90, 0x80, 0x80],
          [0xf5, 0x80, 0x80, 0x80], [0xf8, 0x80, 0x80, 0x80], [0xff, 0xfe, 0xfd], [0xe0, 0x80, 0x80], [0xf0, 0x80, 0x80, 0x80]];
        for (const v of invalidos) {
          const u = Uint8Array.from(v);
          if (H.utf8Decode(u) !== antigoDecode(u)) falha({ invalido: v });
        }
        // varredura: bytes aleatórios puxados para a faixa alta, de todos os tamanhos
        for (let k = 0; k < 3000; k++) {
          const n = Math.floor(aleatorio() * 200);
          const u = new Uint8Array(n);
          for (let i = 0; i < n; i++) u[i] = aleatorio() < 0.5 ? 0x80 + Math.floor(aleatorio() * 128) : Math.floor(aleatorio() * 256);
          if (H.utf8Decode(u) !== antigoDecode(u)) falha({ varredura: Array.from(u) });
          if (new TextDecoder().decode(u) !== (() => { const t = antigoDecode(u); return t.charCodeAt(0) === 0xfeff ? t.slice(1) : t; })()) falha({ textDecoder: Array.from(u) });
        }
        // vista com deslocamento dentro de um buffer maior (o ponteiro nativo soma o byteOffset)
        const grande = antigoEncode("xxxxxolá mundo " + "é".repeat(80));
        for (const [a, b] of [[5, grande.length], [5, 20], [1, 70]]) {
          const vista = grande.subarray(a, b);
          if (H.utf8Decode(vista) !== antigoDecode(vista)) falha({ vista: [a, b] });
          if (H.utf8Decode(new DataView(grande.buffer, a, b - a).buffer.slice(a, b)) !== antigoDecode(vista)) falha({ arrayBuffer: [a, b] });
          if (new TextDecoder().decode(new DataView(grande.buffer, a, b - a)) !== antigoDecode(vista)) falha({ dataView: [a, b] });
        }
        """)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(falhas == "[]", Comment(rawValue: falhas))
    }

    @Test func bomEEncodeInto() async throws {
        let (code, falhas, c) = try await verifica("""
        const bom = [0xef, 0xbb, 0xbf];
        for (const texto of ["a", "texto longo ".repeat(10)]) {
          const u = Uint8Array.from([...bom, ...antigoEncode(texto)]);
          if (new TextDecoder().decode(u) !== texto) falha({ semBOM: texto.length });
          if (new TextDecoder("utf-8", { ignoreBOM: true }).decode(u) !== "\\ufeff" + texto) falha({ ignoreBOM: texto.length });
          if (Buffer.from(u).toString() !== "\\ufeff" + texto) falha({ bufferMantemBOM: texto.length });
        }
        // destino grande: igual a encode
        const enc = new TextEncoder();
        for (const s of ["olá 🎉", "olá 🎉 ".repeat(30)]) {
          const d = new Uint8Array(1000);
          const r = enc.encodeInto(s, d);
          const e = antigoEncode(s);
          if (r.read !== s.length || r.written !== e.length || !iguais(d.subarray(0, r.written), e)) falha({ encodeIntoGrande: s.length, r });
        }
        // destino pequeno: nunca corta um ponto de código; nativo e JS concordam
        const s = "aé日🎉b";
        for (let cap = 0; cap <= 12; cap++) {
          const dj = new Uint8Array(cap), dn = new Uint8Array(cap);
          const rj = enc.encodeInto(s, dj), rn = H.utf8EncodeInto(s, dn);
          if (rj.read !== rn.read || rj.written !== rn.written || !iguais(dj, dn)) falha({ cap, rj, rn });
          const esperado = [[0, 0], [1, 1], [1, 1], [2, 3], [2, 3], [2, 3], [3, 6], [3, 6], [3, 6], [3, 6], [5, 10], [6, 11], [6, 11]][cap];
          if (rn.read !== esperado[0] || rn.written !== esperado[1]) falha({ cap, rn, esperado });
          if (!iguais(dn.subarray(0, rn.written), antigoEncode(s.slice(0, rn.read)))) falha({ bytes: cap });
        }
        const longa = "é".repeat(100);
        const r = H.utf8EncodeInto(longa, new Uint8Array(101));
        if (r.read !== 50 || r.written !== 100) falha({ longaCortada: r });
        """)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(falhas == "[]", Comment(rawValue: falhas))
    }

    @Test func latin1Utf16EBase64IguaisAoJSAntigo() async throws {
        let (code, falhas, c) = try await verifica("""
        // latin1: todos os bytes; pares substitutos viram um byte só, como Uint8Array.from
        const todos = Uint8Array.from({ length: 256 }, (_, i) => i);
        const jsLatin1 = (u) => { let s = ""; for (const x of u) s += String.fromCharCode(x); return s; };
        if (H.latin1Decode(todos) !== jsLatin1(todos)) falha("latin1Decode");
        if (Buffer.from(todos).toString("latin1") !== jsLatin1(todos) || new TextDecoder("latin1").decode(todos) !== jsLatin1(todos)) falha("latin1 via Buffer/TextDecoder");
        for (const s of ["ação ÿ", "x🎉y\\ud800z" + "é".repeat(70), "日本"]) {
          const velho = Uint8Array.from(s, (ch) => ch.charCodeAt(0) & 255);
          if (!iguais(H.latin1Encode(s), velho)) falha({ latin1Encode: s.slice(0, 10) });
          if (!iguais(Buffer.from(s, "binary"), velho)) falha({ binary: s.slice(0, 10) });
        }
        if (atob(btoa("\\u00ff\\u0000abc".repeat(30))) !== "\\u00ff\\u0000abc".repeat(30)) falha("btoa/atob");
        // utf16le, inclusive tamanho ímpar
        for (const n of [0, 1, 2, 7, 64, 129]) {
          const u = Uint8Array.from({ length: n }, (_, i) => (i * 37 + 11) & 255);
          let esperado = ""; for (let i = 0; i + 1 < u.length; i += 2) esperado += String.fromCharCode(u[i] | (u[i + 1] << 8));
          if (H.utf16leDecode(u) !== esperado || new TextDecoder("utf-16le").decode(u) !== esperado || Buffer.from(u).toString("utf16le") !== esperado) falha({ utf16le: n });
        }
        // base64: todos os restos, lixo no meio, os dois alfabetos
        for (let n = 0; n < 150; n++) {
          const u = Uint8Array.from({ length: n }, () => Math.floor(aleatorio() * 256));
          const velho = antigoB64Enc(u);
          if (H.b64Encode(u, false) !== velho || Buffer.from(u).toString("base64") !== velho) falha({ b64enc: n });
          const url = velho.replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
          if (H.b64Encode(u, true) !== url || Buffer.from(u).toString("base64url") !== url) falha({ b64url: n });
          if (!iguais(H.b64Decode(velho, false), antigoB64Dec(velho))) falha({ b64dec: n });
          if (!iguais(H.b64Decode(url, true), antigoB64Dec(url.replace(/-/g, "+").replace(/_/g, "/")))) falha({ b64decUrl: n });
        }
        const sujos = ["QUJD\\nREVG", "  QUJ DRA==  ", "Q", "QU", "QUJ", "QUJDR", "=Q=U=J=D", "QUJD-_é日", "-_-_", "ab+/cd-_", ""];
        for (const s of sujos) {
          if (!iguais(H.b64Decode(s, false), antigoB64Dec(s))) falha({ sujo: s });
          if (!iguais(H.b64Decode(s, true), antigoB64Dec(s.replace(/-/g, "+").replace(/_/g, "/")))) falha({ sujoUrl: s });
          const longo = s.repeat(20);
          if (!iguais(Buffer.from(longo, "base64"), antigoB64Dec(longo))) falha({ sujoLongo: s });
        }
        // hash, zlib e aleatório pela ponte de bytes
        const crypto = require("crypto"), zlib = require("zlib");
        if (crypto.createHash("sha384").update("abc").digest("hex") !== "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7") falha("sha384");
        if (crypto.createHash("md5").update(Buffer.from([0, 1, 2])).digest("base64") !== "uV9n9h67A2GWIteY9F/C0w==") falha("md5");
        const grande = crypto.randomBytes(200000);
        if (!iguais(zlib.gunzipSync(zlib.gzipSync(grande)), grande)) falha("gzip");
        crypto.subtle.digest("SHA-256", new TextEncoder().encode("abc")).then((ab) => {
          if (Buffer.from(ab).toString("hex") !== "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") falha("subtle");
          const r = crypto.getRandomValues(new Uint32Array(8));
          if (r.every((x) => x === 0)) falha("getRandomValues");
          console.log("FALHAS " + JSON.stringify(falhas));
        });
        """)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(falhas == "[]", Comment(rawValue: falhas))
        #expect(c.stdout.split(separator: "\n").last == "FALHAS []", Comment(rawValue: c.stdout))
    }

    @Test func arquivoBinarioIdaEVolta() async throws {
        let dir = try tmp()
        let (code, c) = try await run("""
        const fs = require("fs"), crypto = require("crypto");
        const zeros = Buffer.from([0, 1, 0, 255, 0, 0, 128, 0]);
        fs.writeFileSync("zeros.bin", zeros);
        const lido = fs.readFileSync("zeros.bin");
        console.log("zeros", Buffer.isBuffer(lido), Array.from(lido).join(","));
        fs.appendFileSync("zeros.bin", Uint8Array.of(0, 42));
        console.log("append", Array.from(fs.readFileSync("zeros.bin")).join(","));
        const grande = Buffer.from([9, 9, 9, 1, 2, 3, 9]);
        fs.writeFileSync("vista.bin", grande.subarray(3, 6));
        fs.writeFileSync("u16.bin", new Uint16Array([0x0102, 0x0304]));
        fs.writeFileSync("dv.bin", new DataView(Uint8Array.of(7, 8, 9).buffer, 1, 2));
        fs.writeFileSync("ab.bin", Uint8Array.of(5, 6).buffer);
        fs.writeFileSync("b64.txt", "AAEC/w==", "base64");
        console.log("tipos", ["vista", "u16", "dv", "ab"].map((n) => Array.from(fs.readFileSync(n + ".bin")).join(",")).join(" "), Array.from(fs.readFileSync("b64.txt")).join(","));
        console.log("codificado", fs.readFileSync("zeros.bin", "base64"), fs.readFileSync("zeros.bin", "hex"), fs.readFileSync("zeros.bin", { encoding: "latin1" }).length);
        const rnd = crypto.randomBytes(5 * 1024 * 1024);
        fs.writeFileSync("rnd.bin", rnd);
        const volta = fs.readFileSync("rnd.bin");
        const h = (b) => crypto.createHash("sha256").update(b).digest("hex");
        console.log("rnd", volta.length, h(volta) === h(rnd), Buffer.compare(volta, rnd), h(rnd));
        const erros = [["ausente", () => fs.readFileSync("nao-existe.bin")], ["pasta", () => fs.readFileSync(".")],
          ["semPasta", () => fs.writeFileSync("nao/existe.bin", zeros)], ["nul", () => fs.writeFileSync("nul\\u0000x.bin", zeros)]];
        for (const [nome, fn] of erros) {
          try { fn(); console.log("erro", nome, "nenhum"); } catch (e) { console.log("erro", nome, e.code); }
        }
        fs.promises.readFile("rnd.bin").then((b) => fs.readFile("zeros.bin", (e, z) => console.log("async", b.length, h(b) === h(rnd), Array.from(z).join(","))));
        """, cwd: dir)
        #expect(code == 0, Comment(rawValue: c.stderr))
        let out = c.stdout
        #expect(out.contains("zeros true 0,1,0,255,0,0,128,0"))
        #expect(out.contains("append 0,1,0,255,0,0,128,0,0,42"))
        #expect(out.contains("tipos 1,2,3 2,1,4,3 8,9 5,6 0,1,2,255"))
        #expect(out.contains("codificado AAEA/wAAgAAAKg== 000100ff00008000002a 10"))
        #expect(out.contains("rnd 5242880 true 0"))
        #expect(out.contains("erro ausente ENOENT") && out.contains("erro pasta EISDIR") && out.contains("erro semPasta ENOENT"))
        // NUL no caminho não pode virar um arquivo "nul" (o caminho cortado em C)
        #expect(out.contains("erro nul ENOENT"))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "nul").path))
        #expect(out.contains("async 5242880 true 0,1,0,255,0,0,128,0,0,42"))
        // O que o JS escreveu é o que está no disco.
        let zeros = try Data(contentsOf: dir.appending(path: "zeros.bin"))
        #expect(Array(zeros) == [0, 1, 0, 255, 0, 0, 128, 0, 0, 42])
        let rnd = try Data(contentsOf: dir.appending(path: "rnd.bin"))
        let hex = SHA256.hash(data: rnd).map { String(format: "%02x", $0) }.joined()
        #expect(out.contains(hex))
    }

    @Test func corpoHttpEmBytes() async throws {
        let (code, c) = try await run("""
        const http = require("http"), crypto = require("crypto"), H = globalThis.__odete;
        const corpo = Buffer.from([0, 1, 2, 255, 0, 128, 10, 13, 0]);
        const srv = http.createServer((req, res) => {
          const partes = []; req.on("data", (d) => partes.push(d)); req.on("end", () => {
            const b = Buffer.concat(partes);
            if (req.url === "/eco") { res.end(b); return; }
            if (req.url === "/velho") { res.writeHead(200, { "content-length": 5 }); H.httpWrite(res._sid, res._rid, Buffer.from("velho").toString("base64"), true); return; }
            res.writeHead(200, { "content-type": "application/octet-stream" }); // sem tamanho: chunked
            res.write(b.subarray(0, 3)); res.write(new Uint16Array([0x0201])); res.end(Buffer.concat([b.subarray(3), Buffer.from([0])]));
          });
        });
        srv.listen(0, async () => { try {
          const base = `http://127.0.0.1:${srv.address().port}`;
          const r = await fetch(base + "/partes", { method: "POST", body: corpo });
          console.log("fetch", r.status, Array.from(new Uint8Array(await r.arrayBuffer())).join(","));
          const grande = crypto.randomBytes(1 << 20);
          const r2 = await fetch(base + "/eco", { method: "PUT", body: grande });
          const volta = Buffer.from(await r2.arrayBuffer());
          console.log("eco", volta.length, Buffer.compare(volta, grande));
          console.log("velho", await (await fetch(base + "/velho")).text());
          const req = http.request(base + "/eco", { method: "POST" }, (res) => {
            const p = []; res.on("data", (d) => p.push(d)); res.on("end", () => { console.log("request", Array.from(Buffer.concat(p)).join(",")); srv.close(); });
          });
          req.end(Uint8Array.of(0, 200, 0));
        } catch (e) { console.log("ERR", e.message); srv.close(); } });
        """)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(c.stdout.contains("fetch 200 0,1,2,1,2,255,0,128,10,13,0,0"), Comment(rawValue: c.stdout))
        #expect(c.stdout.contains("eco 1048576 0"))
        #expect(c.stdout.contains("velho velho"))
        #expect(c.stdout.contains("request 0,200,0"))
    }
}
