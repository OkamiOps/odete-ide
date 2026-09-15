// Globals base. `__odete` é o objeto host (Swift).
(function () {
  const H = globalThis.__odete;
  const mods = Object.create(null);      // nome → factory(module, exports, require)
  const cache = Object.create(null);     // nome → exports
  globalThis.__nodeDefine = (name, factory) => { mods[name] = factory; };
  globalThis.__nodeRequire = (name) => {
    const n = name.startsWith("node:") ? name.slice(5) : name;
    if (cache[n]) return cache[n];
    const f = mods[n];
    if (!f) throw Object.assign(new Error(`Cannot find module '${name}'`), { code: "MODULE_NOT_FOUND" });
    const module = { exports: {} };
    cache[n] = module.exports;
    f(module, module.exports, globalThis.__nodeRequire);
    cache[n] = module.exports;
    return module.exports;
  };
  globalThis.__nodeHas = (name) => !!mods[name.startsWith("node:") ? name.slice(5) : name];

  // --- timers ---
  const timers = new Map();
  function makeTimer(fn, ms, args, repeats) {
    const id = H.setTimer(Number(ms) || 0, repeats);
    timers.set(id, { fn, args, repeats });
    const t = { id, ref() { return t; }, unref() { return t; }, hasRef() { return true; }, refresh() { return t; }, [Symbol.toPrimitive]() { return id; } };
    return t;
  }
  globalThis.__odete_fireTimer = (id) => {
    const t = timers.get(id);
    if (!t) return;
    if (!t.repeats) timers.delete(id);
    try { t.fn(...t.args); } catch (e) { reportUncaught(e); }
  };
  globalThis.setTimeout = (fn, ms, ...args) => makeTimer(fn, ms, args, false);
  globalThis.setInterval = (fn, ms, ...args) => makeTimer(fn, ms, args, true);
  globalThis.setImmediate = (fn, ...args) => makeTimer(fn, 0, args, false);
  const clear = (t) => { if (t == null) return; const id = typeof t === "object" ? t.id : t; if (timers.delete(id)) H.clearTimer(id); };
  globalThis.clearTimeout = clear; globalThis.clearInterval = clear; globalThis.clearImmediate = clear;
  globalThis.queueMicrotask = globalThis.queueMicrotask || ((fn) => Promise.resolve().then(fn));

  function reportUncaught(e) {
    const p = globalThis.process;
    if (p && p.listenerCount && p.listenerCount("uncaughtException") > 0) { p.emit("uncaughtException", e); return; }
    H.write(2, globalThis.__formatError(e));
    H.exit(1);
  }
  globalThis.__odete_reportUncaught = reportUncaught;
  globalThis.__formatError = (e) => {
    if (!(e instanceof Error)) return "Uncaught " + String(e);
    const head = (e.name || "Error") + ": " + e.message;
    const stack = e.stack ? String(e.stack).split("\n").filter(Boolean).map((l) => "    at " + l).join("\n") : "";
    return head + (stack ? "\n" + stack : "");
  };

  // --- console ---
  const inspect = (v, depth) => globalThis.__nodeRequire("util").inspect(v, { depth: depth ?? 2, colors: false });
  const fmt = (args) => globalThis.__nodeRequire("util").format(...args);
  const counts = new Map(), times = new Map();
  let indent = "";
  const out = (fd) => (...a) => H.write(fd, indent + fmt(a).split("\n").join("\n" + indent));
  globalThis.console = {
    log: out(1), info: out(1), debug: out(1), warn: out(2), error: out(2), trace: (...a) => H.write(2, "Trace: " + fmt(a) + "\n" + new Error().stack),
    dir: (v, o) => H.write(1, inspect(v, o && o.depth)),
    table: (v) => H.write(1, inspect(v)),
    assert: (c, ...a) => { if (!c) H.write(2, "Assertion failed" + (a.length ? ": " + fmt(a) : "")); },
    count: (l = "default") => { const n = (counts.get(l) || 0) + 1; counts.set(l, n); H.write(1, `${l}: ${n}`); },
    countReset: (l = "default") => counts.delete(l),
    time: (l = "default") => times.set(l, H.perfNow()),
    timeEnd: (l = "default") => { const t = times.get(l); if (t != null) { H.write(1, `${l}: ${(H.perfNow() - t).toFixed(3)}ms`); times.delete(l); } },
    timeLog: (l = "default") => { const t = times.get(l); if (t != null) H.write(1, `${l}: ${(H.perfNow() - t).toFixed(3)}ms`); },
    group: (...a) => { if (a.length) H.write(1, fmt(a)); indent += "  "; }, groupEnd: () => { indent = indent.slice(0, -2); },
    clear: () => {},
  };

  // --- encoding ---
  function utf8Encode(str) {
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
  }
  function toU8(v) {
    if (v instanceof Uint8Array) return v;
    if (v instanceof ArrayBuffer) return new Uint8Array(v);
    if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength); // DataView, outras typed arrays
    if (v && v.buffer instanceof ArrayBuffer) return new Uint8Array(v.buffer);
    return new Uint8Array(0);
  }
  function utf8Decode(bytes) {
    const b = toU8(bytes);
    let s = "", i = 0;
    const n = b.length;
    while (i < n) {
      const c = b[i++];
      if (c < 0x80) { s += String.fromCharCode(c); continue; }
      if (c < 0xc2) { s += "\ufffd"; continue; }
      if (c < 0xe0) { if (i >= n) { s += "\ufffd"; break; } s += String.fromCharCode(((c & 31) << 6) | (b[i++] & 63)); continue; }
      if (c < 0xf0) { if (i + 1 >= n) { s += "\ufffd"; break; } s += String.fromCharCode(((c & 15) << 12) | ((b[i++] & 63) << 6) | (b[i++] & 63)); continue; }
      if (i + 2 >= n) { s += "\ufffd"; break; }
      const cp = ((c & 7) << 18) | ((b[i++] & 63) << 12) | ((b[i++] & 63) << 6) | (b[i++] & 63);
      s += cp > 0x10ffff ? "\ufffd" : String.fromCodePoint(cp);
    }
    return s;
  }
  globalThis.__utf8 = { encode: utf8Encode, decode: utf8Decode };
  globalThis.TextEncoder = class TextEncoder { get encoding() { return "utf-8"; } encode(s = "") { return utf8Encode(String(s)); } encodeInto(s, dst) { const b = utf8Encode(s); dst.set(b.subarray(0, dst.length)); return { read: s.length, written: Math.min(b.length, dst.length) }; } };
  globalThis.TextDecoder = class TextDecoder { constructor(enc = "utf-8", opts = {}) { this.encoding = String(enc).toLowerCase(); this.fatal = !!opts.fatal; this.ignoreBOM = !!opts.ignoreBOM; } decode(b) { if (!b) return ""; const u = toU8(b); if (this.encoding === "utf-16le" || this.encoding === "utf-16") { let s = ""; for (let i = 0; i + 1 < u.length; i += 2) s += String.fromCharCode(u[i] | (u[i + 1] << 8)); return s; } if (this.encoding === "latin1" || this.encoding === "iso-8859-1" || this.encoding === "ascii") { let s = ""; for (const x of u) s += String.fromCharCode(x); return s; } const t = utf8Decode(u); return !this.ignoreBOM && t.charCodeAt(0) === 0xfeff ? t.slice(1) : t; } };

  const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  function b64encBytes(bytes) {
    let s = "";
    for (let i = 0; i < bytes.length; i += 3) {
      const a = bytes[i], b = bytes[i + 1], c = bytes[i + 2];
      s += B64[a >> 2] + B64[((a & 3) << 4) | (b >> 4)] + (b === undefined ? "=" : B64[((b & 15) << 2) | (c >> 6)]) + (c === undefined ? "=" : B64[c & 63]);
    }
    return s;
  }
  function b64decBytes(str) {
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
  globalThis.__b64 = { enc: b64encBytes, dec: b64decBytes };
  globalThis.btoa = (s) => b64encBytes(Uint8Array.from(String(s), (c) => c.charCodeAt(0) & 255));
  globalThis.atob = (s) => Array.from(b64decBytes(s), (b) => String.fromCharCode(b)).join("");


  // --- URL / URLSearchParams (o JSC não traz) ---
  if (typeof globalThis.URL !== "function") {
    class URLSearchParams {
      constructor(init) { this._l = []; this._url = null; if (init == null) return; if (typeof init === "string") { for (const part of init.replace(/^\?/, "").split("&")) { if (!part) continue; const i = part.indexOf("="); const k = i < 0 ? part : part.slice(0, i); const v = i < 0 ? "" : part.slice(i + 1); this._l.push([dec(k), dec(v)]); } } else if (init instanceof URLSearchParams) this._l = init._l.map((x) => [...x]); else if (Array.isArray(init)) this._l = init.map(([k, v]) => [String(k), String(v)]); else if (typeof init === "object") this._l = Object.entries(init).map(([k, v]) => [k, String(v)]); }
      _up() { if (this._url) this._url._search = this._l.length ? "?" + this.toString() : ""; }
      append(k, v) { this._l.push([String(k), String(v)]); this._up(); } delete(k, v) { this._l = this._l.filter(([a, b]) => !(a === String(k) && (v === undefined || b === String(v)))); this._up(); }
      get(k) { const e = this._l.find(([a]) => a === String(k)); return e ? e[1] : null; } getAll(k) { return this._l.filter(([a]) => a === String(k)).map(([, b]) => b); } has(k, v) { return this._l.some(([a, b]) => a === String(k) && (v === undefined || b === String(v))); }
      set(k, v) { const i = this._l.findIndex(([a]) => a === String(k)); if (i < 0) this._l.push([String(k), String(v)]); else { this._l[i][1] = String(v); this._l = this._l.filter(([a], j) => a !== String(k) || j === i); } this._up(); }
      sort() { this._l.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)); this._up(); } forEach(fn, t) { for (const [k, v] of this._l) fn.call(t, v, k, this); }
      keys() { return this._l.map((x) => x[0])[Symbol.iterator](); } values() { return this._l.map((x) => x[1])[Symbol.iterator](); } entries() { return this._l.map((x) => [...x])[Symbol.iterator](); } [Symbol.iterator]() { return this.entries(); }
      get size() { return this._l.length; } toString() { return this._l.map(([k, v]) => enc(k) + "=" + enc(v)).join("&"); }
    }
    const enc = (s) => encodeURIComponent(s).replace(/%20/g, "+").replace(/[!'()~]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
    const dec = (s) => { try { return decodeURIComponent(String(s).replace(/\+/g, " ")); } catch { return String(s); } };
    const SPECIAL = { "http:": "80", "https:": "443", "ws:": "80", "wss:": "443", "ftp:": "21", "file:": "" };
    const RE = /^([a-zA-Z][a-zA-Z0-9+.-]*:)?(?:\/\/(?:([^:@\/?#]*)(?::([^@\/?#]*))?@)?(\[[^\]]*\]|[^:\/?#]*)(?::(\d*))?)?([^?#]*)(\?[^#]*)?(#.*)?$/;
    function normPath(p, special) { if (!special) return p; const out = []; for (const seg of p.split("/")) { if (seg === "..") { if (out.length > 1) out.pop(); } else if (seg !== ".") out.push(seg); } let r = out.join("/"); if (p.endsWith("/..") || p.endsWith("/.")) r += "/"; return r.startsWith("/") ? r : "/" + r; }
    class URL {
      constructor(input, base) {
        input = String(input).trim();
        let m = RE.exec(input);
        if (!m) throw new TypeError("Invalid URL: " + input);
        let [, protocol, user, pass, host, port, path, search, hash] = m;
        if (!protocol) {
          if (base === undefined) throw new TypeError("Invalid URL: " + input);
          const b = base instanceof URL ? base : new URL(String(base));
          protocol = b.protocol;
          if (m[4] === undefined) { user = b.username; pass = b.password; host = b.hostname; port = b.port; if (!path) { path = b.pathname; if (search === undefined) search = b.search; } else if (!path.startsWith("/")) { path = b.pathname.replace(/[^/]*$/, "") + path; } }
        }
        protocol = protocol.toLowerCase();
        const special = protocol in SPECIAL;
        this._protocol = protocol; this._username = user ? user : ""; this._password = pass ? pass : "";
        this._hostname = special ? (host || "").toLowerCase() : host || "";
        this._port = port && port !== SPECIAL[protocol] ? port : "";
        this._pathname = special ? normPath(path || "/", true) : path || "";
        this._search = search && search !== "?" ? search : ""; this._hash = hash && hash !== "#" ? hash : "";
        this._special = special;
        this._params = new URLSearchParams(this._search); this._params._url = this;
        if (special && !this._hostname && protocol !== "file:") throw new TypeError("Invalid URL: " + input);
      }
      get protocol() { return this._protocol; } set protocol(v) { this._protocol = String(v).replace(/:?$/, ":").toLowerCase(); }
      get username() { return this._username; } set username(v) { this._username = String(v); } get password() { return this._password; } set password(v) { this._password = String(v); }
      get hostname() { return this._hostname; } set hostname(v) { this._hostname = String(v).toLowerCase(); } get port() { return this._port; } set port(v) { v = String(v); this._port = v === SPECIAL[this._protocol] ? "" : v; }
      get host() { return this._hostname + (this._port ? ":" + this._port : ""); } set host(v) { const [h, p] = String(v).split(":"); this.hostname = h; this.port = p || ""; }
      get pathname() { return this._pathname; } set pathname(v) { v = String(v); this._pathname = this._special ? normPath(v.startsWith("/") ? v : "/" + v, true) : v; }
      get search() { return this._search; } set search(v) { v = String(v); this._search = v && v !== "?" ? (v.startsWith("?") ? v : "?" + v) : ""; this._params = new URLSearchParams(this._search); this._params._url = this; }
      get searchParams() { return this._params; } get hash() { return this._hash; } set hash(v) { v = String(v); this._hash = v && v !== "#" ? (v.startsWith("#") ? v : "#" + v) : ""; }
      get origin() { return this._special && this._protocol !== "file:" ? this._protocol + "//" + this.host : "null"; }
      get href() { const auth = this._username ? this._username + (this._password ? ":" + this._password : "") + "@" : ""; const slashes = this._special || this._hostname ? "//" : ""; return this._protocol + slashes + auth + this.host + this._pathname + this._search + this._hash; }
      set href(v) { const u = new URL(v); Object.assign(this, { _protocol: u._protocol, _username: u._username, _password: u._password, _hostname: u._hostname, _port: u._port, _pathname: u._pathname, _search: u._search, _hash: u._hash, _special: u._special }); this._params = new URLSearchParams(this._search); this._params._url = this; }
      toString() { return this.href; } toJSON() { return this.href; }
      static canParse(u, b) { try { new URL(u, b); return true; } catch { return false; } } static parse(u, b) { try { return new URL(u, b); } catch { return null; } }
      static createObjectURL() { return "blob:odete/" + Math.random().toString(36).slice(2); } static revokeObjectURL() {}
      [Symbol.for("nodejs.util.inspect.custom")]() { return `URL { href: '${this.href}' }`; }
    }
    globalThis.URL = URL; globalThis.URLSearchParams = URLSearchParams;
  }

  // --- WebAssembly: o JSC do sistema não resolve as promessas do instantiate async; fazemos síncrono ---
  if (typeof WebAssembly === "object") {
    const toBytes = (src) => (src instanceof ArrayBuffer ? new Uint8Array(src) : ArrayBuffer.isView(src) ? new Uint8Array(src.buffer, src.byteOffset, src.byteLength) : src);
    WebAssembly.compile = (src) => new Promise((res, rej) => { try { res(new WebAssembly.Module(toBytes(src))); } catch (e) { rej(e); } });
    WebAssembly.instantiate = (src, imports = {}) => new Promise((res, rej) => { try {
      if (src instanceof WebAssembly.Module) res(new WebAssembly.Instance(src, imports));
      else { const m = new WebAssembly.Module(toBytes(src)); res({ module: m, instance: new WebAssembly.Instance(m, imports) }); }
    } catch (e) { rej(e); } });
    WebAssembly.compileStreaming = async (resp) => WebAssembly.compile(await (await resp).arrayBuffer());
    WebAssembly.instantiateStreaming = async (resp, imports) => WebAssembly.instantiate(await (await resp).arrayBuffer(), imports);
  }

  // --- ponte de chamadas assíncronas vindas do Swift ---
  globalThis.__odete_callAsync = (id, fn, argsJSON) => {
    Promise.resolve().then(() => {
      const f = typeof fn === "function" ? fn : globalThis[fn];
      if (typeof f !== "function") throw new Error("função não encontrada: " + fn);
      return f(...JSON.parse(argsJSON));
    }).then((v) => H.asyncDone(id, true, JSON.stringify(v === undefined ? null : v)), (e) => H.asyncDone(id, false, globalThis.__formatError ? globalThis.__formatError(e) : String(e)));
  };

  // --- crypto (subset) ---
  globalThis.crypto = globalThis.crypto || {};
  globalThis.crypto.getRandomValues = (arr) => { const bytes = H.randomBytes(arr.byteLength); const u8 = new Uint8Array(arr.buffer, arr.byteOffset, arr.byteLength); for (let i = 0; i < u8.length; i++) u8[i] = bytes[i]; return arr; };
  globalThis.crypto.randomUUID = () => { const b = H.randomBytes(16); b[6] = (b[6] & 15) | 64; b[8] = (b[8] & 63) | 128; const h = b.map((x) => x.toString(16).padStart(2, "0")).join(""); return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`; };
  globalThis.crypto.subtle = { async digest(algo, data) { const name = String(algo && algo.name || algo).replace("-", "").toLowerCase(); const u8 = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength); const hex = H.hash(name, b64encBytes(u8)); const out = new Uint8Array(hex.length / 2); for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16); return out.buffer; } };

  globalThis.performance = globalThis.performance || { now: () => H.perfNow(), timeOrigin: H.now(), mark() {}, measure() {} };
  globalThis.structuredClone = globalThis.structuredClone || ((v) => JSON.parse(JSON.stringify(v)));
  globalThis.global = globalThis;
  globalThis.self = globalThis;

  // AbortController
  if (!globalThis.AbortController) {
    class AbortSignal { constructor() { this.aborted = false; this.reason = undefined; this._l = []; this.onabort = null; } addEventListener(t, f) { if (t === "abort") this._l.push(f); } removeEventListener(t, f) { this._l = this._l.filter((x) => x !== f); } throwIfAborted() { if (this.aborted) throw this.reason; } static timeout(ms) { const c = new AbortController(); setTimeout(() => c.abort(new Error("TimeoutError")), ms); return c.signal; } }
    globalThis.AbortSignal = AbortSignal;
    globalThis.AbortController = class AbortController { constructor() { this.signal = new AbortSignal(); } abort(reason) { if (this.signal.aborted) return; this.signal.aborted = true; this.signal.reason = reason || new Error("AbortError"); const ev = { type: "abort", target: this.signal }; if (this.signal.onabort) this.signal.onabort(ev); this.signal._l.forEach((f) => f(ev)); } };
  }
  if (!globalThis.Event) { globalThis.Event = class Event { constructor(type, init = {}) { this.type = type; Object.assign(this, init); } }; }
  if (!globalThis.EventTarget) {
    globalThis.EventTarget = class EventTarget { constructor() { this._m = new Map(); } addEventListener(t, f) { (this._m.get(t) || this._m.set(t, []).get(t)).push(f); } removeEventListener(t, f) { const a = this._m.get(t); if (a) this._m.set(t, a.filter((x) => x !== f)); } dispatchEvent(e) { (this._m.get(e.type) || []).forEach((f) => f.call(this, e)); return true; } };
  }
})();
