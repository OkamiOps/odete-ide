__nodeDefine("events", (module) => {
  class EventEmitter {
    constructor() { this._events = Object.create(null); this._max = 10; }
    static get defaultMaxListeners() { return 10; }
    on(ev, fn) { (this._events[ev] || (this._events[ev] = [])).push(fn); if (ev !== "newListener" && this._events.newListener) this.emit("newListener", ev, fn); return this; }
    addListener(ev, fn) { return this.on(ev, fn); }
    prependListener(ev, fn) { (this._events[ev] || (this._events[ev] = [])).unshift(fn); return this; }
    once(ev, fn) { const w = (...a) => { this.off(ev, w); fn.apply(this, a); }; w.listener = fn; return this.on(ev, w); }
    prependOnceListener(ev, fn) { const w = (...a) => { this.off(ev, w); fn.apply(this, a); }; w.listener = fn; return this.prependListener(ev, w); }
    off(ev, fn) { const l = this._events[ev]; if (!l) return this; const i = l.findIndex((x) => x === fn || x.listener === fn); if (i >= 0) l.splice(i, 1); if (!l.length) delete this._events[ev]; return this; }
    removeListener(ev, fn) { return this.off(ev, fn); }
    removeAllListeners(ev) { if (ev === undefined) this._events = Object.create(null); else delete this._events[ev]; return this; }
    emit(ev, ...args) {
      const l = this._events[ev];
      if (!l || !l.length) { if (ev === "error") { const e = args[0] instanceof Error ? args[0] : new Error("Unhandled error. " + String(args[0])); throw e; } return false; }
      for (const fn of [...l]) fn.apply(this, args);
      return true;
    }
    listenerCount(ev) { return (this._events[ev] || []).length; }
    listeners(ev) { return [...(this._events[ev] || [])].map((f) => f.listener || f); }
    rawListeners(ev) { return [...(this._events[ev] || [])]; }
    eventNames() { return Object.keys(this._events); }
    setMaxListeners(n) { this._max = n; return this; }
    getMaxListeners() { return this._max; }
  }
  EventEmitter.EventEmitter = EventEmitter;
  EventEmitter.once = (em, ev) => new Promise((res, rej) => { em.once(ev, (...a) => res(a)); if (ev !== "error") em.once("error", rej); });
  EventEmitter.on = (em, ev) => { const q = []; let w; em.on(ev, (...a) => { if (w) { w(a); w = null; } else q.push(a); }); return { [Symbol.asyncIterator]() { return this; }, next() { return q.length ? Promise.resolve({ value: q.shift(), done: false }) : new Promise((r) => { w = (v) => r({ value: v, done: false }); }); } }; };
  module.exports = EventEmitter;
});
