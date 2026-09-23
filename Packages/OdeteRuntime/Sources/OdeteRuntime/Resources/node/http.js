__nodeDefine("http", (module, exports, require) => {
  const H = globalThis.__odete, EE = require("events"), { Readable, Writable } = require("stream");
  const STATUS_CODES = { 100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content", 301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 410: "Gone", 413: "Payload Too Large", 415: "Unsupported Media Type", 422: "Unprocessable Entity", 429: "Too Many Requests", 500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable" };
  const METHODS = ["GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "CONNECT", "TRACE"];
  const servers = new Map();

  class IncomingMessage extends Readable {
    constructor(method, url, headers, body) { super(); this.method = method; this.url = url; this.headers = headers; this.rawHeaders = Object.entries(headers).flat(); this.httpVersion = "1.1"; this.httpVersionMajor = 1; this.httpVersionMinor = 1; this.complete = true; this.aborted = false; this.socket = this.connection = { remoteAddress: "127.0.0.1", remotePort: 0, localAddress: "127.0.0.1", encrypted: false, setTimeout() {}, setNoDelay() {}, setKeepAlive() {}, on() {}, once() {}, destroy() {}, end() {} }; this._body = body; this.trailers = {}; this.statusCode = null; this.statusMessage = null; }
    _read() { if (this._body !== undefined) { const b = this._body; this._body = undefined; if (b && b.length) this.push(b); this.push(null); } }
    setTimeout(ms, cb) { if (cb) this.once("timeout", cb); return this; }
    get(name) { return this.headers[String(name).toLowerCase()]; }
  }
  class OutgoingMessage extends Writable {
    constructor() { super(); this._headers = {}; this.headersSent = false; this.finished = false; this.statusCode = 200; this.statusMessage = undefined; this.sendDate = true; this.socket = this.connection = { remoteAddress: "127.0.0.1", encrypted: false, on() {}, once() {}, setTimeout() {}, setNoDelay() {}, setKeepAlive() {}, destroy() {}, writable: true }; this.useChunkedEncodingByDefault = true; this.chunkedEncoding = false; this.shouldKeepAlive = true; }
    setHeader(k, v) { this._headers[String(k).toLowerCase()] = v; return this; } getHeader(k) { return this._headers[String(k).toLowerCase()]; } removeHeader(k) { delete this._headers[String(k).toLowerCase()]; } hasHeader(k) { return String(k).toLowerCase() in this._headers; } getHeaders() { return { ...this._headers }; } getHeaderNames() { return Object.keys(this._headers); } appendHeader(k, v) { const cur = this.getHeader(k); this.setHeader(k, cur == null ? v : [].concat(cur, v)); return this; } setHeaders(h) { for (const [k, v] of h instanceof Map ? h : Object.entries(h)) this.setHeader(k, v); return this; }
    setTimeout(ms, cb) { if (cb) this.once("timeout", cb); return this; } flushHeaders() { this._sendHead(); } addTrailers() {} cork() {} uncork() {}
    _flatHeaders() { const out = {}; for (const [k, v] of Object.entries(this._headers)) out[k] = Array.isArray(v) ? v.join(", ") : String(v); return out; }
  }
  class ServerResponse extends OutgoingMessage {
    constructor(sid, rid, req) { super(); this._sid = sid; this._rid = rid; this.req = req; }
    writeHead(status, msg, headers) { if (typeof msg === "object") { headers = msg; msg = undefined; } this.statusCode = status; if (msg) this.statusMessage = msg; if (headers) { if (Array.isArray(headers)) { for (let i = 0; i < headers.length; i += 2) this.setHeader(headers[i], headers[i + 1]); } else for (const [k, v] of Object.entries(headers)) this.setHeader(k, v); } this._sendHead(); return this; }
    _sendHead() { if (this.headersSent) return; this.headersSent = true; H.httpWriteHead(this._sid, this._rid, this.statusCode, this._flatHeaders()); }
    // O corpo vai ao Swift como bytes (Uint8Array), sem passar por base64.
    _write(chunk, enc, cb) { this._sendHead(); H.httpWrite(this._sid, this._rid, globalThis.__comoBytes(chunk, enc), false); cb(); }
    end(chunk, enc, cb) { if (typeof chunk === "function") { cb = chunk; chunk = undefined; } if (typeof enc === "function") { cb = enc; enc = undefined; } if (this.finished) { if (cb) cb(); return this; } if (chunk != null) { const b = globalThis.__comoBytes(chunk, enc); if (!this.headersSent && !this.hasHeader("content-length") && !this.hasHeader("transfer-encoding")) this.setHeader("content-length", b.length); this._sendHead(); H.httpWrite(this._sid, this._rid, b, true); } else { if (!this.headersSent && !this.hasHeader("content-length") && !this.hasHeader("transfer-encoding")) this.setHeader("content-length", 0); this._sendHead(); H.httpWrite(this._sid, this._rid, null, true); } this.finished = true; this.writableEnded = true; this.writableFinished = true; queueMicrotask(() => { this.emit("finish"); this.emit("close"); if (cb) cb(); }); return this; }
    writeContinue() {} writeProcessing() {} assignSocket() {} detachSocket() {}
  }
  class Server extends EE {
    constructor(opts, handler) { super(); if (typeof opts === "function") { handler = opts; opts = {}; } if (handler) this.on("request", handler); this._id = null; this.listening = false; this.timeout = 0; this.keepAliveTimeout = 5000; this.headersTimeout = 60000; this.requestTimeout = 300000; this.maxHeadersCount = null; this._ws = new Map(); }
    listen(...args) { let port = 0, cb; for (const a of args) { if (typeof a === "function") cb = a; else if (typeof a === "number" || (typeof a === "string" && /^\d+$/.test(a))) port = Number(a); else if (a && typeof a === "object" && a.port != null) port = Number(a.port); } if (cb) this.once("listening", cb); const r = H.httpListen(port); if (r.error) { queueMicrotask(() => this.emit("error", Object.assign(new Error("listen EADDRINUSE: address already in use :" + port), { code: "EADDRINUSE", port }))); return this; } this._id = r.id; servers.set(r.id, this); return this; }
    address() { return this._port ? { address: "127.0.0.1", family: "IPv4", port: this._port } : null; }
    close(cb) { if (this._id != null) { H.httpClose(this._id); servers.delete(this._id); this._id = null; } this.listening = false; queueMicrotask(() => { this.emit("close"); if (cb) cb(); }); return this; }
    closeAllConnections() {} closeIdleConnections() {} setTimeout(ms, cb) { if (cb) this.on("timeout", cb); return this; } ref() { return this; } unref() { return this; }
    // O corpo chega do Swift como Uint8Array (string base64 no formato antigo ainda vale).
    _handle(rid, method, url, headers, body) { const req = new IncomingMessage(method, url, headers, typeof body === "string" ? Buffer.from(body, "base64") : globalThis.__comoBuffer(body)); const res = new ServerResponse(this._id, rid, req); res.on("error", (e) => H.debug("res error: " + e.message)); if (this.listenerCount("request") === 0) { res.statusCode = 404; res.end("Not Found"); return; } try { this.emit("request", req, res); } catch (e) { globalThis.__odete_reportUncaught(e); } }
  }
  globalThis.__odete_httpListening = (id, port) => { const s = servers.get(id); if (!s) return; s._port = port; s.listening = true; s.emit("listening"); };
  globalThis.__odete_httpError = (id, msg) => { const s = servers.get(id); if (s) s.emit("error", new Error(msg)); };
  globalThis.__odete_httpRequest = (id, rid, method, url, headers, body) => { const s = servers.get(id); if (s) s._handle(rid, method, url, headers, body); };
  globalThis.__odete_wsOpen = (id, rid, url) => { const s = servers.get(id); if (!s) return; const sock = new EE(); sock.send = (t) => H.wsSend(id, rid, typeof t === "string" ? t : JSON.stringify(t)); sock.close = () => {}; sock.readyState = 1; s._ws.set(rid, sock); s.emit("odete:ws", sock, url); };
  globalThis.__odete_wsClose = (id, rid) => { const s = servers.get(id); if (!s) return; const sock = s._ws.get(rid); s._ws.delete(rid); if (sock) sock.emit("close"); };

  // cliente
  class ClientRequest extends Writable {
    constructor(url, opts, cb) { super(); if (typeof opts === "function") { cb = opts; opts = {}; } if (typeof url === "string" || url instanceof URL) { url = new URL(String(url)); opts = { ...opts, protocol: url.protocol, hostname: url.hostname, port: url.port, path: url.pathname + url.search, headers: { ...(opts && opts.headers) } }; } else if (url && typeof url === "object" && typeof opts === "function") { cb = opts; opts = url; } else if (url && typeof url === "object") { opts = { ...url, ...opts }; } this._opts = opts || {}; this._chunks = []; this.method = (this._opts.method || "GET").toUpperCase(); this.path = this._opts.path || "/"; this.aborted = false; this.socket = { on() {}, once() {}, setTimeout() {}, setNoDelay() {}, setKeepAlive() {}, destroy() {} }; this._headers = {}; for (const [k, v] of Object.entries(this._opts.headers || {})) this._headers[String(k).toLowerCase()] = String(v); if (cb) this.once("response", cb); }
    setHeader(k, v) { this._headers[String(k).toLowerCase()] = String(v); return this; } getHeader(k) { return this._headers[String(k).toLowerCase()]; } removeHeader(k) { delete this._headers[String(k).toLowerCase()]; } setTimeout(ms, cb) { if (cb) this.once("timeout", cb); return this; } setNoDelay() {} setSocketKeepAlive() {} flushHeaders() {} abort() { this.aborted = true; this.destroy(); }
    _write(c, e, cb) { this._chunks.push(Buffer.from(c)); cb(); }
    end(chunk, enc, cb) { if (typeof chunk === "function") { cb = chunk; chunk = undefined; } if (chunk != null) this._chunks.push(Buffer.from(chunk, enc)); const o = this._opts; const proto = (o.protocol || (o._https ? "https:" : "http:")).replace(/:?$/, ":"); const host = o.hostname || o.host || "localhost"; const port = o.port ? ":" + o.port : ""; const url = o.href || `${proto}//${host}${port}${this.path}`; const body = this._chunks.length ? Buffer.concat(this._chunks) : null; fetch(url, { method: this.method, headers: this._headers, body, redirect: "manual" }).then(async (r) => { const buf = Buffer.from(await r.arrayBuffer()); const headers = {}; r.headers.forEach((v, k) => { headers[k] = v; }); const res = new IncomingMessage(this.method, url, headers, buf); res.statusCode = r.status; res.statusMessage = STATUS_CODES[r.status] || ""; this.emit("response", res); }, (e) => this.emit("error", e)); Writable.prototype.end.call(this, cb); return this; }
  }
  const request = (url, opts, cb) => new ClientRequest(url, opts, cb);
  const get = (url, opts, cb) => { const r = request(url, opts, cb); r.end(); return r; };
  class Agent { constructor(o) { this.options = o || {}; this.maxSockets = Infinity; } destroy() {} }
  module.exports = { STATUS_CODES, METHODS, Server, IncomingMessage, ServerResponse, OutgoingMessage, ClientRequest, Agent, globalAgent: new Agent(), createServer: (o, h) => new Server(o, h), request, get, maxHeaderSize: 16384, validateHeaderName() {}, validateHeaderValue() {}, setMaxIdleHTTPParsers() {} };
});
__nodeDefine("https", (module, exports, require) => { const http = require("http"); module.exports = { ...http, request: (u, o, cb) => http.request(u, { ...(typeof o === "object" ? o : {}), _https: true }, typeof o === "function" ? o : cb), get: (u, o, cb) => { const r = module.exports.request(u, o, cb); r.end(); return r; }, createServer: () => { throw new Error("Odete: https.createServer não existe no iPad; use http (o preview é local)"); }, Agent: http.Agent, globalAgent: new http.Agent() }; });
__nodeDefine("net", (module, exports, require) => { const EE = require("events"); class Socket extends EE { constructor() { super(); this.remoteAddress = "127.0.0.1"; this.writable = true; } write() { return true; } end() {} destroy() {} setTimeout() { return this; } setNoDelay() { return this; } setKeepAlive() { return this; } connect() { queueMicrotask(() => this.emit("error", new Error("Odete: sockets TCP crus não existem no iPad"))); return this; } } module.exports = { Socket, createServer: () => { throw new Error("Odete: net.createServer não existe; use http.createServer"); }, connect: () => new Socket().connect(), createConnection: () => new Socket().connect(), isIP: (s) => (/^\d+\.\d+\.\d+\.\d+$/.test(s) ? 4 : s.includes(":") ? 6 : 0), isIPv4: (s) => /^\d+\.\d+\.\d+\.\d+$/.test(s), isIPv6: (s) => s.includes(":") }; });
__nodeDefine("http2", (module) => {
  // Carrega (o axios pede no topo) mas não conecta: HTTP/2 cru não existe no iPad.
  const semHttp2 = () => { throw Object.assign(new Error("Odete: http2 não existe no iPad; use http/https ou fetch"), { code: "ERR_HTTP2_UNSUPPORTED" }); };
  module.exports = { connect: semHttp2, createServer: semHttp2, createSecureServer: semHttp2, getDefaultSettings: () => ({}), getPackedSettings: () => Buffer.alloc(0), getUnpackedSettings: () => ({}), sensitiveHeaders: Symbol("nodejs.http2.sensitiveHeaders"),
    constants: { HTTP2_HEADER_STATUS: ":status", HTTP2_HEADER_METHOD: ":method", HTTP2_HEADER_AUTHORITY: ":authority", HTTP2_HEADER_SCHEME: ":scheme", HTTP2_HEADER_PATH: ":path", HTTP2_HEADER_CONTENT_TYPE: "content-type", HTTP2_HEADER_CONTENT_LENGTH: "content-length", NGHTTP2_CANCEL: 8 } };
});
__nodeDefine("tls", (module) => { module.exports = { connect: () => { throw new Error("Odete: tls não existe no iPad"); }, createServer: () => { throw new Error("Odete: tls não existe no iPad"); } }; });
__nodeDefine("dns", (module) => { const lookup = (h, o, cb) => { if (typeof o === "function") cb = o; queueMicrotask(() => cb(null, "127.0.0.1", 4)); }; module.exports = { lookup, promises: { lookup: async () => ({ address: "127.0.0.1", family: 4 }), resolve: async () => ["127.0.0.1"] }, resolve: (h, cb) => cb(null, ["127.0.0.1"]), setDefaultResultOrder() {} }; });
__nodeDefine("crypto", (module, exports, require) => {
  const H = globalThis.__odete;
  const bytesDe = (d, e) => (typeof d === "string" ? Buffer.from(d, e) : d instanceof KeyObject ? d._bytes : ArrayBuffer.isView(d) ? Buffer.from(d.buffer, d.byteOffset, d.byteLength) : d instanceof ArrayBuffer ? Buffer.from(d) : Buffer.from(d));
  // Algoritmo que não existe lança já no createHash, como no Node — antes caía no SHA-256.
  const ALGOS = ["md5", "sha1", "sha256", "sha384", "sha512", "sha3-256", "sha3-384", "sha3-512"];
  const nomeAlgo = (a) => { const n = String(a).toLowerCase().replace(/^rsa-/, ""); return n.startsWith("sha3-") ? n : n.replace("-", ""); };
  const conferir = (a) => { const n = nomeAlgo(a); if (!ALGOS.includes(n)) throw Object.assign(new Error("Digest method not supported"), { code: "ERR_CRYPTO_INVALID_DIGEST" }); return n; };
  const hashObj = (algo) => { const chunks = []; let feito = false; const h = { update(d, e) { chunks.push(bytesDe(d, e)); return h; }, digest(e) { if (feito) throw Object.assign(new Error("Digest already called"), { code: "ERR_CRYPTO_HASH_FINALIZED" }); feito = true; const b = globalThis.__comoBuffer(H.hashBytes(algo, Buffer.concat(chunks))); return e && e !== "buffer" ? b.toString(e) : b; }, copy: () => { const c = hashObj(algo); for (const x of chunks) c.update(x); return c; } }; return h; };
  class KeyObject {
    constructor(tipo, bytes) { this.type = tipo; Object.defineProperty(this, "_bytes", { value: bytes }); }
    get symmetricKeySize() { return this.type === "secret" ? this._bytes.length : undefined; }
    get asymmetricKeyType() { return undefined; }
    export(o) { if (o && o.format === "jwk") return { kty: "oct", k: this._bytes.toString("base64url") }; return Buffer.from(this._bytes); }
    equals(o) { return o instanceof KeyObject && Buffer.compare(this._bytes, o._bytes) === 0; }
    static from(k) { return new KeyObject("secret", Buffer.from(k._bytes || [])); }
  }
  const semAssimetrica = (o) => () => { throw Object.assign(new Error("Odete: " + o + " (chaves RSA/EC) ainda não existe no iPad; use HMAC (HS256) ou a crypto.subtle"), { code: "ERR_FEATURE_UNAVAILABLE_ON_PLATFORM" }); };
  const createHmac = (algo, key, _o) => {
    const n = conferir(algo); const k = bytesDe(key); const chunks = []; let feito = false;
    const h = { update(d, e) { chunks.push(bytesDe(d, e)); return h; }, digest(e) { if (feito) throw Object.assign(new Error("Digest already called"), { code: "ERR_CRYPTO_HASH_FINALIZED" }); feito = true; const b = globalThis.__comoBuffer(H.hmacBytes(n, k, Buffer.concat(chunks))); return e && e !== "buffer" ? b.toString(e) : b; } };
    return h;
  };
  const randomFillSync = (buf, off = 0, size) => {
    const u = buf instanceof ArrayBuffer ? new Uint8Array(buf) : new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
    const fim = size === undefined ? u.length : off + size;
    if (off < 0 || fim > u.length) throw Object.assign(new RangeError('The value of "offset" is out of range'), { code: "ERR_OUT_OF_RANGE" });
    H.randomFill(u.subarray(off, fim));
    return buf;
  };
  const randomInt = (a, b, cb) => {
    if (typeof b === "function" || b === undefined) { cb = b; b = a; a = 0; }
    const faixa = b - a;
    if (!(faixa > 0)) throw Object.assign(new RangeError(`The value of "max" is out of range. It must be greater than the value of "min" (${a}). Received ${b}`), { code: "ERR_OUT_OF_RANGE" });
    // Rejeição para não enviesar: descarta o que cai na sobra do último bloco.
    const limite = Math.floor(0x1000000000000 / faixa) * faixa;
    let x;
    do { const r = H.randomFill(new Uint8Array(6)); x = r[0] * 0x10000000000 + r[1] * 0x100000000 + r[2] * 0x1000000 + r[3] * 0x10000 + r[4] * 0x100 + r[5]; } while (x >= limite);
    const v = a + (x % faixa);
    if (cb) { queueMicrotask(() => cb(null, v)); return; }
    return v;
  };
  const pbkdf2Sync = (senha, sal, iter, tam, digest = "sha1") => globalThis.__comoBuffer(H.pbkdf2Bytes(bytesDe(senha), bytesDe(sal), iter, tam, conferir(digest)));
  const timingSafeEqual = (a, b) => {
    if (a.byteLength !== b.byteLength) throw Object.assign(new RangeError("Input buffers must have the same byte length"), { code: "ERR_CRYPTO_TIMING_SAFE_EQUAL_LENGTH" });
    const x = bytesDe(a), y = bytesDe(b); let d = 0; for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i]; return d === 0;
  };
  module.exports = {
    randomBytes: (n, cb) => { const b = Buffer.alloc(n); H.randomFill(b); if (cb) { queueMicrotask(() => cb(null, b)); return; } return b; },
    pseudoRandomBytes: (n) => { const b = Buffer.alloc(n); H.randomFill(b); return b; },
    randomFillSync, randomFill: (buf, off, size, cb) => { if (typeof off === "function") { cb = off; off = 0; size = undefined; } else if (typeof size === "function") { cb = size; size = undefined; } try { randomFillSync(buf, off, size); queueMicrotask(() => cb(null, buf)); } catch (e) { queueMicrotask(() => cb(e)); } },
    randomUUID: () => globalThis.crypto.randomUUID(), randomInt, getRandomValues: (a) => globalThis.crypto.getRandomValues(a),
    createHash: (algo) => hashObj(conferir(algo)), createHmac, hash: (algo, d, e = "hex") => hashObj(conferir(algo)).update(d).digest(e),
    timingSafeEqual, webcrypto: globalThis.crypto, subtle: globalThis.crypto.subtle,
    getHashes: () => ALGOS.slice(), getCiphers: () => [], getCurves: () => [], constants: {},
    pbkdf2Sync, pbkdf2: (s, sal, it, tam, dg, cb) => { if (typeof dg === "function") { cb = dg; dg = "sha1"; } queueMicrotask(() => { let r; try { r = pbkdf2Sync(s, sal, it, tam, dg); } catch (e) { cb(e); return; } cb(null, r); }); },
    KeyObject, createSecretKey: (k, e) => new KeyObject("secret", Buffer.from(bytesDe(k, e))),
    createPublicKey: semAssimetrica("createPublicKey"), createPrivateKey: semAssimetrica("createPrivateKey"), generateKeyPairSync: semAssimetrica("generateKeyPairSync"), generateKeyPair: semAssimetrica("generateKeyPair"),
    createSign: semAssimetrica("createSign"), createVerify: semAssimetrica("createVerify"), sign: semAssimetrica("sign"), verify: semAssimetrica("verify"), publicEncrypt: semAssimetrica("publicEncrypt"), privateDecrypt: semAssimetrica("privateDecrypt"),
    createCipheriv: () => { throw new Error("Odete: cipher ainda não existe no iPad"); }, createDecipheriv: () => { throw new Error("Odete: decipher ainda não existe no iPad"); },
    scryptSync: () => { throw new Error("Odete: scrypt ainda não existe no iPad"); }, scrypt: () => { throw new Error("Odete: scrypt ainda não existe no iPad"); },
  };
});
__nodeDefine("readline", (module, exports, require) => {
  const EE = require("events");
  // Linhas de um stream (o stdin que veio pelo pipe, um arquivo): 'line', 'close', o
  // iterador assíncrono e `question`, que pega a próxima linha. Sem entrada, `question`
  // responde vazio (o terminal ainda não manda o teclado para o processo).
  class Interface extends EE {
    constructor(opts = {}, output) {
      super();
      if (opts && typeof opts.on === "function" && typeof opts.read === "function") opts = { input: opts, output };
      this.input = opts.input; this.output = opts.output; this.terminal = !!opts.terminal; this.line = ""; this.closed = false;
      this._prompt = opts.prompt ?? "> "; this._linhas = []; this._esperando = []; this._resto = "";
      // Sem pipe o stdin do terminal não traz nada (o teclado ainda não chega ao processo):
      // `question` responde vazio na hora e o laço de linhas termina, como antes.
      this._acabou = !this.input || (this.input.fd === 0 && this.input.isTTY === true);
      if (this.input && !this._acabou) {
        const entrar = (c) => { this._resto += typeof c === "string" ? c : c.toString("utf8"); const partes = this._resto.split(/\r?\n/); this._resto = partes.pop(); for (const l of partes) this._entregar(l); };
        this.input.on("data", entrar);
        this.input.on("end", () => { if (this._resto) { this._entregar(this._resto); this._resto = ""; } this._acabou = true; for (const w of this._esperando.splice(0)) w(null); this.close(); });
      } else queueMicrotask(() => {});
    }
    _entregar(l) { const w = this._esperando.shift(); if (w) w(l); else if (this.listenerCount("line")) this.emit("line", l); else this._linhas.push(l); }
    on(ev, fn) { super.on(ev, fn); if (ev === "line") { const l = this._linhas.splice(0); for (const x of l) this.emit("line", x); } return this; }
    question(q, o, cb) { if (typeof o === "function") cb = o; if (q) globalThis.__odete.writeRaw(1, String(q)); const pega = (l) => cb(l ?? ""); if (this._linhas.length) queueMicrotask(() => pega(this._linhas.shift())); else if (this._acabou) queueMicrotask(() => pega("")); else this._esperando.push(pega); }
    close() { if (this.closed) return; this.closed = true; this.emit("close"); }
    pause() { return this; } resume() { return this; } setPrompt(p) { this._prompt = p; } getPrompt() { return this._prompt; } prompt() { if (this._prompt) globalThis.__odete.writeRaw(1, this._prompt); } write() {} getCursorPos() { return { rows: 0, cols: 0 }; }
    async *[Symbol.asyncIterator]() {
      const fila = this._linhas; let fim = false, acordar = null;
      this.on("line", (l) => { fila.push(l); if (acordar) { acordar(); acordar = null; } });
      this.once("close", () => { fim = true; if (acordar) acordar(); });
      while (true) { if (fila.length) yield fila.shift(); else if (fim || this.closed || this._acabou) return; else await new Promise((r) => { acordar = r; }); }
    }
  }
  const createInterface = (o, out) => new Interface(o, out);
  const promises = { Interface, createInterface: (o) => { const rl = createInterface(o); rl.question = ((q) => (pergunta) => new Promise((res) => Interface.prototype.question.call(rl, pergunta, res)))(); return rl; } };
  module.exports = { Interface, createInterface, clearLine: (s, d, cb) => { if (cb) queueMicrotask(cb); return true; }, clearScreenDown: (s, cb) => { if (cb) queueMicrotask(cb); return true; }, cursorTo: (s, x, y, cb) => { const f = [y, cb].find((v) => typeof v === "function"); if (f) queueMicrotask(f); return true; }, moveCursor: (s, x, y, cb) => { if (cb) queueMicrotask(cb); return true; }, emitKeypressEvents() {}, promises };
});
__nodeDefine("readline/promises", (module, exports, require) => { module.exports = require("readline").promises; });
__nodeDefine("tty", (module) => { module.exports = { isatty: () => false, WriteStream: class {}, ReadStream: class {} }; });
__nodeDefine("worker_threads", (module) => { module.exports = { isMainThread: true, parentPort: null, workerData: null, threadId: 0, Worker: class { constructor() { throw new Error("Odete: worker_threads ainda não existe no iPad"); } } }; });
__nodeDefine("perf_hooks", (module) => { module.exports = { performance: globalThis.performance, PerformanceObserver: class { observe() {} disconnect() {} }, monitorEventLoopDelay: () => ({ enable() {}, disable() {}, mean: 0, percentile: () => 0 }) }; });
__nodeDefine("timers", (module) => { module.exports = { setTimeout, setInterval, setImmediate, clearTimeout, clearInterval, clearImmediate }; });
__nodeDefine("timers/promises", (module) => { module.exports = { setTimeout: (ms, v) => new Promise((r) => setTimeout(() => r(v), ms)), setImmediate: (v) => new Promise((r) => setImmediate(() => r(v))), setInterval: async function* (ms, v) { while (true) { await new Promise((r) => setTimeout(r, ms)); yield v; } }, scheduler: { wait: (ms) => new Promise((r) => setTimeout(r, ms)), yield: () => new Promise((r) => setImmediate(r)) } }; });
__nodeDefine("module", (module, exports, require) => { module.exports = { createRequire: (from) => globalThis.__odete_makeRequire(typeof from === "string" ? from.replace(/^file:\/\//, "") : from.pathname), builtinModules: ["fs", "path", "events", "buffer", "util", "stream", "os", "url", "querystring", "http", "https", "http2", "crypto", "zlib", "assert", "child_process", "net", "dns", "tls", "readline", "tty", "module", "process", "timers", "worker_threads", "perf_hooks", "string_decoder"], isBuiltin: (n) => globalThis.__nodeHas(n), Module: { _extensions: {}, _cache: {}, builtinModules: [] }, register() {}, syncBuiltinESMExports() {}, findSourceMap: () => undefined }; });
__nodeDefine("async_hooks", (module) => { class AsyncLocalStorage { constructor() { this._s = undefined; } run(store, fn, ...a) { const prev = this._s; this._s = store; try { return fn(...a); } finally { this._s = prev; } } getStore() { return this._s; } enterWith(s) { this._s = s; } exit(fn, ...a) { return this.run(undefined, fn, ...a); } disable() {} } module.exports = { AsyncLocalStorage, AsyncResource: class { constructor() {} runInAsyncScope(fn, t, ...a) { return fn.apply(t, a); } emitDestroy() {} bind(fn) { return fn; } static bind(fn) { return fn; } }, createHook: () => ({ enable() {}, disable() {} }), executionAsyncId: () => 1, triggerAsyncId: () => 0 }; });
__nodeDefine("constants", (module, exports, require) => { module.exports = { ...require("fs").constants, ...require("os").constants.signals }; });
__nodeDefine("v8", (module) => { module.exports = { getHeapStatistics: () => ({ total_heap_size: 0, used_heap_size: 0, heap_size_limit: 4e9 }), serialize: (v) => Buffer.from(JSON.stringify(v)), deserialize: (b) => JSON.parse(Buffer.from(b).toString()), setFlagsFromString() {} }; });
__nodeDefine("vm", (module) => { module.exports = { runInThisContext: (code) => (0, eval)(code), runInNewContext: (code, ctx = {}) => new Function(...Object.keys(ctx), code)(...Object.values(ctx)), createContext: (o) => o || {}, Script: class { constructor(code) { this.code = code; } runInThisContext() { return (0, eval)(this.code); } runInNewContext(ctx = {}) { return new Function(...Object.keys(ctx), this.code)(...Object.values(ctx)); } }, isContext: () => true }; });
__nodeDefine("cluster", (module) => { module.exports = { isMaster: true, isPrimary: true, isWorker: false, fork: () => { throw new Error("Odete: cluster não existe no iPad"); }, workers: {}, on() {} }; });
__nodeDefine("inspector", (module) => { module.exports = { open() {}, close() {}, url: () => undefined, Session: class { connect() {} post() {} } }; });
__nodeDefine("diagnostics_channel", (module) => { module.exports = { channel: () => ({ hasSubscribers: false, publish() {}, subscribe() {}, unsubscribe() {} }), hasSubscribers: () => false, subscribe() {}, unsubscribe() {}, tracingChannel: () => ({ traceSync: (fn, c, t, ...a) => fn.apply(t, a), tracePromise: (fn, c, t, ...a) => fn.apply(t, a) }) }; });
__nodeDefine("punycode", (module) => { module.exports = { toASCII: (s) => s, toUnicode: (s) => s, encode: (s) => s, decode: (s) => s }; });
__nodeDefine("sys", (module, exports, require) => { module.exports = require("util"); });
__nodeDefine("util/types", (module, exports, require) => { module.exports = require("util").types; });
__nodeDefine("path/posix", (module, exports, require) => { module.exports = require("path"); });
__nodeDefine("fs/promises", (module, exports, require) => { module.exports = require("fs").promises; });
__nodeDefine("events/once", (module, exports, require) => { module.exports = require("events").once; });
