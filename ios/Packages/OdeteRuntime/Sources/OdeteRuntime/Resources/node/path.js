__nodeDefine("path", (module) => {
  function normalizeArray(parts, allowAbove) {
    const res = [];
    for (const p of parts) {
      if (!p || p === ".") continue;
      if (p === "..") { if (res.length && res[res.length - 1] !== "..") res.pop(); else if (allowAbove) res.push(".."); }
      else res.push(p);
    }
    return res;
  }
  const posix = {
    sep: "/", delimiter: ":",
    isAbsolute: (p) => p.startsWith("/"),
    normalize(p) { if (!p) return "."; const abs = p.startsWith("/"), trail = p.endsWith("/"); let r = normalizeArray(p.split("/"), !abs).join("/"); if (!r && !abs) r = "."; if (r && trail) r += "/"; return (abs ? "/" : "") + r; },
    join(...a) { return posix.normalize(a.filter((x) => x != null && x !== "").join("/")) || "."; },
    resolve(...a) { let r = "", abs = false; for (let i = a.length - 1; i >= -1 && !abs; i--) { const p = i >= 0 ? a[i] : __nodeRequire("process").cwd(); if (!p) continue; r = p + "/" + r; abs = p.startsWith("/"); } r = normalizeArray(r.split("/"), !abs).join("/"); return (abs ? "/" : "") + r || "."; },
    relative(from, to) { from = posix.resolve(from).split("/").filter(Boolean); to = posix.resolve(to).split("/").filter(Boolean); let i = 0; while (i < from.length && i < to.length && from[i] === to[i]) i++; return [...from.slice(i).map(() => ".."), ...to.slice(i)].join("/"); },
    dirname(p) { if (!p) return "."; const abs = p.startsWith("/"); const parts = p.replace(/\/+$/, "").split("/"); parts.pop(); const r = parts.join("/"); return r || (abs ? "/" : "."); },
    basename(p, ext) { let b = p.replace(/\/+$/, "").split("/").pop() || ""; if (ext && b.endsWith(ext) && b !== ext) b = b.slice(0, -ext.length); return b; },
    extname(p) { const b = posix.basename(p); const i = b.lastIndexOf("."); return i <= 0 ? "" : b.slice(i); },
    parse(p) { const root = p.startsWith("/") ? "/" : ""; const base = posix.basename(p); const ext = posix.extname(p); return { root, dir: posix.dirname(p) === "." && !p.includes("/") ? "" : posix.dirname(p), base, ext, name: ext ? base.slice(0, -ext.length) : base }; },
    format(o) { const dir = o.dir || o.root || ""; const base = o.base || (o.name || "") + (o.ext || ""); return dir ? (dir.endsWith("/") ? dir + base : dir + "/" + base) : base; },
    toNamespacedPath: (p) => p,
    matchesGlob: (p, g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*\*/g, ".*").replace(/\*/g, "[^/]*").replace(/\?/g, ".") + "$").test(p),
  };
  posix.posix = posix; posix.win32 = posix;
  module.exports = posix;
});
