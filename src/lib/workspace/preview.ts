import type { FileMap } from "./types";

function normalize(href: string) {
  return href
    .trim()
    .replace(/['"]/g, "")
    .replace(/[?#].*$/, "")
    .replace(/^\.\//, "")
    .replace(/^\/+/, "");
}

function findFile(files: FileMap, href: string) {
  const clean = normalize(href);
  if (files[clean]) return files[clean];
  const name = clean.split("/").pop() ?? clean;
  const key = Object.keys(files).find(
    (k) => !k.includes("node_modules/") && (k === name || k.endsWith(`/${name}`)),
  );
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

export function buildPreviewHtml(files: FileMap) {
  let html = files["index.html"] ?? files["src/index.html"] ?? "<!doctype html><html><head></head><body><p>sem index.html</p></body></html>";

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

  html = html.replace(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi, (full, attrs: string, body: string) => {
    const src = attrs.match(/src=["']([^"']+)["']/i)?.[1];
    if (!src) return full;
    const js = findFile(files, src);
    if (js === undefined) return `<!-- missing ${src} -->`;
    const type = /type=["']module["']/i.test(attrs) ? ' type="module"' : "";
    return `<script${type} data-colo="${normalize(src)}">${escapeClose("script", js)}</script>`;
  });

  const linked = new Set(
    [...html.matchAll(/data-colo="([^"]+)"/g)].map((m) => m[1]),
  );
  const extraCss = Object.entries(files)
    .filter(([k]) => k.endsWith(".css") && !k.includes("node_modules/") && !linked.has(k) && !linked.has(k.split("/").pop() ?? ""))
    .map(([, v]) => rewriteViewportUnits(v))
    .join("\n");

  const local = importMap(files).imports;
  const prevMaps = collectImportMaps(html);
  html = html.replace(/<script type=["']importmap["']>[\s\S]*?<\/script>/g, "");
  const imports = { ...prevMaps, ...local };
  const tag = Object.keys(imports).length
    ? `<script type="importmap">${JSON.stringify({ imports })}</script>`
    : "";
  const inject = `${BASE}${HOOK}${extraCss ? `<style>${escapeClose("style", extraCss)}</style>` : ""}`;
  if (html.includes("</head>")) html = html.replace("</head>", `${inject}${tag}</head>`);
  else html = inject + tag + html;

  return html;
}

function collectImportMaps(html: string) {
  const imports: Record<string, string> = {};
  for (const m of html.matchAll(/<script type=["']importmap["']>([\s\S]*?)<\/script>/g)) {
    try {
      Object.assign(imports, (JSON.parse(m[1]!) as { imports?: Record<string, string> }).imports ?? {});
    } catch {
      /* ignore broken map */
    }
  }
  return imports;
}

function resolveRel(from: string, spec: string) {
  const clean = spec.replace(/[?#].*$/, "");
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

function importMap(files: FileMap) {
  const js = Object.keys(files).filter((k) => /\.(m?js|jsx)$/.test(k) && !k.includes("node_modules/"));
  const imports: Record<string, string> = {};
  for (const p of js) {
    let code = files[p]!;
    code = code.replace(/from\s+(['"])(\.[^'"]+)\1/g, (_, q: string, spec: string) => {
      let rel = resolveRel(p, spec);
      if (files[rel] === undefined) {
        const hit = [`${rel}.js`, `${rel}.mjs`, `${rel}/index.js`].find((k) => files[k] !== undefined);
        if (hit) rel = hit;
      }
      return `from ${q}/${rel}${q}`;
    });
    const url = `data:text/javascript;charset=utf-8,${encodeURIComponent(code)}`;
    imports[`/${p}`] = url;
    imports[p] = url;
  }
  return { imports };
}
