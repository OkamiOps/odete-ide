__nodeDefine("child_process", (module, exports, require) => {
  const EE = require("events");
  const notSupported = (cmd) => { const e = new Error(`Odete: não dá para executar "${cmd}" no iPad. Só scripts JavaScript rodam aqui.`); e.code = "ENOENT"; return e; };
  function spawn(cmd, args = [], opts = {}) { const child = new EE(); child.stdout = new EE(); child.stderr = new EE(); child.stdin = { write() {}, end() {} }; child.pid = 0; child.kill = () => true; queueMicrotask(() => child.emit("error", notSupported(cmd))); return child; }
  const exec = (cmd, opts, cb) => { if (typeof opts === "function") cb = opts; queueMicrotask(() => cb && cb(notSupported(cmd), "", "")); return spawn(cmd); };
  module.exports = { spawn, exec, execFile: exec, fork: spawn, spawnSync: (cmd) => ({ status: 127, error: notSupported(cmd), stdout: Buffer.alloc(0), stderr: Buffer.from(notSupported(cmd).message) }), execSync: (cmd) => { throw notSupported(cmd); }, execFileSync: (cmd) => { throw notSupported(cmd); } };
});
