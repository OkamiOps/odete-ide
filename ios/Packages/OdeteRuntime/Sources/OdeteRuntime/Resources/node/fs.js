__nodeDefine("fs", (module, exports, require) => {
  const H = globalThis.__odete, path = require("path");
  const abs = (p) => { p = String(p instanceof URL ? p.pathname : p); return path.isAbsolute(p) ? p : path.resolve(p); };
  function mkErr(r, syscall) { const e = new Error(`${r.error}: ${r.message}, ${syscall} '${r.path}'`); e.code = r.error; e.errno = -2; e.syscall = syscall; e.path = r.path; return e; }
  const check = (r, syscall) => { if (r && typeof r === "object" && r.error) throw mkErr(r, syscall); return r; };
  class Stats { constructor(s) { this.size = s.size; this.mtimeMs = s.mtime; this.mtime = new Date(s.mtime); this.atime = this.ctime = this.birthtime = this.mtime; this.atimeMs = this.ctimeMs = this.birthtimeMs = s.mtime; this.mode = (s.isDir ? 0o40000 : 0o100000) | s.mode; this._d = s.isDir; this._l = s.isLink; this.uid = 501; this.gid = 20; this.ino = 0; this.dev = 0; this.nlink = 1; this.blksize = 4096; this.blocks = Math.ceil(s.size / 512); } isDirectory() { return this._d; } isFile() { return !this._d; } isSymbolicLink() { return !!this._l; } isFIFO() { return false; } isSocket() { return false; } isBlockDevice() { return false; } isCharacterDevice() { return false; } }
  class Dirent { constructor(name, s, parent) { this.name = name; this.parentPath = parent; this.path = parent; this._d = s.isDir; this._l = s.isLink; } isDirectory() { return this._d; } isFile() { return !this._d; } isSymbolicLink() { return !!this._l; } }
  const enc = (o) => (typeof o === "string" ? o : o && o.encoding) || null;
  const fs = {
    constants: { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1, O_RDONLY: 0, O_WRONLY: 1, O_RDWR: 2, O_CREAT: 64, O_TRUNC: 512, O_APPEND: 1024, COPYFILE_EXCL: 1 },
    existsSync: (p) => H.exists(abs(p)),
    readFileSync(p, o) { const e = enc(o); const a = abs(p); if (e && e !== "buffer") { const r = check(H.readText(a), "open"); return e === "utf8" || e === "utf-8" ? r : Buffer.from(r, "utf8").toString(e); } return Buffer.from(check(H.readB64(a), "open"), "base64"); },
    writeFileSync(p, data, o) { const a = abs(p); const flag = o && o.flag; const append = flag === "a" || flag === "a+"; if (typeof data === "string") check(H.writeText(a, data, append), "open"); else check(H.writeB64(a, Buffer.from(data).toString("base64"), append), "open"); },
    appendFileSync(p, data, o) { fs.writeFileSync(p, data, { ...(typeof o === "object" ? o : {}), flag: "a" }); },
    statSync(p, o) { const r = H.stat(abs(p)); if (r.error) { if (o && o.throwIfNoEntry === false) return undefined; throw mkErr(r, "stat"); } return new Stats(r); },
    lstatSync(p, o) { return fs.statSync(p, o); },
    readdirSync(p, o) { const a = abs(p); const names = check(H.readdir(a), "scandir"); if (o && o.withFileTypes) return names.map((n) => new Dirent(n, H.stat(path.join(a, n)), a)); if (o && o.recursive) { const out = []; const walk = (dir, pre) => { for (const n of check(H.readdir(dir), "scandir")) { out.push(pre + n); const s = H.stat(path.join(dir, n)); if (s.isDir) walk(path.join(dir, n), pre + n + "/"); } }; walk(a, ""); return out; } return names; },
    mkdirSync(p, o) { const a = abs(p); const rec = !!(o && o.recursive); check(H.mkdir(a, rec), "mkdir"); return rec ? a : undefined; },
    rmSync(p, o = {}) { check(H.rm(abs(p), !!o.recursive, !!o.force), "rm"); },
    rmdirSync(p, o = {}) { check(H.rm(abs(p), !!o.recursive, false), "rmdir"); },
    unlinkSync(p) { check(H.rm(abs(p), false, false), "unlink"); },
    renameSync(a, b) { check(H.rename(abs(a), abs(b)), "rename"); },
    copyFileSync(a, b, mode) { if (mode & 1 && H.exists(abs(b))) throw mkErr({ error: "EEXIST", message: "file already exists", path: abs(b) }, "copyfile"); check(H.copy(abs(a), abs(b)), "copyfile"); },
    cpSync(a, b, o = {}) { check(H.copy(abs(a), abs(b)), "cp"); },
    realpathSync: Object.assign((p) => H.realpath(abs(p)), { native: (p) => H.realpath(abs(p)) }),
    accessSync(p) { if (!H.exists(abs(p))) throw mkErr({ error: "ENOENT", message: "no such file or directory", path: abs(p) }, "access"); },
    chmodSync(p, m) { check(H.chmod(abs(p), typeof m === "string" ? parseInt(m, 8) : m), "chmod"); },
    symlinkSync(t, p) { check(H.symlink(t, abs(p)), "symlink"); },
    readlinkSync(p) { return check(H.readlink(abs(p)), "readlink"); },
    mkdtempSync(prefix) { const p = prefix + Math.random().toString(36).slice(2, 8); fs.mkdirSync(p, { recursive: true }); return p; },
    truncateSync(p, len = 0) { const b = fs.readFileSync(p); fs.writeFileSync(p, b.subarray(0, len)); },
    utimesSync() {}, chownSync() {}, fsyncSync() {},
    openSync(p, flags = "r") { const a = abs(p); if (String(flags).includes("w")) fs.writeFileSync(a, ""); else if (!H.exists(a) && !String(flags).includes("a")) throw mkErr({ error: "ENOENT", message: "no such file or directory", path: a }, "open"); const fd = ++fdSeq; fds.set(fd, { path: a, pos: 0, flags: String(flags) }); return fd; },
    closeSync(fd) { fds.delete(fd); },
    readSync(fd, buf, off = 0, len = buf.length - off, pos) { const f = fds.get(fd); const data = fs.readFileSync(f.path); const start = pos == null ? f.pos : pos; const n = Math.max(0, Math.min(len, data.length - start)); buf.set(data.subarray(start, start + n), off); if (pos == null) f.pos += n; return n; },
    writeSync(fd, data, a, b, c) { const f = fds.get(fd); const chunk = typeof data === "string" ? Buffer.from(data, typeof a === "string" ? a : "utf8") : Buffer.from(data).subarray(a || 0, a != null && b != null ? a + b : undefined); fs.writeFileSync(f.path, chunk, { flag: f.flags.includes("a") || f.pos > 0 || f.written ? "a" : "w" }); f.written = true; f.pos += chunk.length; return chunk.length; },
    fstatSync(fd) { return fs.statSync(fds.get(fd).path); },
    watch() { const EE = require("events"); const w = new EE(); w.close = () => {}; w.ref = w.unref = () => w; return w; },
    watchFile() {}, unwatchFile() {},
    createReadStream(p, o = {}) { const { Readable } = require("stream"); const a = abs(p); let sent = false; const r = new Readable({ read() { if (sent) return; sent = true; try { let data = fs.readFileSync(a); if (o.start != null || o.end != null) data = data.subarray(o.start || 0, o.end != null ? o.end + 1 : undefined); if (o.encoding) this.setEncoding(o.encoding); this.push(data); this.push(null); queueMicrotask(() => this.emit("open"), this.emit("ready")); } catch (e) { this.destroy(e); } } }); r.path = a; r.bytesRead = 0; r.close = (cb) => { r.destroy(); if (cb) cb(); }; return r; },
    createWriteStream(p, o = {}) { const { Writable } = require("stream"); const a = abs(p); let first = !(o.flags && o.flags.startsWith("a")); const w = new Writable({ write(c, e, cb) { try { fs.writeFileSync(a, c, { flag: first ? "w" : "a" }); first = false; cb(); } catch (err) { cb(err); } } }); if (first) { try { fs.writeFileSync(a, ""); } catch {} first = false; } w.path = a; w.bytesWritten = 0; w.close = (cb) => w.end(cb); queueMicrotask(() => { w.emit("open"); w.emit("ready"); }); return w; },
    Stats, Dirent,
  };
  const fds = new Map(); let fdSeq = 20;
  const cbify = (name) => (...a) => { const cb = a.pop(); queueMicrotask(() => { try { cb(null, fs[name + "Sync"](...a)); } catch (e) { cb(e); } }); };
  for (const n of ["readFile", "writeFile", "appendFile", "stat", "lstat", "readdir", "mkdir", "rm", "rmdir", "unlink", "rename", "copyFile", "cp", "realpath", "access", "chmod", "symlink", "readlink", "mkdtemp", "truncate", "utimes", "chown", "open", "close", "read", "write", "fstat"]) fs[n] = cbify(n);
  fs.exists = (p, cb) => queueMicrotask(() => cb(fs.existsSync(p)));
  const promises = {};
  for (const n of ["readFile", "writeFile", "appendFile", "stat", "lstat", "readdir", "mkdir", "rm", "rmdir", "unlink", "rename", "copyFile", "cp", "realpath", "access", "chmod", "symlink", "readlink", "mkdtemp", "truncate", "utimes", "chown"]) promises[n] = async (...a) => fs[n + "Sync"](...a);
  promises.open = async (p, flags) => { const fd = fs.openSync(p, flags); return { fd, readFile: async (o) => fs.readFileSync(fds.get(fd).path, o), writeFile: async (d) => fs.writeFileSync(fds.get(fd).path, d), close: async () => fs.closeSync(fd), stat: async () => fs.fstatSync(fd), write: async (d) => ({ bytesWritten: fs.writeSync(fd, d) }), read: async (b, o, l, p2) => ({ bytesRead: fs.readSync(fd, b, o, l, p2), buffer: b }), createReadStream: (o) => fs.createReadStream(fds.get(fd).path, o), createWriteStream: (o) => fs.createWriteStream(fds.get(fd).path, o) }; };
  promises.constants = fs.constants;
  promises.watch = async function* () {};
  fs.promises = promises;
  module.exports = fs;
});
__nodeDefine("fs/promises", (module, exports, require) => { module.exports = require("fs").promises; });
