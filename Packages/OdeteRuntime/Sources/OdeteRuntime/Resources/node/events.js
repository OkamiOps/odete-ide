__nodeDefine("events", (module) => {
  // Função construtora, e não `class`: muito pacote ainda faz `EventEmitter.call(this)` com
  // `util.inherits`, ou copia os métodos para um objeto qualquer (`Object.assign(o,
  // EE.prototype)`) — com classe o primeiro dava "Cannot call a class constructor" e o
  // segundo morria em `this._events` indefinido. `_events` guarda uma função quando há um
  // ouvinte e uma lista quando há vários, como no Node (há quem olhe lá dentro).
  const kCapture = Symbol("kCapture");
  const errorMonitor = Symbol("events.errorMonitor");
  let defaultMaxListeners = 10;
  function EventEmitter(opts) { EventEmitter.init.call(this, opts); }
  EventEmitter.init = function (opts) {
    if (this._events === undefined || this._events === Object.getPrototypeOf(this)._events) { this._events = Object.create(null); this._eventsCount = 0; }
    this._maxListeners = this._maxListeners || undefined;
    if (opts && opts.captureRejections) this[kCapture] = true;
  };
  const eventos = (em) => { if (!em._events || em._events === Object.getPrototypeOf(em)._events) { em._events = Object.create(null); em._eventsCount = 0; } return em._events; };
  function adicionar(em, ev, fn, antes) {
    if (typeof fn !== "function") throw Object.assign(new TypeError('The "listener" argument must be of type function. Received ' + typeof fn), { code: "ERR_INVALID_ARG_TYPE" });
    const evs = eventos(em);
    if (evs.newListener !== undefined) { em.emit("newListener", ev, fn.listener ? fn.listener : fn); }
    const atual = evs[ev];
    if (atual === undefined) { evs[ev] = fn; em._eventsCount++; }
    else if (typeof atual === "function") evs[ev] = antes ? [fn, atual] : [atual, fn];
    else if (antes) atual.unshift(fn); else atual.push(fn);
    return em;
  }
  function umaVez(em, ev, fn) {
    const estado = { disparou: false, em, ev, fn };
    const w = function (...a) { if (estado.disparou) return; estado.disparou = true; em.removeListener(ev, w); return fn.apply(em, a); };
    w.listener = fn;
    return w;
  }
  const P = EventEmitter.prototype;
  P._events = undefined; P._eventsCount = 0; P._maxListeners = undefined;
  P.setMaxListeners = function (n) { this._maxListeners = n; return this; };
  P.getMaxListeners = function () { return this._maxListeners === undefined ? defaultMaxListeners : this._maxListeners; };
  P.on = P.addListener = function (ev, fn) { return adicionar(this, ev, fn, false); };
  P.prependListener = function (ev, fn) { return adicionar(this, ev, fn, true); };
  P.once = function (ev, fn) { return adicionar(this, ev, umaVez(this, ev, fn), false); };
  P.prependOnceListener = function (ev, fn) { return adicionar(this, ev, umaVez(this, ev, fn), true); };
  P.off = P.removeListener = function (ev, fn) {
    const evs = eventos(this);
    const l = evs[ev];
    if (l === undefined) return this;
    if (l === fn || l.listener === fn) {
      if (--this._eventsCount === 0) this._events = Object.create(null); else delete evs[ev];
      if (evs.removeListener) this.emit("removeListener", ev, l.listener || fn);
    } else if (typeof l !== "function") {
      let i = -1;
      for (let k = l.length - 1; k >= 0; k--) if (l[k] === fn || l[k].listener === fn) { i = k; break; }
      if (i < 0) return this;
      const saiu = l[i];
      l.splice(i, 1);
      if (l.length === 1) evs[ev] = l[0];
      if (evs.removeListener !== undefined) this.emit("removeListener", ev, saiu.listener || saiu);
    }
    return this;
  };
  P.removeAllListeners = function (ev) {
    const evs = eventos(this);
    if (ev === undefined) { this._events = Object.create(null); this._eventsCount = 0; return this; }
    if (evs[ev] !== undefined) { if (--this._eventsCount === 0) this._events = Object.create(null); else delete evs[ev]; }
    return this;
  };
  P.emit = function (ev, ...args) {
    const evs = eventos(this);
    if (ev === "error" && evs[errorMonitor] !== undefined) this.emit(errorMonitor, ...args);
    const l = evs[ev];
    if (l === undefined) {
      if (ev === "error") {
        const e = args[0];
        if (e instanceof Error) throw e;
        const err = new Error("Unhandled error." + (e === undefined ? "" : " (" + String(e) + ")"));
        err.code = "ERR_UNHANDLED_ERROR"; err.context = e;
        throw err;
      }
      return false;
    }
    if (typeof l === "function") l.apply(this, args);
    else for (const fn of l.slice()) fn.apply(this, args);
    return true;
  };
  P.listenerCount = function (ev, fn) {
    const l = eventos(this)[ev];
    if (l === undefined) return 0;
    if (typeof l === "function") return fn === undefined || l === fn || l.listener === fn ? 1 : 0;
    return fn === undefined ? l.length : l.filter((x) => x === fn || x.listener === fn).length;
  };
  P.rawListeners = function (ev) { const l = eventos(this)[ev]; return l === undefined ? [] : typeof l === "function" ? [l] : l.slice(); };
  P.listeners = function (ev) { return this.rawListeners(ev).map((f) => f.listener || f); };
  P.eventNames = function () { return Reflect.ownKeys(eventos(this)); };
  EventEmitter.EventEmitter = EventEmitter;
  EventEmitter.errorMonitor = errorMonitor;
  EventEmitter.captureRejectionSymbol = Symbol.for("nodejs.rejection");
  EventEmitter.captureRejections = false;
  Object.defineProperty(EventEmitter, "defaultMaxListeners", { enumerable: true, get: () => defaultMaxListeners, set: (n) => { defaultMaxListeners = n; } });
  EventEmitter.setMaxListeners = (n, ...alvos) => { if (!alvos.length) defaultMaxListeners = n; for (const a of alvos) if (a && a.setMaxListeners) a.setMaxListeners(n); };
  EventEmitter.getMaxListeners = (em) => (em && em.getMaxListeners ? em.getMaxListeners() : defaultMaxListeners);
  EventEmitter.listenerCount = (em, ev) => em.listenerCount(ev);
  EventEmitter.getEventListeners = (em, ev) => (typeof em.listeners === "function" ? em.listeners(ev) : em._l ? em._l.slice() : []);
  EventEmitter.once = (em, ev, opts = {}) => new Promise((res, rej) => {
    const sinal = opts.signal;
    if (sinal && sinal.aborted) { rej(Object.assign(new Error("The operation was aborted"), { name: "AbortError", code: "ABORT_ERR" })); return; }
    if (typeof em.addEventListener === "function" && typeof em.on !== "function") { em.addEventListener(ev, (...a) => res(a), { once: true }); return; }
    const aoErro = (e) => { em.removeListener(ev, aoEvento); rej(e); };
    const aoEvento = (...a) => { if (ev !== "error") em.removeListener("error", aoErro); res(a); };
    em.once(ev, aoEvento);
    if (ev !== "error") em.once("error", aoErro);
    if (sinal) sinal.addEventListener("abort", () => { em.removeListener(ev, aoEvento); em.removeListener("error", aoErro); rej(Object.assign(new Error("The operation was aborted"), { name: "AbortError", code: "ABORT_ERR" })); });
  });
  EventEmitter.on = (em, ev, opts = {}) => {
    const fila = [], esperando = [];
    let erro = null, fim = false;
    const empurrar = (...a) => { const w = esperando.shift(); if (w) w.res({ value: a, done: false }); else fila.push(a); };
    const falhar = (e) => { erro = e; const w = esperando.shift(); if (w) w.rej(e); };
    em.on(ev, empurrar);
    if (ev !== "error") em.on("error", falhar);
    const it = {
      next() { if (fila.length) return Promise.resolve({ value: fila.shift(), done: false }); if (erro) { const e = erro; erro = null; return Promise.reject(e); } if (fim) return Promise.resolve({ value: undefined, done: true }); return new Promise((res, rej) => esperando.push({ res, rej })); },
      return() { fim = true; em.removeListener(ev, empurrar); em.removeListener("error", falhar); for (const w of esperando.splice(0)) w.res({ value: undefined, done: true }); return Promise.resolve({ value: undefined, done: true }); },
      throw(e) { erro = e; return it.return(); },
      [Symbol.asyncIterator]() { return this; },
    };
    if (opts.signal) opts.signal.addEventListener("abort", () => it.return());
    return it;
  };
  EventEmitter.addAbortListener = (sinal, fn) => { sinal.addEventListener("abort", fn, { once: true }); return { [Symbol.dispose || Symbol.for("dispose")]() { sinal.removeEventListener("abort", fn); } }; };
  EventEmitter.usingDomains = false;
  class EventEmitterAsyncResource extends EventEmitter { constructor(o) { super(o); } get asyncResource() { return this; } emitDestroy() {} }
  EventEmitter.EventEmitterAsyncResource = EventEmitterAsyncResource;
  module.exports = EventEmitter;
});
