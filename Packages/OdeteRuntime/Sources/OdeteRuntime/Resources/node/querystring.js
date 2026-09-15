__nodeDefine("querystring", (module) => {
  const esc = (s) => encodeURIComponent(s);
  const parse = (s = "", sep = "&", eq = "=") => { const out = {}; for (const part of String(s).split(sep)) { if (!part) continue; const i = part.indexOf(eq); const k = decodeURIComponent((i < 0 ? part : part.slice(0, i)).replace(/\+/g, " ")); const v = i < 0 ? "" : decodeURIComponent(part.slice(i + eq.length).replace(/\+/g, " ")); if (k in out) out[k] = [].concat(out[k], v); else out[k] = v; } return out; };
  const stringify = (o = {}, sep = "&", eq = "=") => Object.entries(o).flatMap(([k, v]) => (Array.isArray(v) ? v : [v]).map((x) => esc(k) + eq + esc(x == null ? "" : x))).join(sep);
  module.exports = { parse, stringify, decode: parse, encode: stringify, escape: esc, unescape: decodeURIComponent };
});
