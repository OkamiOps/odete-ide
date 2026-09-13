import { transform } from "sucrase";
import type { FileMap } from "./types";
import { detectStack, parsePkg, stackHint } from "./npm";
import { esmImports, lockOfFiles } from "./npm-lock";

function normalize(href: string) {
  return href
    .trim()
    .replace(/['"]/g, "")
    .replace(/[?#].*$/, "")
    .replace(/^\.\//, "")
    .replace(/^\/+/, "");
}

function findFilePath(files: FileMap, href: string) {
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
  const key = Object.keys(files).find(
    (k) => !k.includes("node_modules/") && (k === name || k.endsWith(`/${name}`)),
  );
  return key;
}

function findFile(files: FileMap, href: string) {
  const key = findFilePath(files, href);
  return key ? files[key] : undefined;
}

function escapeClose(tag: "style" | "script", source: string) {
  return source.replace(new RegExp(`<\\/${tag}`, "gi"), `<\\/${tag}`);
}

function rewriteViewportUnits(source: string) {
  return source.replace(/100d?vh/gi, "100%").replace(/100d?vw/gi, "100%");
}

const BASE = `<style>html, body { margin: 0; background: #efece4; color: #161412; color-scheme: light; }</style>`;
const HOOK = `<script>
(function(){
  const send = (level, args) => {
    try { parent.postMessage({ source: "colo-preview", level, args: args.map(a => {
      try { return typeof a === "string" ? a : JSON.stringify(a); } catch { return String(a); }
    })}, "*"); } catch (e) {}
  };
  ["log","info","warn","error"].forEach((level) => {
    const orig = console[level].bind(console);
    console[level] = function(){ send(level, [].slice.call(arguments)); orig.apply(console, arguments); };
  });
  window.addEventListener("error", (e) => send("error", [e.message]));
  window.addEventListener("unhandledrejection", (e) => send("error", [String(e.reason)]));
  try { window.localStorage.getItem("__colo_probe"); }
  catch (e) {
    const store = function(){
      const mem = {};
      return {
        getItem: function(k){ return Object.prototype.hasOwnProperty.call(mem, k) ? mem[k] : null; },
        setItem: function(k, v){ mem[k] = String(v); },
        removeItem: function(k){ delete mem[k]; },
        clear: function(){ for (const x of Object.keys(mem)) delete mem[x]; },
        key: function(i){ return Object.keys(mem)[i] || null; },
        get length(){ return Object.keys(mem).length; }
      };
    };
    try { Object.defineProperty(window, "localStorage", { value: store() }); } catch (err) {}
    try { Object.defineProperty(window, "sessionStorage", { value: store() }); } catch (err) {}
  }
})();
</script>`;

function transpile(path: string, code: string) {
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
      `const import_meta = { env: { DEV: true, PROD: false, MODE: "development", BASE_URL: "/", SSR: false }, hot: undefined };\n` +
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

function localModules(files: FileMap, entries: string[]) {
  const imports: Record<string, string> = {};
  const queue = [...entries];
  const seen = new Set<string>();
  while (queue.length && seen.size < 250) {
    const p = queue.shift()!;
    if (seen.has(p) || files[p] === undefined) continue;
    seen.add(p);
    if (/\.(css|scss|sass|less)$/.test(p)) continue;
    let code = transpile(p, files[p]!);
    code = shimVite(code);
    code = rewriteLocals(p, code, files, queue);
    const url = `data:text/javascript;charset=utf-8,${encodeURIComponent(code)}`;
    imports[`/${p}`] = url;
    imports[p] = url;
  }
  return imports;
}

function collectImportMaps(html: string) {
  const imports: Record<string, string> = {};
  for (const m of html.matchAll(/<script type=["']importmap["']>([\s\S]*?)<\/script>/g)) {
    try {
      Object.assign(imports, (JSON.parse(m[1]!) as { imports?: Record<string, string> }).imports ?? {});
    } catch {
      /* ignore */
    }
  }
  return imports;
}

function entriesFromHtml(html: string, files: FileMap) {
  const out: string[] = [];
  for (const m of html.matchAll(/<script\b([^>]*)>/gi)) {
    const src = m[1]!.match(/src=["']([^"']+)["']/i)?.[1];
    if (!src) continue;
    const path = findFilePath(files, src);
    if (path) out.push(path);
  }
  return out;
}

function fallbackHtml(files: FileMap) {
  const pkg = parsePkg(files["package.json"]);
  const stack = detectStack(pkg);
  const entry = ["src/main.tsx", "src/main.ts", "src/main.jsx", "src/main.js", "src/index.tsx", "src/index.jsx", "src/index.ts", "src/index.js", "src/App.tsx", "App.tsx"]
    .find((p) => files[p] !== undefined);
  if (stack.kind === "spa" && entry) {
    return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head><body><div id="root"></div><div id="app"></div><script type="module" src="/${entry}"></script></body></html>`;
  }
  const hint = stackHint(stack);
  return `<!doctype html><html><head><meta charset="utf-8"><style>body{font:15px/1.45 ui-sans-serif,system-ui;padding:28px;background:#efece4;color:#161412}b{display:block;margin-bottom:8px}</style></head><body><b>${stack.label}</b><p>${hint}</p><p>Coloca um <code>index.html</code> (Vite/React) pra o Preview rodar no iPad.</p></body></html>`;
}

export function buildPreviewHtml(files: FileMap) {
  let html =
    files["index.html"] ??
    files["src/index.html"] ??
    fallbackHtml(files);

  if (!/<head[\s>]/i.test(html)) {
    html = html.replace(/<html[^>]*>/i, "$&<head></head>");
  }
  if (!/<head[\s>]/i.test(html)) html = `<!doctype html><html><head></head><body>${html}</body></html>`;

  html = html.replace(/<link\b[^>]*>/gi, (tag) => {
    if (!/rel=["']?stylesheet/i.test(tag)) return tag;
    const href = tag.match(/href=["']([^"']+)["']/i)?.[1];
    if (!href) return tag;
    const css = findFile(files, href);
    if (css === undefined) return `<!-- missing ${href} -->`;
    return `<style data-colo="${normalize(href)}">${escapeClose("style", rewriteViewportUnits(css))}</style>`;
  });

  const boot: string[] = [];
  html = html.replace(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi, (full, attrs: string) => {
    if (/type=["']importmap["']/i.test(attrs)) return full;
    const src = attrs.match(/src=["']([^"']+)["']/i)?.[1];
    if (!src) return full;
    const path = findFilePath(files, src);
    if (!path) return `<!-- missing ${src} -->`;
    boot.push(path);
    return `<script type="module" data-colo="${path}">import ${JSON.stringify(`/${path}`)}</script>`;
  });

  const linked = new Set([...html.matchAll(/data-colo="([^"]+)"/g)].map((m) => m[1]));
  const extraCss = Object.entries(files)
    .filter(([k]) => k.endsWith(".css") && !k.includes("node_modules/") && !linked.has(k) && !linked.has(k.split("/").pop() ?? ""))
    .map(([, v]) => rewriteViewportUnits(v))
    .join("\n");

  const entries = [...boot, ...entriesFromHtml(html, files)];
  const local = localModules(files, entries);
  const prevMaps = collectImportMaps(html);
  html = html.replace(/<script type=["']importmap["']>[\s\S]*?<\/script>/g, "");
  const imports = { ...esmImports(lockOfFiles(files)), ...prevMaps, ...local };
  const tag = Object.keys(imports).length
    ? `<script type="importmap">${JSON.stringify({ imports })}</script>`
    : "";
  const inject = `${BASE}${HOOK}${extraCss ? `<style>${escapeClose("style", extraCss)}</style>` : ""}`;
  if (html.includes("</head>")) html = html.replace("</head>", `${inject}${tag}</head>`);
  else html = inject + tag + html;

  return html;
}
