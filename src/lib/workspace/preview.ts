import { transform } from "sucrase";
import { unpackBin } from "@/lib/github/api";
import type { FileMap } from "./types";
import { detectStack, parsePkg, stackHint } from "./npm";
import { esmImports, lockOfFiles } from "./npm-lock";
import { isNoisePath } from "./ignore";
import { workspaceImportAliases } from "./pnpm";

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

export function rewriteViewportUnits(source: string) {
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

  var reqId = 1;
  var pending = new Map();
  function previewUrl(input) {
    try {
      var raw = typeof input === "string" ? input : (input && input.url) ? input.url : String(input);
      if (!raw) return { skip: true, raw: raw };
      if (/^(data:|blob:|about:)/i.test(raw)) return { skip: true, raw: raw };
      if (/^(https?:)?\\/\\//i.test(raw)) {
        var abs = new URL(raw.indexOf("//") === 0 ? "https:" + raw : raw);
        if (/^(esm\\.sh|cdn\\.jsdelivr\\.net|unpkg\\.com|ga\\.jspm\\.io|cdn\\.skypack\\.dev)$/i.test(abs.hostname)) {
          return { skip: true, raw: raw };
        }
        if (abs.origin === location.origin && location.protocol !== "about:") return { path: abs.pathname + abs.search };
        return { skip: true, raw: raw };
      }
      var u = new URL(raw, "https://colo.preview/");
      return { path: u.pathname + u.search };
    } catch (err) {
      return { skip: true, raw: String(input) };
    }
  }
  function ask(path, method, body) {
    var id = reqId++;
    return new Promise(function(resolve, reject) {
      var t = setTimeout(function(){ pending.delete(id); reject(new Error("preview fetch timeout " + path)); }, 8000);
      pending.set(id, { resolve: resolve, reject: reject, t: t });
      parent.postMessage({ source: "colo-preview", type: "fetch", id: id, url: path, method: method || "GET", body: body || null }, "*");
    });
  }
  function toResponse(res) {
    var body = res.body || "";
    if (res.base64) {
      var bin = atob(body);
      var arr = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
      body = arr;
    }
    return new Response(body, { status: res.status || 200, headers: { "content-type": res.contentType || "text/plain" } });
  }
  var origFetch = window.fetch.bind(window);
  window.fetch = function(input, init) {
    var info = previewUrl(input);
    if (info.skip) return origFetch(input, init);
    var method = (init && init.method) || (input && input.method) || "GET";
    var body = init && init.body;
    if (body && typeof body !== "string") { try { body = String(body); } catch (e) { body = null; } }
    return ask(info.path, method, body).then(toResponse);
  };
  var OrigXHR = window.XMLHttpRequest;
  function ShimXHR() {
    var xhr = new OrigXHR();
    var _url = "";
    var _method = "GET";
    var origOpen = xhr.open.bind(xhr);
    var origSend = xhr.send.bind(xhr);
    xhr.open = function(method, url, async, user, pass) {
      _method = method;
      _url = String(url);
      var info = previewUrl(_url);
      if (info.skip) return origOpen.call(xhr, method, url, async, user, pass);
    };
    xhr.send = function(body) {
      var info = previewUrl(_url);
      if (info.skip) return origSend(body);
      ask(info.path, _method, typeof body === "string" ? body : null).then(function(res) {
        try { Object.defineProperty(xhr, "readyState", { configurable: true, get: function(){ return 4; } }); } catch (e) {}
        try { Object.defineProperty(xhr, "status", { configurable: true, get: function(){ return res.status || 200; } }); } catch (e) {}
        try { Object.defineProperty(xhr, "statusText", { configurable: true, get: function(){ return "OK"; } }); } catch (e) {}
        var text = res.base64 ? atob(res.body || "") : (res.body || "");
        try { Object.defineProperty(xhr, "responseText", { configurable: true, get: function(){ return text; } }); } catch (e) {}
        try { Object.defineProperty(xhr, "response", { configurable: true, get: function(){ return text; } }); } catch (e) {}
        try { xhr.dispatchEvent(new Event("readystatechange")); } catch (e) {}
        try { xhr.dispatchEvent(new Event("load")); } catch (e) {}
      }, function() {
        try { xhr.dispatchEvent(new Event("error")); } catch (e) {}
      });
    };
    return xhr;
  }
  ShimXHR.prototype = OrigXHR.prototype;
  ShimXHR.UNSENT = 0; ShimXHR.OPENED = 1; ShimXHR.HEADERS_RECEIVED = 2; ShimXHR.LOADING = 3; ShimXHR.DONE = 4;
  try { window.XMLHttpRequest = ShimXHR; } catch (e) {}

  function remountRoots() {
    ["root", "app"].forEach(function(id) {
      var el = document.getElementById(id);
      if (!el || !el.parentNode) return;
      el.parentNode.replaceChild(el.cloneNode(false), el);
    });
    document.querySelectorAll("script[data-colo-hmr]").forEach(function(s){ s.remove(); });
  }
  window.addEventListener("message", function(e) {
    var d = e.data;
    if (d && d.source === "colo-host" && d.type === "fetch-res") {
      var p = pending.get(d.id);
      if (!p) return;
      clearTimeout(p.t);
      pending.delete(d.id);
      p.resolve(d);
      return;
    }
    if (!d || d.source !== "colo-hmr") return;
    if (d.kind === "css") {
      var sel = 'style[data-colo-path="' + String(d.path).replace(/"/g, "") + '"]';
      var el = document.querySelector(sel);
      if (!el) {
        el = document.createElement("style");
        el.setAttribute("data-colo-path", d.path);
        document.head.appendChild(el);
      }
      el.textContent = d.content || "";
      return;
    }
    if (d.kind === "js" && d.entryUrl) {
      remountRoots();
      var s = document.createElement("script");
      s.type = "module";
      s.dataset.coloHmr = "1";
      s.textContent = "import " + JSON.stringify(d.entryUrl);
      document.body.appendChild(s);
      return;
    }
    if (d.kind === "full") {
      parent.postMessage({ source: "colo-preview", type: "need-reload" }, "*");
    }
  });
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

function moduleSources(files: FileMap, entries: string[]) {
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

function localModules(files: FileMap, entries: string[]) {
  const imports: Record<string, string> = {};
  const code = moduleSources(files, entries);
  for (const [p, src] of Object.entries(code)) {
    const url = `data:text/javascript;charset=utf-8,${encodeURIComponent(src)}`;
    imports[`/${p}`] = url;
    imports[p] = url;
  }
  return imports;
}

function localSpecifiers(code: string): string[] {
  const out: string[] = [];
  for (const m of code.matchAll(/(?:from|import)\s*\(?\s*['"]\/([^'"]+)['"]/g)) {
    if (m[1] && !out.includes(m[1])) out.push(m[1]);
  }
  return out;
}

function linkDataUrls(code: Record<string, string>): Record<string, string> | null {
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
    src = src.replace(/(from\s+|import\s*\(\s*|import\s+)(['"])\/([^'"]+)\2/g, (m, pre: string, q: string, spec: string) => {
      const url = urls[spec];
      if (!url) return m;
      return `${pre}${q}${url}${q}`;
    });
    urls[p] = `data:text/javascript;charset=utf-8,${encodeURIComponent(src)}`;
  }
  return urls;
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

const ENTRY_CANDIDATES = [
  "src/main.tsx",
  "src/main.ts",
  "src/main.jsx",
  "src/main.js",
  "src/index.tsx",
  "src/index.jsx",
  "src/index.ts",
  "src/index.js",
  "src/App.tsx",
  "App.tsx",
];

function fallbackHtml(files: FileMap) {
  const pkg = parsePkg(files["package.json"]);
  const stack = detectStack(pkg);
  const entry = ENTRY_CANDIDATES.find((p) => files[p] !== undefined);
  if (stack.kind === "spa" && entry) {
    return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head><body><div id="root"></div><div id="app"></div><script type="module" src="/${entry}"></script></body></html>`;
  }
  const hint = stackHint(stack);
  return `<!doctype html><html><head><meta charset="utf-8"><style>body{font:15px/1.45 ui-sans-serif,system-ui;padding:28px;background:#efece4;color:#161412}b{display:block;margin-bottom:8px}</style></head><body><b>${stack.label}</b><p>${hint}</p><p>Coloca um <code>index.html</code> (Vite/React) pra o Preview rodar no iPad.</p></body></html>`;
}

function previewBoot(files: FileMap) {
  const html = files["index.html"] ?? files["src/index.html"] ?? fallbackHtml(files);
  const fromHtml = entriesFromHtml(html, files);
  const ws = workspaceImportAliases(files);
  const wsEntries = Object.values(ws).map((v) => v.replace(/^\//, ""));
  const extra = ENTRY_CANDIDATES.filter((p) => files[p] !== undefined);
  const entries = [...new Set([...fromHtml, ...extra, ...wsEntries])];
  return { html, entries, ws };
}

export type HmrKind = "css" | "js" | "full";

export function classifyPreviewChange(prev: FileMap, next: FileMap): { kind: HmrKind; paths: string[] } {
  const changed: string[] = [];
  const keys = new Set([...Object.keys(prev), ...Object.keys(next)]);
  for (const k of keys) {
    if (isNoisePath(k)) continue;
    if (prev[k] !== next[k]) changed.push(k);
  }
  if (!changed.length) return { kind: "css", paths: [] };
  if (changed.some((p) => /(^|\/)index\.html$/.test(p) || p === "package.json" || p === "package-lock.colo.json" || p.endsWith(".html"))) {
    return { kind: "full", paths: changed };
  }
  if (changed.every((p) => /\.css$/.test(p))) return { kind: "css", paths: changed };
  if (changed.every((p) => /\.(js|jsx|ts|tsx|mjs|cjs|json)$/.test(p))) return { kind: "js", paths: changed };
  return { kind: "full", paths: changed };
}

export function previewCss(files: FileMap, path: string) {
  const raw = files[path];
  if (raw === undefined) return "";
  return rewriteViewportUnits(raw);
}

export function previewHmrJs(files: FileMap): { entryUrl: string } | null {
  const { entries } = previewBoot(files);
  if (!entries.length) return null;
  const code = moduleSources(files, entries);
  const urls = linkDataUrls(code);
  if (!urls) return null;
  const entry = entries[0]!;
  const entryUrl = urls[entry];
  if (!entryUrl) return null;
  return { entryUrl };
}

const MIME: Record<string, string> = {
  json: "application/json",
  html: "text/html",
  css: "text/css",
  js: "text/javascript",
  mjs: "text/javascript",
  cjs: "text/javascript",
  ts: "text/javascript",
  tsx: "text/javascript",
  jsx: "text/javascript",
  svg: "image/svg+xml",
  txt: "text/plain;charset=utf-8",
  md: "text/markdown;charset=utf-8",
  xml: "application/xml",
  map: "application/json",
  wasm: "application/wasm",
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  ico: "image/x-icon",
  woff: "font/woff",
  woff2: "font/woff2",
  ttf: "font/ttf",
  otf: "font/otf",
};

export type PreviewFetch = {
  status: number;
  body: string;
  contentType: string;
  base64?: boolean;
};

function isServerRoute(files: FileMap, path: string) {
  const rest = path.replace(/^api\//, "").replace(/\/+$/, "");
  const tries = [
    `app/api/${rest}/route.ts`,
    `app/api/${rest}/route.js`,
    `src/app/api/${rest}/route.ts`,
    `src/app/api/${rest}/route.js`,
    `pages/api/${rest}.ts`,
    `pages/api/${rest}.js`,
    `pages/api/${rest}.tsx`,
    `src/pages/api/${rest}.ts`,
    `src/pages/api/${rest}.js`,
  ];
  if (tries.some((t) => files[t] !== undefined)) return true;
  return Object.keys(files).some(
    (k) =>
      /(^|\/)((src\/)?app)\/api\/.+\/route\.[jt]sx?$/.test(k) &&
      path.startsWith("api/"),
  );
}

export function lookupPreviewAsset(files: FileMap, url: string, method = "GET"): PreviewFetch {
  let path = url;
  try {
    if (/^https?:/i.test(url) || url.startsWith("//")) {
      const u = new URL(url.startsWith("//") ? `https:${url}` : url);
      path = u.pathname;
    }
  } catch {
    /* keep */
  }
  path = decodeURIComponent(path)
    .replace(/[?#].*$/, "")
    .replace(/^\/+/, "")
    .replace(/^__colo\/preview\/?/, "");

  const tries: string[] = [];
  const push = (p: string) => {
    if (p && !tries.includes(p)) tries.push(p);
  };
  push(path);
  push(`public/${path}`);
  push(`static/${path}`);
  if (!path.includes(".")) {
    push(`${path}.json`);
    push(`public/${path}.json`);
    push(`public/${path}/index.html`);
    push(`${path}/index.html`);
  }
  if (path.startsWith("api/")) {
    const rest = path.slice(4);
    push(`public/api/${rest}.json`);
    push(`public/api/${rest}`);
    push(`api/${rest}.json`);
    push(`mock/api/${rest}.json`);
    push(`mocks/${rest}.json`);
    push(`src/mocks/${rest}.json`);
  }

  for (const t of tries) {
    const body = files[t];
    if (body === undefined) continue;
    const bin = unpackBin(body);
    if (bin) return { status: 200, body: bin.b64, contentType: bin.mime, base64: true };
    const ext = (t.split(".").pop() ?? "").toLowerCase();
    const contentType =
      MIME[ext] ||
      (body.trimStart().startsWith("{") || body.trimStart().startsWith("[")
        ? "application/json"
        : "text/plain;charset=utf-8");
    return { status: 200, body, contentType };
  }

  if (path.startsWith("api/") || isServerRoute(files, path)) {
    return {
      status: 501,
      contentType: "application/json;charset=utf-8",
      body: JSON.stringify({
        error: "API de servidor (Next/Nest) não roda no iPad — sem Node.",
        path: `/${path}`,
        method,
        hint: "Coloca JSON em public/api/… json. No TestFlight nativo também não tem Node; o fetch do Preview só serve arquivos do workspace.",
      }),
    };
  }

  return {
    status: 404,
    contentType: "application/json;charset=utf-8",
    body: JSON.stringify({ error: "not found", path: `/${path}` }),
  };
}

export function buildPreviewHtml(files: FileMap) {
  const boot = previewBoot(files);
  let html = boot.html;

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
    const path = findFilePath(files, href) ?? normalize(href);
    return `<style data-colo-path="${path}">${escapeClose("style", rewriteViewportUnits(css))}</style>`;
  });

  const entryScripts: string[] = [];
  html = html.replace(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi, (full, attrs: string) => {
    if (/type=["']importmap["']/i.test(attrs)) return full;
    const src = attrs.match(/src=["']([^"']+)["']/i)?.[1];
    if (!src) return full;
    const path = findFilePath(files, src);
    if (!path) return `<!-- missing ${src} -->`;
    entryScripts.push(path);
    return `<script type="module" data-colo="${path}">import ${JSON.stringify(`/${path}`)}</script>`;
  });

  const linked = new Set([...html.matchAll(/data-colo(?:-path)?="([^"]+)"/g)].map((m) => m[1]));
  const extraCss = Object.entries(files)
    .filter(
      ([k]) =>
        k.endsWith(".css") &&
        !k.includes("node_modules/") &&
        !linked.has(k) &&
        !linked.has(k.split("/").pop() ?? ""),
    )
    .map(([k, v]) => `<style data-colo-path="${k}">${escapeClose("style", rewriteViewportUnits(v))}</style>`)
    .join("");

  const entries = [...new Set([...entryScripts, ...boot.entries])];
  const local = localModules(files, entries);
  const prevMaps = collectImportMaps(html);
  html = html.replace(/<script type=["']importmap["']>[\s\S]*?<\/script>/g, "");
  const imports = { ...esmImports(lockOfFiles(files)), ...prevMaps, ...local };
  for (const [name, path] of Object.entries(boot.ws)) {
    const url = local[path] || local[path.replace(/^\//, "")];
    if (url) imports[name] = url;
    else imports[name] = path;
  }
  const tag = Object.keys(imports).length
    ? `<script type="importmap">${JSON.stringify({ imports })}</script>`
    : "";
  const inject = `${BASE}${HOOK}${extraCss}`;
  if (html.includes("</head>")) html = html.replace("</head>", `${inject}${tag}</head>`);
  else html = inject + tag + html;

  return html;
}
