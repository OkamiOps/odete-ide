__nodeDefine("process", (module, exports, require) => {
  const H = globalThis.__odete, EE = require("events");
  let cwd = H.cwd;
  const p = new EE();
  // stdout/stderr escrevem bytes crus (`writeRaw`): `write("a"); write("b\n")` é uma linha
  // "ab", e binário (`> arquivo.png`) chega inteiro. Antes cada `write` virava uma linha e o
  // Buffer passava por UTF-8. O console.log continua indo por `H.write`, uma linha por vez.
  const stdio = (fd) => {
    const { Writable } = require("stream");
    const w = new Writable({ decodeStrings: false, write(c, e, cb) { H.writeRaw(fd, typeof c === "string" ? c : c instanceof Uint8Array ? c : Buffer.from(c)); cb(); } });
    w.isTTY = true; w.columns = 80; w.rows = 24; w.fd = fd; w._type = "tty";
    w.getColorDepth = () => 1; w.hasColors = () => false; w.getWindowSize = () => [80, 24];
    w.cursorTo = w.clearLine = w.clearScreenDown = w.moveCursor = (...a) => { const cb = a.find((x) => typeof x === "function"); if (cb) queueMicrotask(cb); return true; };
    // `process.stdout.write` é síncrono no Node (TTY e arquivo): a função devolve depois de
    // escrever, e quem chama `process.exit()` logo depois não perde a saída.
    w.write = function (chunk, enc, cb) {
      if (typeof enc === "function") { cb = enc; enc = undefined; }
      if (typeof chunk === "string" && enc && enc !== "utf8" && enc !== "utf-8") chunk = Buffer.from(chunk, enc);
      H.writeRaw(fd, typeof chunk === "string" || chunk instanceof Uint8Array ? chunk : Buffer.from(chunk));
      if (cb) queueMicrotask(cb);
      return true;
    };
    w.end = function (chunk, enc, cb) { if (typeof chunk === "function") { cb = chunk; chunk = undefined; } if (chunk != null) w.write(chunk, enc); if (cb) queueMicrotask(cb); return w; };
    w.destroySoon = w.destroy = () => w;
    return w;
  };
  // stdin: o que veio pelo pipe (`echo x | node s.js`), inteiro, entregue como um Readable
  // que termina; sem pipe não há nada a ler (o terminal ainda não passa o teclado).
  const stdin = (() => {
    const { Readable } = require("stream");
    const temDados = !!H.temStdin;
    const r = new Readable({ read() {} });
    r.fd = 0; r.isTTY = !temDados ? true : undefined; r.setRawMode = function () { return this; }; r.ref = r.unref = function () { return this; };
    if (temDados) {
      let entregue = false;
      r._read = function () { if (entregue) return; entregue = true; const b = H.stdin(); if (b && b.length) this.push(Buffer.from(b)); this.push(null); };
    }
    return r;
  })();
  let saiu = false;
  class ExitError extends Error { constructor() { super("process.exit"); this.__odeteExit = true; } }
  Object.assign(p, {
    title: "node", version: "v22.0.0-odete", versions: { node: "22.0.0", v8: "jsc", odete: "0.1", uv: "1.0.0", modules: "127" }, platform: "darwin", arch: "arm64", pid: 1, ppid: 0, execPath: "/usr/local/bin/node", execArgv: [], release: { name: "node", lts: "Odete" }, config: { variables: {} }, features: { inspector: false, ipv6: true, tls: false, typescript: "transform" },
    argv: ["/usr/local/bin/node", ...H.argv], argv0: "node", env: { ...H.env },
    cwd: () => cwd, chdir: (d) => { const novo = require("path").resolve(cwd, String(d)); const s = require("fs").statSync(novo); if (!s.isDirectory()) throw Object.assign(new Error(`ENOTDIR: not a directory, chdir '${d}'`), { code: "ENOTDIR" }); cwd = novo; }, exitCode: undefined,
    exit: (code) => {
      const c = code ?? p.exitCode ?? 0;
      p.exitCode = c;
      if (!saiu && !(globalThis.__odete_marcarSaida && globalThis.__odete_marcarSaida())) { saiu = true; try { p.emit("exit", c); } catch {} }
      H.exit(p.exitCode ?? c);
      throw new ExitError();
    },
    reallyExit: (code) => { H.exit(code || 0); throw new ExitError(); },
    nextTick: (fn, ...a) => globalThis.__odete_nextTick(fn, ...a),
    hrtime: Object.assign((prev) => { const ms = H.perfNow(); let s = Math.floor(ms / 1000), ns = Math.floor((ms % 1000) * 1e6); if (prev) { s -= prev[0]; ns -= prev[1]; if (ns < 0) { s--; ns += 1e9; } } return [s, ns]; }, { bigint: () => BigInt(Math.floor(H.perfNow() * 1e6)) }),
    uptime: () => H.perfNow() / 1000, memoryUsage: Object.assign(() => ({ rss: 0, heapTotal: 0, heapUsed: 0, external: 0, arrayBuffers: 0 }), { rss: () => 0 }), cpuUsage: () => ({ user: 0, system: 0 }), resourceUsage: () => ({}),
    umask: () => 0o22, getuid: () => 501, getgid: () => 20, geteuid: () => 501, getegid: () => 20, getgroups: () => [20],
    kill: (pid, sinal) => { if (pid === p.pid || pid === 0) { p.exit(sinal === "SIGTERM" || sinal === 15 ? 143 : 130); } return true; },
    abort: () => { H.exit(134); throw new ExitError(); },
    stdout: stdio(1), stderr: stdio(2), stdin,
    emitWarning: (w, tipo, codigo) => { const nome = (w && w.name) || (typeof tipo === "string" ? tipo : (tipo && tipo.type) || "Warning"); const msg = (w && w.message) || String(w); if (p.listenerCount("warning")) { p.emit("warning", Object.assign(w instanceof Error ? w : new Error(msg), { name: nome })); return; } H.write(2, `(node:${p.pid}) ${codigo ? "[" + codigo + "] " : ""}${nome}: ${msg}`); },
    binding: () => { throw new Error("process.binding não existe na Odete"); }, report: {}, allowedNodeEnvironmentFlags: new Set(), availableMemory: () => 4 * 1024 ** 3, constrainedMemory: () => 0,
    getBuiltinModule: (n) => (globalThis.__nodeHas(n) ? globalThis.__nodeRequire(n) : undefined),
    loadEnvFile(caminho = ".env") { const txt = require("fs").readFileSync(caminho, "utf8"); for (const [k, v] of Object.entries(require("util").parseEnv(txt))) if (p.env[k] === undefined) p.env[k] = v; },
    setSourceMapsEnabled() {}, setUncaughtExceptionCaptureCallback() {}, hasUncaughtExceptionCaptureCallback: () => false,
    emit: EE.prototype.emit,
  });
  // Laço vazio: `beforeExit` (pode agendar mais trabalho) e, na saída, `exit`.
  globalThis.__odete_antesDeSair = () => { if (p.listenerCount("beforeExit")) p.emit("beforeExit", p.exitCode ?? 0); };
  globalThis.__odete_aoSair = (codigo) => {
    if (saiu || (globalThis.__odete_marcarSaida && globalThis.__odete_marcarSaida())) return;
    saiu = true;
    if (p.exitCode === undefined) p.exitCode = codigo;
    try { p.emit("exit", p.exitCode); } catch (e) { globalThis.__odete_reportUncaught(e); }
  };
  globalThis.process = p;
  module.exports = p;
});
