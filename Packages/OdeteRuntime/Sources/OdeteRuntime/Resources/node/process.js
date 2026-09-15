__nodeDefine("process", (module, exports, require) => {
  const H = globalThis.__odete, EE = require("events");
  let cwd = H.cwd;
  const p = new EE();
  const stdio = (fd) => { const { Writable } = require("stream"); const w = new Writable({ write(c, e, cb) { H.write(fd, typeof c === "string" ? c : Buffer.from(c).toString("utf8").replace(/\n$/, "")); cb(); } }); w.isTTY = true; w.columns = 80; w.rows = 24; w.fd = fd; w.getColorDepth = () => 1; w.hasColors = () => false; w.cursorTo = w.clearLine = w.moveCursor = () => true; return w; };
  Object.assign(p, {
    title: "node", version: "v22.0.0-odete", versions: { node: "22.0.0", v8: "jsc", odete: "0.1" }, platform: "darwin", arch: "arm64", pid: 1, ppid: 0, execPath: "/usr/local/bin/node", execArgv: [], release: { name: "node" }, config: { variables: {} }, features: {},
    argv: ["/usr/local/bin/node", ...H.argv], argv0: "node", env: { ...H.env },
    cwd: () => cwd, chdir: (d) => { cwd = require("path").resolve(cwd, d); }, exitCode: undefined,
    exit: (code) => { const c = code ?? p.exitCode ?? 0; p.emit("exit", c); H.exit(c); throw new (class ExitError extends Error { constructor() { super("process.exit"); this.__odeteExit = true; } })(); },
    nextTick: (fn, ...a) => queueMicrotask(() => fn(...a)),
    hrtime: Object.assign((prev) => { const ms = H.perfNow(); let s = Math.floor(ms / 1000), ns = Math.floor((ms % 1000) * 1e6); if (prev) { s -= prev[0]; ns -= prev[1]; if (ns < 0) { s--; ns += 1e9; } } return [s, ns]; }, { bigint: () => BigInt(Math.floor(H.perfNow() * 1e6)) }),
    uptime: () => H.perfNow() / 1000, memoryUsage: Object.assign(() => ({ rss: 0, heapTotal: 0, heapUsed: 0, external: 0, arrayBuffers: 0 }), { rss: () => 0 }), cpuUsage: () => ({ user: 0, system: 0 }), resourceUsage: () => ({}),
    umask: () => 0o22, getuid: () => 501, getgid: () => 20, geteuid: () => 501, getegid: () => 20, kill: () => true, abort: () => H.exit(134),
    stdout: stdio(1), stderr: stdio(2), stdin: Object.assign(new EE(), { isTTY: false, setRawMode() {}, resume() {}, pause() {}, setEncoding() {}, read: () => null, fd: 0 }),
    emitWarning: (w) => H.write(2, "(node) Warning: " + (w && w.message || w)),
    binding: () => { throw new Error("process.binding não existe na Odete"); }, report: {}, allowedNodeEnvironmentFlags: new Set(), availableMemory: () => 4 * 1024 ** 3, constrainedMemory: () => 0,
    getBuiltinModule: (n) => (globalThis.__nodeHas(n) ? globalThis.__nodeRequire(n) : undefined),
    loadEnvFile() {}, setSourceMapsEnabled() {}, setUncaughtExceptionCaptureCallback() {}, hasUncaughtExceptionCaptureCallback: () => false,
  });
  globalThis.process = p;
  module.exports = p;
});
