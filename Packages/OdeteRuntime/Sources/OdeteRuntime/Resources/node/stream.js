__nodeDefine("stream", (module, exports, require) => {
  // Funções construtoras, como no Node: o readable-stream (e quem herda à moda antiga, com
  // `util.inherits`) chama `Stream.call(this)` e `Readable.call(this, opts)`, que com
  // `class` dava "Cannot call a class constructor". `class X extends Readable` continua
  // valendo. `_readableState`/`_writableState` existem com os campos que os pacotes mais
  // olham (ended, flowing, objectMode, length, finished…), lidos do estado de verdade.
  const EE = require("events");
  const herdar = (Filho, Pai) => { Object.setPrototypeOf(Filho.prototype, Pai.prototype); Object.setPrototypeOf(Filho, Pai); };

  function Stream(opts) { EE.call(this, opts); }
  herdar(Stream, EE);
  Stream.prototype.pipe = function (dest, opts) {
    const src = this;
    src.on("data", (c) => { if (dest.write(c) === false && src.pause) src.pause(); });
    dest.on("drain", () => src.resume && src.resume());
    if (!opts || opts.end !== false) src.on("end", () => dest.end && dest.end());
    src.on("error", (e) => { if (dest.listenerCount("error") > 0) dest.emit("error", e); });
    if (dest.emit) dest.emit("pipe", src);
    return dest;
  };

  function estadoLeitura(s) {
    return {
      get objectMode() { return s._objectMode; }, get highWaterMark() { return s.readableHighWaterMark; },
      get ended() { return s._ended; }, get endEmitted() { return s.readableEnded; }, get flowing() { return s._flowing; },
      get length() { return s._buf.reduce((a, c) => a + (s._objectMode ? 1 : c.length || 0), 0); }, get buffer() { return s._buf; },
      get destroyed() { return s.destroyed; }, get reading() { return s._reading; }, get errored() { return s._erro || null; },
      get closed() { return s._fechado; }, get encoding() { return s._encoding; }, get pipes() { return []; }, set flowing(v) { s._flowing = v; },
      sync: false, needReadable: false, emittedReadable: false, readableListening: false, resumeScheduled: false, errorEmitted: false, autoDestroy: true, defaultEncoding: "utf8", decoder: null,
    };
  }
  function estadoEscrita(s) {
    return {
      get objectMode() { return s._objectMode; }, get highWaterMark() { return s.writableHighWaterMark; },
      get ended() { return s.writableEnded; }, get ending() { return s.writableEnded; }, get finished() { return s.writableFinished; },
      get length() { return s._pending; }, get destroyed() { return s.destroyed; }, get errored() { return s._erro || null; },
      get closed() { return s._fechado; }, get corked() { return s._corked; }, get needDrain() { return s._pending >= 16; },
      errorEmitted: false, autoDestroy: true, defaultEncoding: "utf8", decodeStrings: true, getBuffer() { return []; },
    };
  }

  function Readable(opts) {
    if (!(this instanceof Readable)) return new Readable(opts);
    opts = opts || {};
    Stream.call(this, opts);
    this._buf = []; this._ended = false; this._flowing = null; this._reading = false; this._fechado = false;
    this._objectMode = !!(opts.objectMode || opts.readableObjectMode); this._encoding = opts.encoding || null;
    this.readable = true; this.readableEnded = false; this.destroyed = false;
    if (opts.read) this._read = opts.read;
    if (opts.destroy) this._destroy = opts.destroy;
    if (opts.construct) this._construct = opts.construct;
    this.readableHighWaterMark = opts.highWaterMark || opts.readableHighWaterMark || (this._objectMode ? 16 : 16384);
    this.readableObjectMode = this._objectMode;
    if (!this._readableState) this._readableState = estadoLeitura(this);
    if (opts.signal) opts.signal.addEventListener("abort", () => this.destroy(Object.assign(new Error("The operation was aborted"), { name: "AbortError" })));
  }
  herdar(Readable, Stream);
  const R = Readable.prototype;
  R._read = function () {};
  R._lerMais = function () { if (this._reading || this._ended || this.destroyed) return; this._reading = true; try { this._read(this.readableHighWaterMark); } catch (e) { this.destroy(e); } finally { this._reading = false; } };
  R.push = function (chunk, enc) {
    if (chunk === null) { this._ended = true; this._escoar(); return false; }
    if (typeof chunk === "string" && !this._objectMode) chunk = Buffer.from(chunk, enc);
    this._buf.push(chunk); this._escoar();
    return this._buf.length < 16;
  };
  R.unshift = function (chunk) { this._buf.unshift(chunk); };
  R._escoar = function () {
    if (this._flowing === false) { if (this.listenerCount("readable")) queueMicrotask(() => { if (this._buf.length || this._ended) this.emit("readable"); }); return; }
    if (this._flowing === null && this.listenerCount("data") === 0 && this.listenerCount("readable") === 0) return;
    if (this._agendado) return;
    this._agendado = true;
    queueMicrotask(() => {
      this._agendado = false;
      while (this._buf.length && this._flowing !== false && !this.destroyed) { let c = this._buf.shift(); if (this._encoding && Buffer.isBuffer(c)) c = c.toString(this._encoding); this.emit("data", c); }
      if (this._ended && !this._buf.length && !this.readableEnded && !this.destroyed) {
        this.readableEnded = true; this.readable = false; this.emit("end");
        if (this._autoFechar !== false) { this._fechado = true; this.emit("close"); }
      } else if (!this._ended && this._flowing) this._lerMais();
    });
  };
  R.on = R.addListener = function (ev, fn) {
    EE.prototype.on.call(this, ev, fn);
    if (ev === "data" && this._flowing !== false) { this._flowing = true; this._escoar(); if (!this._buf.length) queueMicrotask(() => this._lerMais()); }
    if (ev === "readable") { this._flowing = false; queueMicrotask(() => { this._lerMais(); if (this._buf.length || this._ended) this.emit("readable"); }); }
    return this;
  };
  R.read = function (n) {
    if (!this._buf.length) {
      if (this._ended && !this.readableEnded) { this.readableEnded = true; queueMicrotask(() => { this.emit("end"); this._fechado = true; this.emit("close"); }); }
      else this._lerMais();
      if (!this._buf.length) return null;
    }
    if (this._objectMode || n === undefined) { const all = this._objectMode ? this._buf.shift() : Buffer.concat(this._buf); if (!this._objectMode) this._buf = []; return this._encoding && Buffer.isBuffer(all) ? all.toString(this._encoding) : all; }
    const all = Buffer.concat(this._buf); if (all.length < n && !this._ended) return null;
    this._buf = all.length > n ? [all.subarray(n)] : [];
    const out = all.subarray(0, n); return this._encoding ? out.toString(this._encoding) : out;
  };
  R.pause = function () { this._flowing = false; return this; };
  R.resume = function () { this._flowing = true; this._escoar(); if (!this._buf.length) queueMicrotask(() => this._lerMais()); return this; };
  R.isPaused = function () { return this._flowing === false; };
  R.setEncoding = function (e) { this._encoding = e; return this; };
  R.destroy = function (err, cb) {
    if (this.destroyed) return this;
    this.destroyed = true; this._ended = true; if (err) this._erro = err;
    const fim = (e) => { if (e) { this._erro = e; this.emit("error", e); } this._fechado = true; this.emit("close"); if (cb) cb(e); };
    if (this._destroy) this._destroy(err || null, (e) => queueMicrotask(() => fim(e))); else queueMicrotask(() => fim(err));
    return this;
  };
  R.unpipe = function () { return this; };
  R.wrap = function (s) { s.on("data", (c) => this.push(c)); s.on("end", () => this.push(null)); s.on("error", (e) => this.destroy(e)); this._read = () => s.resume && s.resume(); return this; };
  R[Symbol.asyncIterator] = async function* () {
    const q = []; let done = false, err = null, wake = null;
    this.on("data", (c) => { q.push(c); if (wake) { wake(); wake = null; } });
    this.on("end", () => { done = true; if (wake) wake(); });
    this.on("error", (e) => { err = e; if (wake) wake(); });
    this.on("close", () => { done = true; if (wake) wake(); });
    try { while (true) { if (q.length) yield q.shift(); else if (err) throw err; else if (done) return; else await new Promise((r) => { wake = r; }); } }
    finally { if (!done && !this.destroyed) this.destroy(); }
  };
  R.toArray = async function () { const out = []; for await (const c of this) out.push(c); return out; };
  R.map = function (fn) { const src = this; return Readable.from((async function* () { for await (const c of src) yield await fn(c); })()); };
  R.filter = function (fn) { const src = this; return Readable.from((async function* () { for await (const c of src) if (await fn(c)) yield c; })()); };
  R.forEach = async function (fn) { for await (const c of this) await fn(c); };
  Object.defineProperty(R, "readableLength", { get() { return this._readableState ? this._readableState.length : 0; } });
  Object.defineProperty(R, "readableFlowing", { get() { return this._flowing; }, set(v) { this._flowing = v; } });
  Object.defineProperty(R, "readableEncoding", { get() { return this._encoding; } });
  Object.defineProperty(R, "closed", { get() { return !!this._fechado; } });
  Object.defineProperty(R, "errored", { get() { return this._erro || null; } });
  Readable.from = function (iter, opts) {
    const r = new Readable({ objectMode: true, ...opts });
    if (typeof iter === "string" || Buffer.isBuffer(iter)) { r.push(iter); r.push(null); return r; }
    let comecou = false;
    r._read = function () {
      if (comecou) return; comecou = true;
      (async () => { try { for await (const c of iter) { if (r.destroyed) return; r.push(c); } r.push(null); } catch (e) { r.destroy(e); } })();
    };
    return r;
  };

  function Writable(opts) {
    if (!(this instanceof Writable) && !(this instanceof Duplex)) return new Writable(opts);
    opts = opts || {};
    Stream.call(this, opts);
    iniciarEscrita(this, opts);
  }
  function iniciarEscrita(s, opts) {
    s.writable = true; s.writableEnded = false; s.writableFinished = false; s.destroyed = s.destroyed || false; s._fechado = false;
    s._objectMode = s._objectMode || !!(opts.objectMode || opts.writableObjectMode);
    if (opts.write) s._write = opts.write;
    if (opts.writev) s._writev = opts.writev;
    if (opts.final) s._final = opts.final;
    if (opts.destroy) s._destroy = opts.destroy;
    s.writableHighWaterMark = opts.highWaterMark || opts.writableHighWaterMark || 16384; s._pending = 0; s._corked = 0;
    s.writableObjectMode = !!(opts.objectMode || opts.writableObjectMode);
    if (!s._writableState) s._writableState = estadoEscrita(s);
    s._decodeStrings = opts.decodeStrings !== false;
  }
  herdar(Writable, Stream);
  const W = Writable.prototype;
  W._write = function (chunk, enc, cb) { if (this._writev) this._writev([{ chunk, encoding: enc }], cb); else cb(); };
  W.write = function (chunk, enc, cb) {
    if (typeof enc === "function") { cb = enc; enc = undefined; }
    if (this.writableEnded || this.destroyed) { const e = Object.assign(new Error("write after end"), { code: "ERR_STREAM_WRITE_AFTER_END" }); if (cb) queueMicrotask(() => cb(e)); queueMicrotask(() => this.emit("error", e)); return false; }
    if (typeof chunk === "string" && !this._objectMode && this._decodeStrings !== false) { chunk = Buffer.from(chunk, enc || "utf8"); enc = "buffer"; }
    else if (!this._objectMode && chunk instanceof Uint8Array && !Buffer.isBuffer(chunk)) chunk = Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength);
    this._pending++;
    let sincrono = true;
    this._write(chunk, enc || (typeof chunk === "string" ? "utf8" : "buffer"), (e) => {
      const depois = () => { this._pending--; if (e) { this._erro = e; this.emit("error", e); } if (cb) cb(e); if (!this._pending) { this.emit("drain"); this._maybeFinish(); } };
      if (sincrono) queueMicrotask(depois); else depois();
    });
    sincrono = false;
    return this._pending < 16;
  };
  W._maybeFinish = function () {
    if (this.writableEnded && !this._pending && !this.writableFinished && !this._terminando) {
      this._terminando = true;
      const fin = () => { this.writableFinished = true; this.emit("finish"); if (this._autoFechar !== false && !(this instanceof Duplex && !this.readableEnded && this._ended === false)) { this._fechado = true; this.emit("close"); } };
      if (this._final) this._final((e) => { if (e) this.emit("error", e); else fin(); }); else fin();
    }
  };
  W.end = function (chunk, enc, cb) {
    if (typeof chunk === "function") { cb = chunk; chunk = undefined; }
    if (typeof enc === "function") { cb = enc; enc = undefined; }
    if (chunk != null) this.write(chunk, enc);
    if (this.writableEnded) { if (cb) queueMicrotask(cb); return this; }
    this.writableEnded = true; this.writable = false;
    if (cb) this.once("finish", cb);
    queueMicrotask(() => this._maybeFinish());
    return this;
  };
  W.cork = function () { this._corked++; };
  W.uncork = function () { this._corked = Math.max(0, this._corked - 1); };
  W.setDefaultEncoding = function () { return this; };
  W.destroy = function (err, cb) {
    if (this.destroyed) return this;
    this.destroyed = true; if (err) this._erro = err;
    const fim = (e) => { if (e) this.emit("error", e); this._fechado = true; this.emit("close"); if (cb) cb(e); };
    if (this._destroy) this._destroy(err || null, (e) => queueMicrotask(() => fim(e))); else queueMicrotask(() => fim(err));
    return this;
  };
  Object.defineProperty(W, "writableLength", { get() { return this._pending; } });
  Object.defineProperty(W, "writableNeedDrain", { get() { return this._pending >= 16; } });
  Object.defineProperty(W, "writableCorked", { get() { return this._corked; } });
  Object.defineProperty(Writable, Symbol.hasInstance, { value(obj) { if (Function.prototype[Symbol.hasInstance].call(this, obj)) return true; return this === Writable && !!obj && obj._writableState !== undefined && typeof obj.write === "function"; } });

  function Duplex(opts) {
    if (!(this instanceof Duplex)) return new Duplex(opts);
    opts = opts || {};
    Readable.call(this, opts);
    iniciarEscrita(this, opts);
    if (opts.readable === false) { this.readable = false; this._ended = true; this.readableEnded = true; }
    if (opts.writable === false) { this.writable = false; this.writableEnded = true; this.writableFinished = true; }
    if (opts.allowHalfOpen === false) this.once("end", () => this.end());
  }
  herdar(Duplex, Readable);
  for (const k of ["write", "_write", "end", "_maybeFinish", "cork", "uncork", "setDefaultEncoding"]) Duplex.prototype[k] = W[k];
  for (const k of ["writableLength", "writableNeedDrain", "writableCorked"]) Object.defineProperty(Duplex.prototype, k, Object.getOwnPropertyDescriptor(W, k));
  Duplex.prototype.destroy = function (err, cb) { Readable.prototype.destroy.call(this, err, cb); this.writable = false; return this; };
  Duplex.from = (x) => (x instanceof Readable || x instanceof Duplex ? x : Readable.from(x));

  function Transform(opts) {
    if (!(this instanceof Transform)) return new Transform(opts);
    opts = opts || {};
    Duplex.call(this, opts);
    if (opts.transform) this._transform = opts.transform;
    if (opts.flush) this._flush = opts.flush;
  }
  herdar(Transform, Duplex);
  const T = Transform.prototype;
  T._transform = function (chunk, enc, cb) { cb(null, chunk); };
  T._write = function (chunk, enc, cb) { this._transform(chunk, enc, (e, out) => { if (e) return cb(e); if (out != null) this.push(out); cb(); }); };
  T.end = function (chunk, enc, cb) {
    if (typeof chunk === "function") { cb = chunk; chunk = undefined; }
    if (typeof enc === "function") { cb = enc; enc = undefined; }
    if (chunk != null) this.write(chunk, enc);
    if (this.writableEnded) return this;
    this.writableEnded = true;
    const esperar = () => {
      if (this._pending) { queueMicrotask(esperar); return; }
      const done = () => { this.push(null); this.writableFinished = true; this.emit("finish"); if (cb) cb(); };
      const flush = typeof this._flush === "function" ? this._flush : null;
      if (flush) flush.call(this, (e, out) => { if (e) { this.emit("error", e); return; } if (out != null) this.push(out); done(); }); else done();
    };
    queueMicrotask(esperar);
    return this;
  };
  function PassThrough(opts) { if (!(this instanceof PassThrough)) return new PassThrough(opts); Transform.call(this, opts); }
  herdar(PassThrough, Transform);

  const finished = (s, opts, cb) => {
    if (typeof opts === "function") { cb = opts; opts = {}; }
    let done = false;
    const end = (e) => { if (!done) { done = true; cb(e || undefined); } };
    const ehLeitura = typeof s.read === "function" && s.readable !== false;
    const ehEscrita = typeof s.write === "function";
    if ((s.readableEnded || !ehLeitura) && (s.writableFinished || !ehEscrita)) { queueMicrotask(() => end()); return () => {}; }
    s.once("end", () => { if (!ehEscrita || s.writableFinished) end(); });
    s.once("finish", () => { if (!ehLeitura || s.readableEnded) end(); });
    s.once("error", end);
    s.once("close", () => { if (!done) end(s.readableEnded || s.writableFinished ? undefined : Object.assign(new Error("Premature close"), { code: "ERR_STREAM_PREMATURE_CLOSE" })); });
    return () => {};
  };
  const pipeline = (...streams) => {
    const cb = typeof streams[streams.length - 1] === "function" ? streams.pop() : null;
    if (streams.length === 1 && Array.isArray(streams[0])) streams = streams[0];
    streams = streams.map((s, i) => (typeof s === "function" ? Readable.from(s(i ? streams[i - 1] : undefined)) : s && typeof s.pipe !== "function" && (s[Symbol.asyncIterator] || s[Symbol.iterator]) && typeof s !== "string" ? Readable.from(s) : s));
    let erro = null;
    const falhar = (e) => { if (erro) return; erro = e; for (const s of streams) if (s.destroy && !s.destroyed) s.destroy(); if (cb) cb(e); };
    for (let i = 0; i < streams.length - 1; i++) streams[i].pipe(streams[i + 1]);
    for (const s of streams) s.on("error", falhar);
    const last = streams[streams.length - 1];
    if (cb) finished(last, (e) => { if (!erro) { if (e) falhar(e); else cb(); } });
    return last;
  };
  const promises = { pipeline: (...s) => new Promise((res, rej) => pipeline(...s, (e) => (e ? rej(e) : res()))), finished: (s, o) => new Promise((res, rej) => finished(s, o, (e) => (e ? rej(e) : res()))) };
  Object.assign(Stream, { Stream, Readable, Writable, Duplex, Transform, PassThrough, finished, pipeline, promises });
  Stream.addAbortSignal = (sig, s) => { if (sig) sig.addEventListener("abort", () => s.destroy(Object.assign(new Error("The operation was aborted"), { name: "AbortError" }))); return s; };
  Stream.isReadable = (s) => !!s && typeof s.read === "function" && s.readable !== false && !s.destroyed;
  Stream.isWritable = (s) => !!s && typeof s.write === "function" && s.writable !== false && !s.destroyed;
  Stream.isErrored = (s) => !!(s && s._erro);
  Stream.isDisturbed = (s) => !!(s && (s.readableEnded || s._flowing));
  Stream.getDefaultHighWaterMark = (obj) => (obj ? 16 : 16384);
  Stream.setDefaultHighWaterMark = () => {};
  Stream.compose = (...s) => { const first = s[0], last = s[s.length - 1]; for (let i = 0; i < s.length - 1; i++) s[i].pipe(s[i + 1]); const d = new Duplex({ write(c, e, cb) { first.write(c, e, cb); }, final(cb) { first.end(); cb(); }, read() {} }); last.on("data", (c) => d.push(c)); last.on("end", () => d.push(null)); return d; };
  module.exports = Stream;
});
__nodeDefine("stream/promises", (module, exports, require) => { module.exports = require("stream").promises; });
__nodeDefine("stream/web", (module) => { module.exports = { ReadableStream: globalThis.ReadableStream, WritableStream: globalThis.WritableStream, TransformStream: globalThis.TransformStream, TextDecoderStream: globalThis.TextDecoderStream, TextEncoderStream: globalThis.TextEncoderStream }; });
