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
  const key = Object.keys(files).find((k) => k === name || k.endsWith(`/${name}`));
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
    .filter(([k]) => k.endsWith(".css") && !linked.has(k) && !linked.has(k.split("/").pop() ?? ""))
    .map(([, v]) => rewriteViewportUnits(v))
    .join("\n");

  const inject = `${BASE}${HOOK}${extraCss ? `<style>${escapeClose("style", extraCss)}</style>` : ""}`;
  if (html.includes("</head>")) html = html.replace("</head>", `${inject}</head>`);
  else html = inject + html;

  return html;
}
