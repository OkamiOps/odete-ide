// fetch (host), require de arquivos e o main.
(function () {
  const H = globalThis.__odete, path = __nodeRequire("path"), fs = __nodeRequire("fs");
  __nodeRequire("process");
  __nodeRequire("buffer");

  // ---- fetch ----
  const pendingFetch = new Map(); let fetchSeq = 1;
  class Headers { constructor(init) { this._m = new Map(); if (init instanceof Headers) init.forEach((v, k) => this.append(k, v)); else if (Array.isArray(init)) init.forEach(([k, v]) => this.append(k, v)); else if (init) for (const k of Object.keys(init)) this.append(k, init[k]); } append(k, v) { k = String(k).toLowerCase(); const cur = this._m.get(k); this._m.set(k, cur ? cur + ", " + v : String(v)); } set(k, v) { this._m.set(String(k).toLowerCase(), String(v)); } get(k) { return this._m.get(String(k).toLowerCase()) ?? null; } has(k) { return this._m.has(String(k).toLowerCase()); } delete(k) { this._m.delete(String(k).toLowerCase()); } forEach(fn) { this._m.forEach((v, k) => fn(v, k, this)); } entries() { return this._m.entries(); } keys() { return this._m.keys(); } values() { return this._m.values(); } [Symbol.iterator]() { return this._m.entries(); } getSetCookie() { const c = this.get("set-cookie"); return c ? [c] : []; } }
  class Body { constructor(body) { this._body = body == null ? null : body; this.bodyUsed = false; } _bytes() { this.bodyUsed = true; const b = this._body; if (b == null) return new Uint8Array(0); if (typeof b === "string") return globalThis.__utf8.encode(b); if (b instanceof ArrayBuffer) return new Uint8Array(b); if (ArrayBuffer.isView(b)) return new Uint8Array(b.buffer, b.byteOffset, b.byteLength); if (b instanceof URLSearchParams) return globalThis.__utf8.encode(b.toString()); if (b instanceof Blob) return b._bytes(); if (typeof b === "object" && typeof b.pipe === "function") { throw new TypeError("stream body não suportado ainda"); } return globalThis.__utf8.encode(String(b)); } async arrayBuffer() { const b = this._bytes(); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); } async bytes() { return this._bytes(); } async text() { return globalThis.__utf8.decode(this._bytes()); } async json() { return JSON.parse(await this.text()); } async blob() { return new Blob([this._bytes()]); } async formData() { const fd = new FormData(); new URLSearchParams(await this.text()).forEach((v, k) => fd.append(k, v)); return fd; } get body() { const b = this._bytes(); return { getReader: () => { let done = false; return { read: async () => done ? { done: true, value: undefined } : (done = true, { done: false, value: b }), releaseLock() {}, cancel: async () => {} }; }, [Symbol.asyncIterator]: async function* () { yield b; }, cancel: async () => {}, locked: false, pipeTo: async (w) => { await w.write(b); await w.close(); } }; } }
  class Blob { constructor(parts = [], opts = {}) { this._parts = parts.map((p) => (typeof p === "string" ? globalThis.__utf8.encode(p) : p instanceof Blob ? p._bytes() : p instanceof ArrayBuffer ? new Uint8Array(p) : new Uint8Array(p.buffer, p.byteOffset, p.byteLength))); this.type = opts.type || ""; } get size() { return this._parts.reduce((a, p) => a + p.length, 0); } _bytes() { const out = new Uint8Array(this.size); let o = 0; for (const p of this._parts) { out.set(p, o); o += p.length; } return out; } async arrayBuffer() { return this._bytes().buffer; } async text() { return globalThis.__utf8.decode(this._bytes()); } async bytes() { return this._bytes(); } slice(s, e, t) { return new Blob([this._bytes().subarray(s, e)], { type: t }); } stream() { return new Response(this._bytes()).body; } }
  class File extends Blob { constructor(parts, name, opts = {}) { super(parts, opts); this.name = name; this.lastModified = opts.lastModified || Date.now(); } }
  class FormData { constructor() { this._e = []; } append(k, v, f) { this._e.push([k, v instanceof Blob && f ? new File([v], f) : v]); } set(k, v) { this.delete(k); this.append(k, v); } get(k) { const e = this._e.find((x) => x[0] === k); return e ? e[1] : null; } getAll(k) { return this._e.filter((x) => x[0] === k).map((x) => x[1]); } has(k) { return this._e.some((x) => x[0] === k); } delete(k) { this._e = this._e.filter((x) => x[0] !== k); } forEach(fn) { this._e.forEach(([k, v]) => fn(v, k, this)); } entries() { return this._e[Symbol.iterator](); } keys() { return this._e.map((x) => x[0])[Symbol.iterator](); } values() { return this._e.map((x) => x[1])[Symbol.iterator](); } [Symbol.iterator]() { return this.entries(); } }
  class Request extends Body { constructor(input, init = {}) { const isReq = input instanceof Request; super(init.body ?? (isReq ? input._body : null)); this.url = isReq ? input.url : String(input instanceof URL ? input.href : input); this.method = (init.method || (isReq ? input.method : "GET")).toUpperCase(); this.headers = new Headers(init.headers || (isReq ? input.headers : undefined)); this.signal = init.signal || (isReq ? input.signal : null) || new AbortController().signal; this.redirect = init.redirect || "follow"; this.cache = init.cache || "default"; this.credentials = init.credentials || "same-origin"; this.mode = init.mode || "cors"; this.referrer = ""; this.integrity = ""; this.keepalive = false; this.duplex = init.duplex; } clone() { return new Request(this, {}); } }
  class Response extends Body { constructor(body, init = {}) { super(body); this.status = init.status ?? 200; this.statusText = init.statusText ?? ""; this.headers = new Headers(init.headers); this.ok = this.status >= 200 && this.status < 300; this.url = init.url || ""; this.redirected = false; this.type = "default"; if (typeof body === "string" && !this.headers.has("content-type")) this.headers.set("content-type", "text/plain;charset=UTF-8"); } clone() { return new Response(this._body, { status: this.status, statusText: this.statusText, headers: this.headers, url: this.url }); } static json(v, init = {}) { return new Response(JSON.stringify(v), { ...init, headers: { "content-type": "application/json", ...(init.headers || {}) } }); } static error() { const r = new Response(null, { status: 0 }); r.type = "error"; return r; } static redirect(url, status = 302) { return new Response(null, { status, headers: { location: String(url) } }); } }
  Object.assign(globalThis, { Headers, Request, Response, Blob, File, FormData });
  globalThis.fetch = (input, init = {}) => new Promise((resolve, reject) => {
    const req = new Request(input, init);
    let url = req.url;
    if (url.startsWith("/")) url = "http://localhost" + url;
    if (url.startsWith("file:")) { try { const p = decodeURIComponent(url.replace(/^file:\/\//, "")); resolve(new Response(fs.readFileSync(p), { status: 200, url })); } catch (e) { reject(new TypeError("fetch failed: " + e.message)); } return; }
    const id = fetchSeq++;
    const headers = {}; req.headers.forEach((v, k) => { headers[k] = v; });
    let body = null;
    if (req._body != null) { body = req._bytes(); if (!headers["content-type"]) { if (typeof req._body === "string") headers["content-type"] = "text/plain;charset=UTF-8"; else if (req._body instanceof URLSearchParams) headers["content-type"] = "application/x-www-form-urlencoded;charset=UTF-8"; } }
    pendingFetch.set(id, { resolve, reject, url, redirect: req.redirect });
    if (req.signal) req.signal.addEventListener("abort", () => { if (pendingFetch.delete(id)) reject(Object.assign(new Error("The operation was aborted"), { name: "AbortError" })); });
    H.fetch(id, url, req.method, headers, body);
  });
  // O corpo chega como Uint8Array (string base64 no formato antigo ainda vale).
  globalThis.__odete_fetchDone = (id, status, headers, body, url) => { const p = pendingFetch.get(id); if (!p) return; pendingFetch.delete(id); const r = new Response(typeof body === "string" ? globalThis.__b64.dec(body) : body, { status, statusText: "", headers, url }); r.redirected = url !== p.url; p.resolve(r); };
  globalThis.__odete_fetchFail = (id, msg) => { const p = pendingFetch.get(id); if (!p) return; pendingFetch.delete(id); p.reject(Object.assign(new TypeError("fetch failed: " + msg), { cause: new Error(msg) })); };

  // ---- require de arquivos ----
  const fileCache = Object.create(null);
  function makeRequire(fromFile) {
    const fromDir = path.dirname(fromFile);
    function require(spec) {
      if (globalThis.__nodeHas(spec) && !spec.startsWith("./") && !spec.startsWith("../") && !spec.startsWith("/")) return globalThis.__nodeRequire(spec);
      const r = H.resolve(spec, fromFile);
      if (r && typeof r === "object") { const e = new Error(r.message); e.code = r.error; e.requireStack = [fromFile]; throw e; }
      if (r.startsWith("node:")) return globalThis.__nodeRequire(r);
      return loadFile(r);
    }
    require.resolve = (spec, o) => { if (globalThis.__nodeHas(spec)) return spec; const r = H.resolve(spec, fromFile); if (r && typeof r === "object") { const e = new Error(r.message); e.code = r.error; throw e; } return r; };
    require.resolve.paths = () => [path.join(fromDir, "node_modules")];
    require.cache = fileCache;
    require.main = mainModule;
    require.extensions = {};
    return require;
  }
  globalThis.__odete_makeRequire = makeRequire;
  let mainModule = null;
  globalThis.require = makeRequire(path.join(H.cwd, "__global__.js"));
  function loadFile(file) {
    if (fileCache[file]) return fileCache[file].exports;
    const module = { id: file, filename: file, path: path.dirname(file), exports: {}, loaded: false, children: [], paths: [], parent: null };
    fileCache[file] = module;
    if (file.endsWith(".json")) { module.exports = JSON.parse(fs.readFileSync(file, "utf8")); module.loaded = true; return module.exports; }
    if (file.endsWith(".node")) { throw Object.assign(new Error(`Odete: ${path.basename(file)} é um binário nativo e não roda no iPad`), { code: "ERR_DLOPEN_FAILED" }); }
    const src = H.loadModule(file);
    if (src && typeof src === "object") { delete fileCache[file]; const e = new Error(src.message || src.error); e.code = src.error; throw e; }
    const wrapper = `(function (exports, require, module, __filename, __dirname) {${src.startsWith("#!") ? "//" + src : src}\n})`;
    let fn;
    try { fn = (0, eval)(wrapper + "\n//# sourceURL=" + file); } catch (e) { delete fileCache[file]; e.message = file + ": " + e.message; throw e; }
    const req = makeRequire(file);
    try { fn.call(module.exports, module.exports, req, module, file, path.dirname(file)); } catch (e) { delete fileCache[file]; throw e; }
    module.loaded = true;
    return module.exports;
  }
  globalThis.__odete_loadFile = loadFile;

  function runGuard(fn) {
    try { fn(); } catch (e) { if (e && e.__odeteExit) return; globalThis.__odete_reportUncaught(e); }
  }
  globalThis.__odete_runMain = (file) => runGuard(() => {
    const abs = path.isAbsolute(file) ? file : path.join(process.cwd(), file);
    const resolved = H.resolve(abs, abs);
    if (resolved && typeof resolved === "object") { H.write(2, `Error: Cannot find module '${file}'`); H.exit(1); return; }
    mainModule = { filename: resolved };
    process.argv[1] = resolved;
    loadFile(resolved);
  });
  globalThis.__odete_runCode = (code, filename) => runGuard(() => {
    const module = { id: "[eval]", filename, exports: {}, loaded: false };
    const fn = (0, eval)(`(function (exports, require, module, __filename, __dirname) {${code}\n})\n//# sourceURL=${filename}`);
    fn.call(module.exports, module.exports, makeRequire(filename), module, filename, path.dirname(filename));
  });

  // rejeições não tratadas
  const unhandled = new Set();
  globalThis.__odete_unhandled = (reason) => { queueMicrotask(() => { if (process.listenerCount("unhandledRejection")) process.emit("unhandledRejection", reason); else globalThis.__odete_reportUncaught(reason); }); };
})();
