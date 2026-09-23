__nodeDefine("fs", (module, exports, require) => {
  const H = globalThis.__odete, path = require("path");
  const caminho = (p) => {
    if (p instanceof URL) p = decodeURIComponent(p.pathname);
    else if (typeof p === "string" && p.startsWith("file://")) p = decodeURIComponent(new URL(p).pathname);
    else if (p instanceof Uint8Array) p = globalThis.__utf8.decode(p);
    if (typeof p !== "string") throw Object.assign(new TypeError('The "path" argument must be of type string or an instance of Buffer or URL. Received ' + (p === null ? "null" : typeof p)), { code: "ERR_INVALID_ARG_TYPE" });
    return p;
  };
  const abs = (p) => { p = caminho(p); return path.isAbsolute(p) ? p : path.resolve(p); };
  const ERRNO = { EPERM: -1, ENOENT: -2, EIO: -5, EBADF: -9, EACCES: -13, EEXIST: -17, EXDEV: -18, ENOTDIR: -20, EISDIR: -21, EINVAL: -22, EMFILE: -24, ENOSPC: -28, EROFS: -30, ELOOP: -62, ENAMETOOLONG: -63, ENOTEMPTY: -66, EINTR: -4 };
  function mkErr(r, syscall, dest) {
    const e = new Error(`${r.error}: ${r.message}, ${syscall}${r.path ? ` '${r.path}'` : ""}${dest ? ` -> '${dest}'` : ""}`);
    e.errno = ERRNO[r.error] ?? -5; e.code = r.error; e.syscall = syscall;
    if (r.path) e.path = r.path;
    if (dest) e.dest = dest;
    return e;
  }
  const check = (r, syscall, dest) => { if (r && typeof r === "object" && !Array.isArray(r) && r.error) throw mkErr(r, syscall, dest); return r; };
  const S_IFMT = 0o170000;
  class Stats {
    constructor(v) {
      [this.dev, this.ino, this.mode, this.nlink, this.uid, this.gid, this.rdev, this.size, this.blksize, this.blocks, this.atimeMs, this.mtimeMs, this.ctimeMs, this.birthtimeMs] = v;
      this.atime = new Date(this.atimeMs); this.mtime = new Date(this.mtimeMs); this.ctime = new Date(this.ctimeMs); this.birthtime = new Date(this.birthtimeMs);
    }
    isFile() { return (this.mode & S_IFMT) === 0o100000; } isDirectory() { return (this.mode & S_IFMT) === 0o040000; }
    isSymbolicLink() { return (this.mode & S_IFMT) === 0o120000; } isFIFO() { return (this.mode & S_IFMT) === 0o010000; }
    isSocket() { return (this.mode & S_IFMT) === 0o140000; } isBlockDevice() { return (this.mode & S_IFMT) === 0o060000; } isCharacterDevice() { return (this.mode & S_IFMT) === 0o020000; }
  }
  const TIPOS = ["outro", "arquivo", "pasta", "link"];
  class Dirent {
    constructor(name, tipo, parent) { this.name = name; this.parentPath = parent; this.path = parent; this._t = tipo; }
    isDirectory() { return this._t === 2; } isFile() { return this._t === 1; } isSymbolicLink() { return this._t === 3; }
    isFIFO() { return false; } isSocket() { return false; } isBlockDevice() { return false; } isCharacterDevice() { return false; }
  }
  const enc = (o) => (typeof o === "string" ? o : o && o.encoding) || null;
  const ehUtf8 = (e) => { e = String(e).toLowerCase(); return e === "utf8" || e === "utf-8"; };
  // Flags do `open` em O_* do Darwin (as constantes do Node no macOS têm estes valores).
  const O = { O_RDONLY: 0, O_WRONLY: 1, O_RDWR: 2, O_APPEND: 8, O_CREAT: 512, O_TRUNC: 1024, O_EXCL: 2048, O_SYNC: 128, O_NOFOLLOW: 256, O_DIRECTORY: 1048576 };
  function flags(f = "r") {
    if (typeof f === "number") return f;
    const tabela = { r: 0, rs: 0, sr: 0, "r+": 2, "rs+": 2, "sr+": 2, w: 1 | 512 | 1024, wx: 1 | 512 | 1024 | 2048, xw: 1 | 512 | 1024 | 2048, "w+": 2 | 512 | 1024, "wx+": 2 | 512 | 1024 | 2048, "xw+": 2 | 512 | 1024 | 2048, a: 1 | 8 | 512, ax: 1 | 8 | 512 | 2048, xa: 1 | 8 | 512 | 2048, as: 1 | 8 | 512, sa: 1 | 8 | 512, "a+": 2 | 8 | 512, "ax+": 2 | 8 | 512 | 2048, "xa+": 2 | 8 | 512 | 2048, "as+": 2 | 8 | 512, "sa+": 2 | 8 | 512 };
    const v = tabela[f];
    if (v === undefined) throw Object.assign(new TypeError(`The value "${f}" is invalid for option "flags"`), { code: "ERR_INVALID_ARG_VALUE" });
    return v;
  }
  const ehStdin = (p) => p === 0 || p === "/dev/stdin";
  const stdinBytes = () => globalThis.__comoBuffer(H.stdin() || new Uint8Array(0));
  // O `open` de verdade (POSIX), com o fd guardado pelo runtime e fechado quando o processo
  // termina. `readSync` lê direto na memória do buffer — antes relia o arquivo inteiro a cada
  // chamada.
  const fs = {
    constants: { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1, ...O, COPYFILE_EXCL: 1, COPYFILE_FICLONE: 2, COPYFILE_FICLONE_FORCE: 4, S_IFMT, S_IFREG: 0o100000, S_IFDIR: 0o040000, S_IFLNK: 0o120000, UV_FS_O_FILEMAP: 0 },
    // Caminho inválido é `false`, como no Node; a interrupção (Ctrl+C) passa.
    existsSync: (p) => { try { return H.exists(abs(p)); } catch (e) { if (e && e.__odeteExit) throw e; return false; } },
    readFileSync(p, o) {
      const e = enc(o);
      if (ehStdin(p)) { const b = stdinBytes(); return e && e !== "buffer" ? b.toString(e) : b; }
      if (typeof p === "number") { const st = fs.fstatSync(p); const b = Buffer.alloc(st.size); let n = 0, r; while ((r = fs.readSync(p, b, n, b.length - n, null)) > 0) n += r; return e && e !== "buffer" ? b.subarray(0, n).toString(e) : b.subarray(0, n); }
      const a = abs(p);
      if (e && ehUtf8(e)) return check(H.readText(a), "open");
      const b = globalThis.__comoBuffer(check(H.readBytes(a), "open"));
      return e && e !== "buffer" ? b.toString(e) : b;
    },
    writeFileSync(p, data, o) {
      if (typeof p === "number") { fs.writeSync(p, typeof data === "string" ? data : globalThis.__comoBytes(data)); return; }
      const a = abs(p); const flag = (o && o.flag) || "w"; const e = enc(o);
      if (String(flag).includes("x") && H.exists(a)) throw mkErr({ error: "EEXIST", message: "file already exists", path: a }, "open");
      const append = String(flag).startsWith("a");
      if (typeof data === "string" && (!e || ehUtf8(e))) check(H.writeText(a, data, append), "open");
      else check(H.writeBytes(a, globalThis.__comoBytes(data, e), append), "open");
      if (o && o.mode) H.chmod(a, typeof o.mode === "string" ? parseInt(o.mode, 8) : o.mode);
    },
    appendFileSync(p, data, o) { fs.writeFileSync(p, data, { ...(typeof o === "object" ? o : { encoding: o }), flag: "a" }); },
    statSync(p, o) { const r = H.statx(abs(p), true); if (r && r.error) { if (o && o.throwIfNoEntry === false) return undefined; throw mkErr(r, "stat"); } return new Stats(r); },
    lstatSync(p, o) { const r = H.statx(abs(p), false); if (r && r.error) { if (o && o.throwIfNoEntry === false) return undefined; throw mkErr(r, "lstat"); } return new Stats(r); },
    fstatSync(fd) { return new Stats(check(H.fstatx(fd), "fstat")); },
    readdirSync(p, o) {
      const a = abs(p);
      const tipos = !!(o && o.withFileTypes), rec = !!(o && o.recursive);
      if (!tipos && !rec) return check(H.readdir(a), "scandir");
      const out = [];
      const andar = (dir, pre) => {
        const [nomes, ts] = check(H.readdirTipos(dir), "scandir");
        for (let i = 0; i < nomes.length; i++) {
          out.push(tipos ? new Dirent(nomes[i], ts[i], dir) : pre + nomes[i]);
          if (rec && ts[i] === 2) andar(path.join(dir, nomes[i]), pre + nomes[i] + "/");
        }
      };
      andar(a, "");
      return out;
    },
    opendirSync(p) {
      const a = abs(p); const [nomes, ts] = check(H.readdirTipos(a), "opendir"); let i = 0;
      const dir = { path: a, readSync: () => (i < nomes.length ? new Dirent(nomes[i], ts[i++], a) : null), read: (cb) => { const d = dir.readSync(); if (cb) { queueMicrotask(() => cb(null, d)); return; } return Promise.resolve(d); }, closeSync() {}, close: (cb) => { if (cb) queueMicrotask(cb); else return Promise.resolve(); }, async *[Symbol.asyncIterator]() { let d; while ((d = dir.readSync())) yield d; }, *[Symbol.iterator]() { let d; while ((d = dir.readSync())) yield d; } };
      return dir;
    },
    mkdirSync(p, o) { const a = abs(p); const rec = !!(o && (o === true || o.recursive)); const modo = o && typeof o === "object" && o.mode ? (typeof o.mode === "string" ? parseInt(o.mode, 8) : o.mode) : 0; const r = check(H.mkdir(a, rec, modo), "mkdir"); return rec ? (typeof r === "string" ? r : undefined) : undefined; },
    rmSync(p, o = {}) { check(H.rm(abs(p), !!o.recursive, !!o.force), "rm"); },
    rmdirSync(p, o = {}) { const a = abs(p); const st = fs.lstatSync(a, { throwIfNoEntry: false }); if (st && !st.isDirectory()) throw mkErr({ error: "ENOTDIR", message: "not a directory", path: a }, "rmdir"); check(H.rm(a, !!o.recursive, false), "rmdir"); },
    unlinkSync(p) { const a = abs(p); const st = fs.lstatSync(a, { throwIfNoEntry: false }); if (st && st.isDirectory()) throw mkErr({ error: "EPERM", message: "operation not permitted", path: a }, "unlink"); check(H.rm(a, false, false), "unlink"); },
    renameSync(a, b) { check(H.rename(abs(a), abs(b)), "rename", abs(b)); },
    copyFileSync(a, b, mode) { if (mode & 1 && H.exists(abs(b))) throw mkErr({ error: "EEXIST", message: "file already exists", path: abs(b) }, "copyfile"); check(H.copy(abs(a), abs(b)), "copyfile", abs(b)); },
    cpSync(a, b, o = {}) {
      const d = abs(b);
      if (o.errorOnExist && o.force === false && H.exists(d)) throw mkErr({ error: "EEXIST", message: "file already exists", path: d }, "cp");
      const r = H.cp(abs(a), d, !!o.recursive, o.force !== false);
      if (r && r.error) { const e = mkErr(r, "cp"); if (r.error === "ERR_FS_EISDIR") e.message = `Recursive option is required to copy a directory: ${abs(a)}`; throw e; }
    },
    realpathSync: Object.assign((p) => check(H.realpath(abs(p)), "realpath"), { native: (p) => check(H.realpath(abs(p)), "realpath") }),
    accessSync(p, mode = 0) { check(H.access(abs(p), mode), "access"); },
    chmodSync(p, m) { check(H.chmod(abs(p), typeof m === "string" ? parseInt(m, 8) : m), "chmod"); },
    lchmodSync() {},
    symlinkSync(t, p) { check(H.symlink(caminho(t), abs(p)), "symlink", caminho(t)); },
    linkSync(a, b) { fs.copyFileSync(a, b); },
    readlinkSync(p, o) { const r = check(H.readlink(abs(p)), "readlink"); return enc(o) === "buffer" ? Buffer.from(r) : r; },
    mkdtempSync(prefix) { return check(H.mkdtemp(abs(prefix)), "mkdtemp"); },
    truncateSync(p, len = 0) { if (typeof p === "number") return fs.ftruncateSync(p, len); check(H.truncate(abs(p), len), "open"); },
    ftruncateSync(fd, len = 0) { check(H.ftruncar(fd, len), "ftruncate"); },
    utimesSync(p, at, mt) { const t = (x) => (x instanceof Date ? x.getTime() / 1000 : typeof x === "string" ? Number(x) : x); check(H.utimes(abs(p), t(at), t(mt)), "utime"); },
    lutimesSync() {}, futimesSync() {}, chownSync() {}, lchownSync() {}, fchownSync() {}, fchmodSync() {}, fsyncSync() {}, fdatasyncSync() {},
    openSync(p, f = "r", modo) { return check(H.abrir(abs(p), flags(f), typeof modo === "string" ? parseInt(modo, 8) : modo || 0o666), "open"); },
    closeSync(fd) { check(H.fechar(fd), "close"); },
    readSync(fd, buf, off, len, pos) {
      if (off !== null && typeof off === "object" && !ArrayBuffer.isView(off)) { ({ offset: off = 0, length: len = buf.byteLength - off, position: pos = null } = off); }
      off = off || 0; if (len === undefined) len = buf.byteLength - off;
      if (fd === 0) { const b = stdinBytes(); const n = Math.min(len, b.length - (fs._stdinPos || 0)); if (n <= 0) return 0; buf.set(b.subarray(fs._stdinPos || 0, (fs._stdinPos || 0) + n), off); fs._stdinPos = (fs._stdinPos || 0) + n; return n; }
      const vista = new Uint8Array(buf.buffer, buf.byteOffset + off, Math.max(0, Math.min(len, buf.byteLength - off)));
      return check(H.lerFd(fd, vista, pos == null ? -1 : Number(pos)), "read");
    },
    writeSync(fd, data, a, b, c) {
      if (fd === 1 || fd === 2) { H.writeRaw(fd, typeof data === "string" ? data : globalThis.__comoBytes(data)); return typeof data === "string" ? globalThis.__utf8.byteLength(data) : data.byteLength; }
      let bytes, pos;
      if (typeof data === "string") { bytes = globalThis.__comoBytes(data, typeof b === "string" ? b : "utf8"); pos = typeof a === "number" ? a : null; }
      else { const u = globalThis.__comoBytes(data); const off = a || 0; const len = b ?? u.length - off; bytes = u.subarray(off, off + len); pos = c; }
      return check(H.escreverFd(fd, bytes, pos == null ? -1 : Number(pos)), "write");
    },
    watch() { const EE = require("events"); const w = new EE(); w.close = () => {}; w.ref = w.unref = () => w; return w; },
    watchFile() {}, unwatchFile() {},
    createReadStream(p, o = {}) {
      if (typeof o === "string") o = { encoding: o };
      const { Readable } = require("stream");
      const a = o.fd != null ? null : abs(p);
      let fd = o.fd ?? null, pos = o.start ?? null;
      const fim = o.end ?? Infinity, tam = o.highWaterMark || 65536;
      const r = new Readable({
        highWaterMark: tam,
        read() {
          try {
            if (fd === null) { fd = fs.openSync(a, o.flags || "r"); this.emit("open", fd); this.emit("ready"); }
            const quer = Math.min(tam, fim === Infinity ? tam : fim - (pos ?? r.bytesRead) + 1);
            if (quer <= 0) { this.push(null); return; }
            const b = Buffer.allocUnsafe(quer);
            const n = fs.readSync(fd, b, 0, quer, pos);
            if (pos !== null) pos += n;
            r.bytesRead += n;
            if (n === 0) { this.push(null); return; }
            this.push(n < quer ? b.subarray(0, n) : b);
          } catch (e) { this.destroy(e); }
        },
        destroy(err, cb) { if (fd !== null && o.autoClose !== false) { try { fs.closeSync(fd); } catch {} fd = null; } cb(err); },
      });
      if (o.encoding) r.setEncoding(o.encoding);
      r.on("end", () => { if (fd !== null && o.autoClose !== false) { try { fs.closeSync(fd); } catch {} fd = null; } });
      r.path = a; r.bytesRead = 0; r.pending = true; r.close = (cb) => { r.destroy(); if (cb) queueMicrotask(cb); };
      return r;
    },
    createWriteStream(p, o = {}) {
      if (typeof o === "string") o = { encoding: o };
      const { Writable } = require("stream");
      const a = o.fd != null ? null : abs(p);
      let fd = o.fd ?? null;
      const w = new Writable({
        write(c, e, cb) { try { if (fd === null) fd = fs.openSync(a, o.flags || "w", o.mode); const n = fs.writeSync(fd, c); w.bytesWritten += n; cb(); } catch (err) { cb(err); } },
        final(cb) { if (fd !== null && o.autoClose !== false) { try { fs.closeSync(fd); } catch {} fd = null; } cb(); },
        destroy(err, cb) { if (fd !== null) { try { fs.closeSync(fd); } catch {} fd = null; } cb(err); },
      });
      try { fd = fd ?? fs.openSync(a, o.flags || "w", o.mode); queueMicrotask(() => { w.emit("open", fd); w.emit("ready"); }); } catch (e) { queueMicrotask(() => w.destroy(e)); }
      w.path = a; w.bytesWritten = 0; w.pending = false; w.close = (cb) => w.end(cb);
      return w;
    },
    Stats, Dirent,
  };
  // Versões com callback: rodam o síncrono numa microtarefa (o disco do iPad é rápido e o JS
  // é uma thread só de qualquer jeito).
  const cbify = (name) => (...a) => { const cb = typeof a[a.length - 1] === "function" ? a.pop() : null; queueMicrotask(() => { let r, e = null; try { r = fs[name + "Sync"](...a); } catch (x) { e = x; } if (cb) { if (name === "read" && !e) cb(null, r, a[1]); else if (name === "write" && !e) cb(null, r, a[1]); else cb(e, r); } }); };
  const NOMES = ["readFile", "writeFile", "appendFile", "stat", "lstat", "fstat", "readdir", "opendir", "mkdir", "rm", "rmdir", "unlink", "rename", "copyFile", "cp", "realpath", "access", "chmod", "lchmod", "symlink", "link", "readlink", "mkdtemp", "truncate", "ftruncate", "utimes", "lutimes", "futimes", "chown", "lchown", "fchown", "fchmod", "fsync", "fdatasync", "open", "close", "read", "write"];
  for (const n of NOMES) fs[n] = cbify(n);
  fs.realpath.native = fs.realpath;
  fs.exists = (p, cb) => queueMicrotask(() => cb(fs.existsSync(p)));
  fs.readv = (fd, bufs, pos, cb) => { if (typeof pos === "function") { cb = pos; pos = null; } queueMicrotask(() => { try { cb(null, fs.readvSync(fd, bufs, pos), bufs); } catch (e) { cb(e); } }); };
  fs.readvSync = (fd, bufs, pos = null) => { let t = 0; for (const b of bufs) { const n = fs.readSync(fd, b, 0, b.byteLength, pos == null ? null : pos + t); t += n; if (n < b.byteLength) break; } return t; };
  fs.writevSync = (fd, bufs, pos = null) => { let t = 0; for (const b of bufs) t += fs.writeSync(fd, b, 0, b.byteLength, pos == null ? null : pos + t); return t; };
  // Promessas pela Promise do processo (a que avisa rejeição não tratada), não `async`.
  const pr = (n) => (...a) => new Promise((res, rej) => { try { res(fs[n + "Sync"](...a)); } catch (e) { rej(e); } });
  const promises = {};
  for (const n of ["readFile", "writeFile", "appendFile", "stat", "lstat", "readdir", "opendir", "mkdir", "rm", "rmdir", "unlink", "rename", "copyFile", "cp", "realpath", "access", "chmod", "lchmod", "symlink", "link", "readlink", "mkdtemp", "truncate", "utimes", "lutimes", "chown", "lchown"]) promises[n] = pr(n);
  class FileHandle {
    constructor(fd) { this.fd = fd; }
    readFile(o) { return pr("readFile")(this.fd, o); } writeFile(d, o) { return pr("writeFile")(this.fd, d, o); } appendFile(d, o) { return pr("writeFile")(this.fd, d, o); }
    stat() { return pr("fstat")(this.fd); } truncate(len) { return pr("ftruncate")(this.fd, len); } sync() { return Promise.resolve(); } datasync() { return Promise.resolve(); }
    close() { return pr("close")(this.fd); } chmod() { return Promise.resolve(); } chown() { return Promise.resolve(); } utimes() { return Promise.resolve(); }
    read(b, o, l, p) { if (b && !ArrayBuffer.isView(b)) { ({ buffer: b = Buffer.alloc(16384), offset: o = 0, length: l = b.byteLength, position: p = null } = b); } b = b || Buffer.alloc(16384); return new Promise((res, rej) => { try { res({ bytesRead: fs.readSync(this.fd, b, o || 0, l ?? b.byteLength, p), buffer: b }); } catch (e) { rej(e); } }); }
    write(d, a, b, c) { return new Promise((res, rej) => { try { res({ bytesWritten: fs.writeSync(this.fd, d, a, b, c), buffer: d }); } catch (e) { rej(e); } }); }
    readLines(o) { return require("readline").createInterface({ input: this.createReadStream(o), crlfDelay: Infinity }); }
    createReadStream(o = {}) { return fs.createReadStream(null, { ...o, fd: this.fd }); } createWriteStream(o = {}) { return fs.createWriteStream(null, { ...o, fd: this.fd }); }
    [Symbol.asyncDispose || Symbol.for("asyncDispose")]() { return this.close(); }
  }
  promises.open = (p, f, m) => new Promise((res, rej) => { try { res(new FileHandle(fs.openSync(p, f, m))); } catch (e) { rej(e); } });
  promises.constants = fs.constants;
  promises.watch = async function* () {};
  fs.promises = promises;
  module.exports = fs;
});
__nodeDefine("fs/promises", (module, exports, require) => { module.exports = require("fs").promises; });
