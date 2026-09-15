__nodeDefine("buffer", (module) => {
  const utf8 = globalThis.__utf8, b64 = globalThis.__b64;
  const encodings = ["utf8", "utf-8", "ascii", "latin1", "binary", "base64", "base64url", "hex", "ucs2", "ucs-2", "utf16le", "utf-16le"];
  function norm(enc) { return String(enc || "utf8").toLowerCase().replace("-", ""); }
  function bytesFrom(str, enc) {
    switch (norm(enc)) {
      case "utf8": return utf8.encode(str);
      case "ascii": case "latin1": case "binary": return Uint8Array.from(str, (c) => c.charCodeAt(0) & 255);
      case "base64": return b64.dec(str);
      case "base64url": return b64.dec(str.replace(/-/g, "+").replace(/_/g, "/"));
      case "hex": { const out = new Uint8Array(str.length >> 1); for (let i = 0; i < out.length; i++) out[i] = parseInt(str.substr(i * 2, 2), 16); return out; }
      case "ucs2": case "utf16le": { const out = new Uint8Array(str.length * 2); for (let i = 0; i < str.length; i++) { const c = str.charCodeAt(i); out[i * 2] = c & 255; out[i * 2 + 1] = c >> 8; } return out; }
      default: throw new TypeError("Unknown encoding: " + enc);
    }
  }
  function strFrom(bytes, enc) {
    switch (norm(enc)) {
      case "utf8": return utf8.decode(bytes);
      case "ascii": case "latin1": case "binary": return Array.from(bytes, (b) => String.fromCharCode(b)).join("");
      case "base64": return b64.enc(bytes);
      case "base64url": return b64.enc(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
      case "hex": return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
      case "ucs2": case "utf16le": { let s = ""; for (let i = 0; i + 1 < bytes.length; i += 2) s += String.fromCharCode(bytes[i] | (bytes[i + 1] << 8)); return s; }
      default: throw new TypeError("Unknown encoding: " + enc);
    }
  }
  class Buffer extends Uint8Array {
    static from(v, enc, len) {
      if (typeof v === "string") return wrap(bytesFrom(v, enc));
      if (v instanceof ArrayBuffer) return wrap(new Uint8Array(v, enc || 0, len));
      if (ArrayBuffer.isView(v)) return wrap(new Uint8Array(v.buffer, v.byteOffset, v.byteLength).slice());
      if (Array.isArray(v)) return wrap(Uint8Array.from(v));
      if (v && v.type === "Buffer" && Array.isArray(v.data)) return wrap(Uint8Array.from(v.data));
      throw new TypeError("Buffer.from: tipo não suportado");
    }
    static alloc(n, fill = 0, enc) { const b = wrap(new Uint8Array(n)); if (fill !== 0) b.fill(fill, 0, n, enc); return b; }
    static allocUnsafe(n) { return wrap(new Uint8Array(n)); }
    static allocUnsafeSlow(n) { return wrap(new Uint8Array(n)); }
    static isBuffer(b) { return b instanceof Buffer; }
    static isEncoding(e) { return encodings.includes(String(e).toLowerCase()); }
    static byteLength(s, enc) { return typeof s === "string" ? bytesFrom(s, enc).length : s.byteLength; }
    static concat(list, total) { const len = total ?? list.reduce((a, b) => a + b.length, 0); const out = Buffer.alloc(len); let o = 0; for (const b of list) { out.set(b.subarray(0, Math.min(b.length, len - o)), o); o += b.length; if (o >= len) break; } return out; }
    static compare(a, b) { return a.compare(b); }
    toString(enc, start = 0, end = this.length) { return strFrom(this.subarray(start, end), enc); }
    toJSON() { return { type: "Buffer", data: Array.from(this) }; }
    equals(o) { if (o.length !== this.length) return false; for (let i = 0; i < this.length; i++) if (this[i] !== o[i]) return false; return true; }
    compare(o) { const n = Math.min(this.length, o.length); for (let i = 0; i < n; i++) if (this[i] !== o[i]) return this[i] < o[i] ? -1 : 1; return this.length === o.length ? 0 : this.length < o.length ? -1 : 1; }
    slice(s, e) { return this.subarray(s, e); }
    subarray(s, e) { return wrap(Uint8Array.prototype.subarray.call(this, s, e)); }
    write(str, offset = 0, length, enc) { if (typeof offset === "string") { enc = offset; offset = 0; } if (typeof length === "string") { enc = length; length = undefined; } const b = bytesFrom(str, enc); const n = Math.min(b.length, length ?? this.length - offset, this.length - offset); this.set(b.subarray(0, n), offset); return n; }
    fill(v, s = 0, e = this.length, enc) { if (typeof v === "string") { const b = bytesFrom(v, enc); if (!b.length) return this; for (let i = s; i < e; i++) this[i] = b[(i - s) % b.length]; return this; } Uint8Array.prototype.fill.call(this, v, s, e); return this; }
    indexOf(v, from = 0, enc) { const b = typeof v === "number" ? Uint8Array.of(v) : typeof v === "string" ? bytesFrom(v, enc) : v; outer: for (let i = from; i <= this.length - b.length; i++) { for (let j = 0; j < b.length; j++) if (this[i + j] !== b[j]) continue outer; return i; } return -1; }
    lastIndexOf(v, from, enc) { const b = typeof v === "number" ? Uint8Array.of(v) : typeof v === "string" ? bytesFrom(v, enc) : v; for (let i = Math.min(from ?? this.length, this.length - b.length); i >= 0; i--) { let ok = true; for (let j = 0; j < b.length; j++) if (this[i + j] !== b[j]) { ok = false; break; } if (ok) return i; } return -1; }
    includes(v, from, enc) { return this.indexOf(v, from, enc) !== -1; }
    copy(target, tStart = 0, sStart = 0, sEnd = this.length) { const n = Math.min(sEnd - sStart, target.length - tStart); target.set(this.subarray(sStart, sStart + n), tStart); return n; }
    readUInt8(o = 0) { return this[o]; } readInt8(o = 0) { return (this[o] << 24) >> 24; }
    readUInt16LE(o = 0) { return this[o] | (this[o + 1] << 8); } readUInt16BE(o = 0) { return (this[o] << 8) | this[o + 1]; }
    readInt16LE(o = 0) { return (this.readUInt16LE(o) << 16) >> 16; } readInt16BE(o = 0) { return (this.readUInt16BE(o) << 16) >> 16; }
    readUInt32LE(o = 0) { return (this[o] | (this[o + 1] << 8) | (this[o + 2] << 16)) + this[o + 3] * 0x1000000; }
    readUInt32BE(o = 0) { return this[o] * 0x1000000 + ((this[o + 1] << 16) | (this[o + 2] << 8) | this[o + 3]); }
    readInt32LE(o = 0) { return this[o] | (this[o + 1] << 8) | (this[o + 2] << 16) | (this[o + 3] << 24); }
    readInt32BE(o = 0) { return (this[o] << 24) | (this[o + 1] << 16) | (this[o + 2] << 8) | this[o + 3]; }
    readDoubleLE(o = 0) { return new DataView(this.buffer, this.byteOffset).getFloat64(o, true); } readDoubleBE(o = 0) { return new DataView(this.buffer, this.byteOffset).getFloat64(o, false); }
    readFloatLE(o = 0) { return new DataView(this.buffer, this.byteOffset).getFloat32(o, true); } readFloatBE(o = 0) { return new DataView(this.buffer, this.byteOffset).getFloat32(o, false); }
    readBigUInt64LE(o = 0) { return new DataView(this.buffer, this.byteOffset).getBigUint64(o, true); } readBigInt64LE(o = 0) { return new DataView(this.buffer, this.byteOffset).getBigInt64(o, true); }
    writeUInt8(v, o = 0) { this[o] = v; return o + 1; } writeInt8(v, o = 0) { this[o] = v & 255; return o + 1; }
    writeUInt16LE(v, o = 0) { this[o] = v & 255; this[o + 1] = (v >> 8) & 255; return o + 2; } writeUInt16BE(v, o = 0) { this[o] = (v >> 8) & 255; this[o + 1] = v & 255; return o + 2; }
    writeInt16LE(v, o = 0) { return this.writeUInt16LE(v & 0xffff, o); } writeInt16BE(v, o = 0) { return this.writeUInt16BE(v & 0xffff, o); }
    writeUInt32LE(v, o = 0) { this[o] = v & 255; this[o + 1] = (v >>> 8) & 255; this[o + 2] = (v >>> 16) & 255; this[o + 3] = (v >>> 24) & 255; return o + 4; }
    writeUInt32BE(v, o = 0) { this[o] = (v >>> 24) & 255; this[o + 1] = (v >>> 16) & 255; this[o + 2] = (v >>> 8) & 255; this[o + 3] = v & 255; return o + 4; }
    writeInt32LE(v, o = 0) { return this.writeUInt32LE(v >>> 0, o); } writeInt32BE(v, o = 0) { return this.writeUInt32BE(v >>> 0, o); }
    writeDoubleLE(v, o = 0) { new DataView(this.buffer, this.byteOffset).setFloat64(o, v, true); return o + 8; } writeDoubleBE(v, o = 0) { new DataView(this.buffer, this.byteOffset).setFloat64(o, v, false); return o + 8; }
    writeFloatLE(v, o = 0) { new DataView(this.buffer, this.byteOffset).setFloat32(o, v, true); return o + 4; } writeFloatBE(v, o = 0) { new DataView(this.buffer, this.byteOffset).setFloat32(o, v, false); return o + 4; }
    swap16() { for (let i = 0; i + 1 < this.length; i += 2) { const t = this[i]; this[i] = this[i + 1]; this[i + 1] = t; } return this; }
    get parent() { return this.buffer; } get offset() { return this.byteOffset; }
    [Symbol.for("nodejs.util.inspect.custom")]() { return `<Buffer ${Array.from(this.subarray(0, 50), (b) => b.toString(16).padStart(2, "0")).join(" ")}${this.length > 50 ? " ... " + (this.length - 50) + " more bytes" : ""}>`; }
  }
  function wrap(u8) { return Object.setPrototypeOf(u8, Buffer.prototype); }
  Buffer.poolSize = 8192;
  globalThis.Buffer = Buffer;
  module.exports = { Buffer, kMaxLength: 2 ** 31 - 1, constants: { MAX_LENGTH: 2 ** 31 - 1, MAX_STRING_LENGTH: 2 ** 29 - 24 }, Blob: globalThis.Blob, SlowBuffer: Buffer, INSPECT_MAX_BYTES: 50 };
});
