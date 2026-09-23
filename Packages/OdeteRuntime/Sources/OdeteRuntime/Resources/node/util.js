__nodeDefine("util", (module, exports, require) => {
  const custom = Symbol.for("nodejs.util.inspect.custom");
  function inspect(v, opts = {}, depth = 0, seen = new Set()) {
    const max = opts.depth ?? 2;
    if (v === null) return "null";
    if (v === undefined) return "undefined";
    if (typeof v === "string") return depth === 0 ? v : JSON.stringify(v).replace(/^"|"$/g, "'");
    if (typeof v === "number" || typeof v === "boolean" || typeof v === "bigint") return String(v) + (typeof v === "bigint" ? "n" : "");
    if (typeof v === "symbol") return v.toString();
    if (typeof v === "function") return `[${v.constructor && v.constructor.name === "AsyncFunction" ? "AsyncFunction" : "Function"}${v.name ? ": " + v.name : " (anonymous)"}]`;
    // A pilha do JSC não começa por "Nome: mensagem" como a do V8: só a pilha, e a mensagem
    // sumia de todo console.error(e) (o "Startup Error" do vitest saía sem dizer qual erro).
    if (v instanceof Error) return globalThis.__formatError(v);
    if (v instanceof Date) return isNaN(v) ? "Invalid Date" : v.toISOString();
    if (v instanceof RegExp) return v.toString();
    if (v instanceof Promise) return "Promise { <pending> }";
    if (typeof v[custom] === "function") return v[custom](max - depth, opts);
    if (seen.has(v)) return "[Circular *1]";
    if (depth > max) return Array.isArray(v) ? "[Array]" : "[Object]";
    seen.add(v);
    const inner = (x) => inspect(x, opts, depth + 1, seen);
    let out;
    if (Array.isArray(v)) { const items = v.slice(0, 100).map(inner); if (v.length > 100) items.push(`... ${v.length - 100} more items`); out = "[ " + items.join(", ") + " ]"; if (!v.length) out = "[]"; }
    else if (v instanceof Map) out = `Map(${v.size}) { ` + [...v].map(([k, x]) => inner(k) + " => " + inner(x)).join(", ") + " }";
    else if (v instanceof Set) out = `Set(${v.size}) { ` + [...v].map(inner).join(", ") + " }";
    else if (ArrayBuffer.isView(v)) out = `${v.constructor.name}(${v.length}) [ ${Array.from(v.subarray ? v.subarray(0, 50) : v).join(", ")} ]`;
    else if (v instanceof ArrayBuffer) out = `ArrayBuffer { byteLength: ${v.byteLength} }`;
    else {
      const keys = Object.keys(v);
      const name = v.constructor && v.constructor !== Object && v.constructor.name ? v.constructor.name + " " : "";
      if (!keys.length) out = name ? name + "{}" : "{}";
      else { const body = keys.map((k) => (/^[a-zA-Z_$][\w$]*$/.test(k) ? k : JSON.stringify(k)) + ": " + inner(v[k])).join(", "); out = name + "{ " + body + " }"; }
    }
    seen.delete(v);
    if (out.length > 76 && depth < max) out = out.replace(/, /g, ",\n" + "  ".repeat(depth + 1)).replace(/\{ /, "{\n" + "  ".repeat(depth + 1)).replace(/ \}$/, "\n" + "  ".repeat(depth) + "}").replace(/\[ /, "[\n" + "  ".repeat(depth + 1)).replace(/ \]$/, "\n" + "  ".repeat(depth) + "]");
    return out;
  }
  function format(f, ...args) {
    // `console.log()` é uma linha vazia, não "undefined".
    if (arguments.length === 0) return "";
    if (typeof f !== "string") return [f, ...args].map((a) => (typeof a === "string" ? a : inspect(a))).join(" ");
    let i = 0;
    let s = f.replace(/%[sdifjoOc%]/g, (m) => {
      if (m === "%%") return "%";
      if (i >= args.length) return m;
      const a = args[i++];
      switch (m) { case "%s": return typeof a === "string" ? a : inspect(a, { depth: 1 }); case "%d": case "%i": return String(parseInt(a)); case "%f": return String(parseFloat(a)); case "%j": try { return JSON.stringify(a); } catch { return "[Circular]"; } case "%c": return ""; default: return inspect(a); }
    });
    for (; i < args.length; i++) s += " " + (typeof args[i] === "string" ? args[i] : inspect(args[i]));
    return s;
  }
  const promisify = (fn) => { if (fn[promisify.custom]) return fn[promisify.custom]; return (...a) => new Promise((res, rej) => fn(...a, (e, ...r) => (e ? rej(e) : res(r.length > 1 ? r : r[0])))); };
  promisify.custom = Symbol.for("nodejs.util.promisify.custom");
  const callbackify = (fn) => (...a) => { const cb = a.pop(); fn(...a).then((r) => cb(null, r), (e) => cb(e)); };
  const types = { isPromise: (v) => v instanceof Promise, isDate: (v) => v instanceof Date, isRegExp: (v) => v instanceof RegExp, isUint8Array: (v) => v instanceof Uint8Array, isArrayBuffer: (v) => v instanceof ArrayBuffer, isAnyArrayBuffer: (v) => v instanceof ArrayBuffer, isTypedArray: (v) => ArrayBuffer.isView(v) && !(v instanceof DataView), isMap: (v) => v instanceof Map, isSet: (v) => v instanceof Set, isNativeError: (v) => v instanceof Error, isAsyncFunction: (v) => typeof v === "function" && v.constructor.name === "AsyncFunction", isBoxedPrimitive: () => false, isProxy: () => false, isGeneratorFunction: (v) => typeof v === "function" && v.constructor.name === "GeneratorFunction" };
  class TextEncoderU extends globalThis.TextEncoder {}
  module.exports = {
    inspect, format, formatWithOptions: (o, ...a) => format(...a), promisify, callbackify, types,
    inherits(ctor, sup) { Object.setPrototypeOf(ctor.prototype, sup.prototype); ctor.super_ = sup; },
    deprecate: (fn, msg) => { let warned = false; return function (...a) { if (!warned) { warned = true; console.warn("DeprecationWarning: " + msg); } return fn.apply(this, a); }; },
    isDeepStrictEqual: (a, b) => { try { require("assert").deepStrictEqual(a, b); return true; } catch { return false; } },
    isArray: Array.isArray, isString: (v) => typeof v === "string", isNumber: (v) => typeof v === "number", isFunction: (v) => typeof v === "function", isObject: (v) => v !== null && typeof v === "object", isUndefined: (v) => v === undefined, isNull: (v) => v === null, isBoolean: (v) => typeof v === "boolean", isError: (v) => v instanceof Error, isRegExp: (v) => v instanceof RegExp, isDate: (v) => v instanceof Date, isPrimitive: (v) => v === null || (typeof v !== "object" && typeof v !== "function"), isBuffer: (v) => globalThis.Buffer && globalThis.Buffer.isBuffer(v),
    TextEncoder: globalThis.TextEncoder, TextDecoder: globalThis.TextDecoder,
    styleText: (_, t) => t, stripVTControlCharacters: (s) => s.replace(/\x1b\[[0-9;]*m/g, ""),
    parseArgs({ args = __nodeRequire("process").argv.slice(2), options = {}, allowPositionals = true } = {}) { const values = {}, positionals = []; for (let i = 0; i < args.length; i++) { const a = args[i]; if (a.startsWith("--")) { const [k, v] = a.slice(2).split("="); const o = options[k] || {}; if (o.type === "boolean" || (v === undefined && (!args[i + 1] || args[i + 1].startsWith("-")))) values[k] = true; else values[k] = v !== undefined ? v : args[++i]; } else if (a.startsWith("-") && a.length > 1) { for (const ch of a.slice(1)) { const k = Object.keys(options).find((n) => options[n].short === ch) || ch; values[k] = true; } } else positionals.push(a); } return { values, positionals }; },
    debuglog: () => Object.assign(() => {}, { enabled: false }), debug: () => Object.assign(() => {}, { enabled: false }),
    // O parser do `.env` do Node (process.loadEnvFile, --env-file): KEY=valor, aspas, # comentário.
    parseEnv(texto) { const out = {}; for (const linha of String(texto).split(/\r?\n/)) { const m = /^\s*(?:export\s+)?([\w.-]+)\s*=\s*(.*)?\s*$/.exec(linha); if (!m) continue; let v = (m[2] || "").trim(); const q = v[0]; if ((q === '"' || q === "'" || q === "`") && v.endsWith(q) && v.length > 1) { v = v.slice(1, -1); if (q === '"') v = v.replace(/\\n/g, "\n"); } else { const h = v.indexOf(" #"); if (h >= 0) v = v.slice(0, h).trim(); } out[m[1]] = v; } return out; },
    getSystemErrorName: (n) => "E" + n, toUSVString: (s) => String(s), aborted: (signal) => new Promise((r) => signal.addEventListener("abort", r)),
  };
  module.exports.inspect.custom = custom;
  module.exports.inspect.defaultOptions = { depth: 2 };
});
