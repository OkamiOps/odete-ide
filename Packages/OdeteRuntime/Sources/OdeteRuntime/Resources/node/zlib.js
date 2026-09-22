__nodeDefine("zlib", (module, exports, require) => {
  const H = globalThis.__odete;
  const run = (b, compress) => globalThis.__comoBuffer(H.gzipBytes(globalThis.__comoBytes(b), compress));
  const sync = { gzipSync: (b) => run(b, true), gunzipSync: (b) => run(b, false), deflateSync: (b) => run(b, true), inflateSync: (b) => run(b, false), unzipSync: (b) => run(b, false), brotliCompressSync: (b) => Buffer.from(b), brotliDecompressSync: (b) => Buffer.from(b), deflateRawSync: (b) => run(b, true), inflateRawSync: (b) => run(b, false) };
  const out = { ...sync, constants: { Z_NO_FLUSH: 0, Z_FINISH: 4, Z_BEST_COMPRESSION: 9, Z_DEFAULT_COMPRESSION: -1, BROTLI_OPERATION_PROCESS: 0 } };
  for (const k of Object.keys(sync)) { const n = k.replace("Sync", ""); out[n] = (b, o, cb) => { if (typeof o === "function") cb = o; queueMicrotask(() => { try { cb(null, sync[k](b)); } catch (e) { cb(e); } }); }; out["create" + n[0].toUpperCase() + n.slice(1)] = () => { const { Transform } = require("stream"); const chunks = []; return new Transform({ transform(c, e, cb) { chunks.push(c); cb(); }, flush(cb) { try { cb(null, sync[k](Buffer.concat(chunks))); } catch (e) { cb(e); } } }); }; }
  out.crc32 = (b) => { let c = 0xffffffff; for (const x of Buffer.from(b)) { c ^= x; for (let i = 0; i < 8; i++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; } return (c ^ 0xffffffff) >>> 0; };
  module.exports = out;
});
