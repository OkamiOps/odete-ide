export function parseTriple(v: string): [number, number, number] | null {
  const m = v.replace(/^v/, "").match(/^(\d+)\.(\d+)\.(\d+)/);
  if (!m) return null;
  return [Number(m[1]), Number(m[2]), Number(m[3])];
}

export function cmpVer(a: string, b: string) {
  const pa = parseTriple(a) || ([0, 0, 0] as [number, number, number]);
  const pb = parseTriple(b) || ([0, 0, 0] as [number, number, number]);
  for (let i = 0; i < 3; i++) if (pa[i] !== pb[i]) return pa[i]! - pb[i]!;
  const preA = a.includes("-");
  const preB = b.includes("-");
  if (preA && !preB) return -1;
  if (!preA && preB) return 1;
  return a.localeCompare(b);
}

export function satisfies(version: string, range: string): boolean {
  const v = parseTriple(version);
  if (!v) return false;
  if (version.includes("-") && !range.includes("-")) return false;
  const r = (range || "*").trim();
  if (!r || r === "*" || r === "x" || r === "latest") return true;
  if (/^(workspace|catalog|file|link|git|http):/.test(r)) return false;
  const body = r.replace(/^v/, "").replace(/^[\s]+/, "");

  function gte(a: [number, number, number], b: [number, number, number]) {
    return cmpVer(a.join("."), b.join(".")) >= 0;
  }
  function lt(a: [number, number, number], b: [number, number, number]) {
    return cmpVer(a.join("."), b.join(".")) < 0;
  }

  if (body.startsWith("^")) {
    const t = parseTriple(body.slice(1).trim());
    if (!t) return false;
    if (!gte(v, t)) return false;
    if (t[0] > 0) return lt(v, [t[0] + 1, 0, 0]);
    if (t[1] > 0) return lt(v, [0, t[1] + 1, 0]);
    return lt(v, [0, 0, t[2] + 1]);
  }
  if (body.startsWith("~")) {
    const t = parseTriple(body.slice(1).trim()) || parseTriple(`${body.slice(1).trim()}.0`);
    if (!t) {
      const m = body.slice(1).trim().match(/^(\d+)\.(\d+)/);
      if (!m) {
        const major = body.slice(1).trim().match(/^(\d+)$/);
        if (!major) return false;
        const n = Number(major[1]);
        return v[0] === n;
      }
      const minor: [number, number, number] = [Number(m[1]), Number(m[2]), 0];
      return gte(v, minor) && lt(v, [minor[0], minor[1] + 1, 0]);
    }
    return gte(v, t) && lt(v, [t[0], t[1] + 1, 0]);
  }
  if (body.startsWith(">=")) {
    const t = parseTriple(body.slice(2).trim());
    return t ? gte(v, t) : false;
  }
  if (/^\d+\.\d+\.\d+/.test(body)) {
    const t = parseTriple(body);
    return t ? v[0] === t[0] && v[1] === t[1] && v[2] === t[2] : false;
  }
  if (/^\d+\.\d+/.test(body)) {
    const m = body.match(/^(\d+)\.(\d+)/);
    if (!m) return false;
    return v[0] === Number(m[1]) && v[1] === Number(m[2]);
  }
  if (/^\d+$/.test(body)) return v[0] === Number(body);
  return true;
}

export function maxSatisfying(versions: string[], range: string): string | null {
  const ok = versions.filter((v) => satisfies(v, range)).sort(cmpVer);
  return ok[ok.length - 1] ?? null;
}
