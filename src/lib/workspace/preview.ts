import { unpackBin } from "@/lib/github/api";
import type { FileMap } from "./types";
import { detectStack, parsePkg, stackHint } from "./npm";
import { esmImports, lockOfFiles } from "./npm-lock";
import { isNoisePath } from "./ignore";
import { workspaceImportAliases } from "./pnpm";
import { findFile, findFilePath, localModules, linkDataUrls, moduleSources, normalize } from "./bundle";
import { nextPageEntry, shimImportMap } from "./runtime";
import type { PreviewFetch } from "./preview-types";

export type { PreviewFetch } from "./preview-types";

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
      var t = setTimeout(function(){ pending.delete(id); reject(new Error("preview fetch timeout " + path)); }, 20000);
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
  const next = nextPageEntry(files);
  if (next) return next.html;
  const pkg = parsePkg(files["package.json"]);
  const stack = detectStack(pkg);
  const entry = ENTRY_CANDIDATES.find((p) => files[p] !== undefined);
  if ((stack.kind === "spa" || stack.id === "next") && entry) {
    return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head><body><div id="root"></div><div id="app"></div><script type="module" src="/${entry}"></script></body></html>`;
  }
  const hint = stackHint(stack);
  return `<!doctype html><html><head><meta charset="utf-8"><style>body{font:15px/1.45 ui-sans-serif,system-ui;padding:28px;background:#efece4;color:#161412}b{display:block;margin-bottom:8px}</style></head><body><b>${stack.label}</b><p>${hint}</p><p>Coloca um <code>index.html</code> ou <code>app/page.tsx</code> pra o Preview rodar no iPad.</p></body></html>`;
}

function previewBoot(files: FileMap) {
  const next = nextPageEntry(files);
  const virtual = next ? { ...files, [next.path]: next.code } : files;
  const html = virtual["index.html"] ?? virtual["src/index.html"] ?? fallbackHtml(files);
  const fromHtml = entriesFromHtml(html, virtual);
  const ws = workspaceImportAliases(virtual);
  const wsEntries = Object.values(ws).map((v) => v.replace(/^\//, ""));
  const extra = ENTRY_CANDIDATES.filter((p) => virtual[p] !== undefined);
  const nextEntries = next ? [next.path] : [];
  const entries = [...new Set([...fromHtml, ...extra, ...wsEntries, ...nextEntries])];
  return { html, entries, ws, files: virtual };
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
  const { entries, files: virtual } = previewBoot(files);
  if (!entries.length) return null;
  const code = moduleSources(virtual, entries);
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

  if (path.startsWith("api/")) {
    return {
      status: 501,
      contentType: "application/json;charset=utf-8",
      body: JSON.stringify({
        error: "sem arquivo estático pra esta API — o runtime do Colo tenta o Route Handler / Nest em seguida",
        path: `/${path}`,
        method,
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
  const vfs = boot.files;
  let html = boot.html;

  if (!/<head[\s>]/i.test(html)) {
    html = html.replace(/<html[^>]*>/i, "$&<head></head>");
  }
  if (!/<head[\s>]/i.test(html)) html = `<!doctype html><html><head></head><body>${html}</body></html>`;

  html = html.replace(/<link\b[^>]*>/gi, (tag) => {
    if (!/rel=["']?stylesheet/i.test(tag)) return tag;
    const href = tag.match(/href=["']([^"']+)["']/i)?.[1];
    if (!href) return tag;
    const css = findFile(vfs, href);
    if (css === undefined) return `<!-- missing ${href} -->`;
    const path = findFilePath(vfs, href) ?? normalize(href);
    return `<style data-colo-path="${path}">${escapeClose("style", rewriteViewportUnits(css))}</style>`;
  });

  const entryScripts: string[] = [];
  html = html.replace(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi, (full, attrs: string) => {
    if (/type=["']importmap["']/i.test(attrs)) return full;
    const src = attrs.match(/src=["']([^"']+)["']/i)?.[1];
    if (!src) return full;
    const path = findFilePath(vfs, src);
    if (!path) return `<!-- missing ${src} -->`;
    entryScripts.push(path);
    return `<script type="module" data-colo="${path}">import ${JSON.stringify(`/${path}`)}</script>`;
  });

  const linked = new Set([...html.matchAll(/data-colo(?:-path)?="([^"]+)"/g)].map((m) => m[1]));
  const extraCss = Object.entries(vfs)
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
  const local = localModules(vfs, entries);
  const prevMaps = collectImportMaps(html);
  html = html.replace(/<script type=["']importmap["']>[\s\S]*?<\/script>/g, "");
  const react = {
    react: "https://esm.sh/react@19",
    "react/jsx-runtime": "https://esm.sh/react@19/jsx-runtime",
    "react/jsx-dev-runtime": "https://esm.sh/react@19/jsx-dev-runtime",
    "react-dom": "https://esm.sh/react-dom@19",
    "react-dom/client": "https://esm.sh/react-dom@19/client",
  };
  const imports: Record<string, string> = {
    ...react,
    ...esmImports(lockOfFiles(files)),
    ...shimImportMap(),
    ...prevMaps,
    ...local,
  };
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
