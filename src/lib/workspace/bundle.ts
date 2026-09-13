import { transform } from "sucrase";
import type { FileMap } from "./types";

export function normalize(href: string) {
  return href
    .trim()
    .replace(/['"]/g, "")
    .replace(/[?#].*$/, "")
    .replace(/^\.\//, "")
    .replace(/^\/+/, "");
}

export function findFilePath(files: FileMap, href: string) {
  const clean = normalize(href);
  if (files[clean] !== undefined) return clean;
  const tries = [
    clean,
    `${clean}.js`,
    `${clean}.jsx`,
    `${clean}.ts`,
    `${clean}.tsx`,
    `${clean}.mjs`,
    `${clean}/index.js`,
    `${clean}/index.jsx`,
    `${clean}/index.ts`,
    `${clean}/index.tsx`,
  ];
  for (const t of tries) if (files[t] !== undefined) return t;
  const name = clean.split("/").pop() ?? clean;
  return Object.keys(files).find(
    (k) => !k.includes("node_modules/") && (k === name || k.endsWith(`/${name}`)),
  );
}

export function findFile(files: FileMap, href: string) {
  const key = findFilePath(files, href);
  return key ? files[key] : undefined;
}

export function transpile(path: string, code: string) {
  const ts = /\.tsx?$/.test(path);
  const jsx = /\.[jt]sx$/.test(path) || /<[A-Za-z/]/.test(code);
  if (!ts && !jsx) return code;
  try {
    const transforms: Array<"typescript" | "jsx"> = [];
    if (ts) transforms.push("typescript");
    if (jsx || ts) transforms.push("jsx");
    return transform(code, {
      transforms,
      jsxRuntime: "automatic",
      production: true,
      filePath: path,
    }).code;
  } catch {
    return code;
  }
}

function shimVite(code: string) {
  let out = code;
  out = out.replace(/^\s*import\s+['"][^'"]+\.(css|scss|sass|less)['"]\s*;?/gm, "");
  out = out.replace(
    /import\s+(\w+)\s+from\s+['"][^'"]+\.(css|scss|sass|less)['"]\s*;?/g,
    "const $1 = new Proxy({}, { get: () => '' });",
  );
  out = out.replace(
    /import\s+(\w+)\s+from\s+['"](\.[^'"]+\.(svg|png|jpg|jpeg|webp|gif))['"]\s*;?/g,
    'const $1 = "$2";',
  );
  if (out.includes("import.meta")) {
    out =
      `const import_meta = { env: { DEV: true, PROD: false, MODE: "development", BASE_URL: "/", SSR: false }, hot: { accept() {}, dispose() {} } };\n` +
      out.replaceAll("import.meta", "import_meta");
  }
  return out;
}

function resolveRel(from: string, spec: string) {
  let clean = spec.replace(/[?#].*$/, "");
  if (clean.startsWith("@/")) clean = `src/${clean.slice(2)}`;
  if (clean.startsWith("/")) return clean.replace(/^\/+/, "");
  const dir = from.includes("/") ? from.slice(0, from.lastIndexOf("/")) : "";
  const parts = `${dir}/${clean}`.split("/");
  const out: string[] = [];
  for (const p of parts) {
    if (!p || p === ".") continue;
    if (p === "..") out.pop();
    else out.push(p);
  }
  return out.join("/");
}

function resolveRelFile(from: string, spec: string, files: FileMap) {
  const rel = resolveRel(from, spec);
  return findFilePath(files, rel) ?? rel;
}

function rewriteLocals(from: string, code: string, files: FileMap, queue: string[]) {
  const rewrite = (q: string, spec: string) => {
    if (spec.startsWith("@/")) {
      const rel = resolveRelFile(from, spec, files);
      if (files[rel] !== undefined && !/\.(css|scss|sass|less)$/.test(rel)) queue.push(rel);
      return `from ${q}/${rel}${q}`;
    }
    if (spec.startsWith(".") || spec.startsWith("/")) {
      const rel = resolveRelFile(from, spec, files);
      if (/\.(css|scss|sass|less)$/.test(rel) || /\.(css|scss|sass|less)$/.test(spec)) {
        return `from ${q}data:text/javascript,export%20default%20{}${q}`;
      }
      if (files[rel] !== undefined) queue.push(rel);
      return `from ${q}/${rel}${q}`;
    }
    return `from ${q}${spec}${q}`;
  };
  let out = code.replace(/from\s+(['"])([^'"]+)\1/g, (_, q: string, spec: string) => rewrite(q, spec));
  out = out.replace(/import\s*\(\s*(['"])([^'"]+)\1\s*\)/g, (_, q: string, spec: string) => {
    if (!(spec.startsWith(".") || spec.startsWith("/") || spec.startsWith("@/"))) return `import(${q}${spec}${q})`;
    const rel = resolveRelFile(from, spec, files);
    if (files[rel] !== undefined) queue.push(rel);
    return `import(${q}/${rel}${q})`;
  });
  out = out.replace(/import\s+(['"])(\.[^'"]+|\/[^'"]+|@\/[^'"]+)\1/g, (_, q: string, spec: string) => {
    const rel = resolveRelFile(from, spec, files);
    if (/\.(css|scss|sass|less)$/.test(spec)) return "";
    if (files[rel] !== undefined) queue.push(rel);
    return `import ${q}/${rel}${q}`;
  });
  return out;
}

export function moduleSources(files: FileMap, entries: string[]) {
  const code: Record<string, string> = {};
  const queue = [...entries];
  const seen = new Set<string>();
  while (queue.length && seen.size < 250) {
    const p = queue.shift()!;
    if (seen.has(p) || files[p] === undefined) continue;
    seen.add(p);
    if (/\.(css|scss|sass|less)$/.test(p)) continue;
    let src = transpile(p, files[p]!);
    src = shimVite(src);
    src = rewriteLocals(p, src, files, queue);
    code[p] = src;
  }
  return code;
}

function localSpecifiers(code: string): string[] {
  const out: string[] = [];
  for (const m of code.matchAll(/(?:from|import)\s*\(?\s*['"]\/([^'"]+)['"]/g)) {
    if (m[1] && !out.includes(m[1])) out.push(m[1]);
  }
  return out;
}

export function rewriteBare(src: string, bare: Record<string, string>) {
  const map = (spec: string) => {
    if (
      spec.startsWith(".") ||
      spec.startsWith("/") ||
      spec.startsWith("data:") ||
      spec.startsWith("https:") ||
      spec.startsWith("http:")
    ) {
      return spec;
    }
    if (bare[spec]) return bare[spec]!;
    const node = spec.startsWith("node:") ? spec.slice(5) : spec;
    if (bare[node]) return bare[node]!;
    if (bare[`node:${node}`]) return bare[`node:${node}`]!;
    const root = spec.startsWith("@") ? spec.split("/").slice(0, 2).join("/") : spec.split("/")[0]!;
    if (bare[spec]) return bare[spec]!;
    if (bare[`${root}/`]) return `${bare[`${root}/`]}${spec.slice(root.length + 1)}`;
    if (bare[root] && spec !== root) {
      const base = bare[root]!.replace(/\/$/, "");
      return `${base}/${spec.slice(root.length + 1)}`;
    }
    if (bare[root]) return bare[root]!;
    return `https://esm.sh/${spec}`;
  };
  return src
    .replace(/from\s+(['"])([^'"]+)\1/g, (_, q: string, spec: string) => `from ${q}${map(spec)}${q}`)
    .replace(/import\s*\(\s*(['"])([^'"]+)\1\s*\)/g, (_, q: string, spec: string) => `import(${q}${map(spec)}${q})`);
}

export function linkDataUrls(code: Record<string, string>): Record<string, string> | null {
  const paths = Object.keys(code);
  const indeg: Record<string, number> = {};
  const adj: Record<string, string[]> = {};
  for (const p of paths) {
    indeg[p] = 0;
    adj[p] = [];
  }
  for (const p of paths) {
    for (const d of localSpecifiers(code[p]!)) {
      if (code[d] === undefined) continue;
      adj[d]!.push(p);
      indeg[p] = (indeg[p] ?? 0) + 1;
    }
  }
  const q = paths.filter((p) => (indeg[p] ?? 0) === 0);
  const order: string[] = [];
  while (q.length) {
    const p = q.shift()!;
    order.push(p);
    for (const n of adj[p] ?? []) {
      indeg[n]!--;
      if (indeg[n] === 0) q.push(n);
    }
  }
  if (order.length !== paths.length) return null;
  const urls: Record<string, string> = {};
  for (const p of order) {
    let src = code[p]!;
    src = src.replace(
      /(from\s+|import\s*\(\s*|import\s+)(['"])\/([^'"]+)\2/g,
      (m, pre: string, q: string, spec: string) => {
        const url = urls[spec];
        if (!url) return m;
        return `${pre}${q}${url}${q}`;
      },
    );
    urls[p] = `data:text/javascript;charset=utf-8,${encodeURIComponent(src)}`;
  }
  return urls;
}

export function localModules(files: FileMap, entries: string[]) {
  const imports: Record<string, string> = {};
  const code = moduleSources(files, entries);
  for (const [p, src] of Object.entries(code)) {
    const url = `data:text/javascript;charset=utf-8,${encodeURIComponent(src)}`;
    imports[`/${p}`] = url;
    imports[p] = url;
  }
  return imports;
}

export function compileToUrls(files: FileMap, entries: string[], bare: Record<string, string> = {}) {
  const code = moduleSources(files, entries);
  for (const p of Object.keys(code)) code[p] = rewriteBare(code[p]!, bare);
  return linkDataUrls(code);
}

export async function importData(url: string): Promise<Record<string, unknown>> {
  return (await import(/* @vite-ignore */ url)) as Record<string, unknown>;
}
