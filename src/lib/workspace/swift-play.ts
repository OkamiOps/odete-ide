/** Tiny SwiftUI subset → HTML for the iPad preview. Not a compiler. */

function esc(s: string) {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function extractString(src: string) {
  const m = src.match(/"((?:\\.|[^"\\])*)"/);
  return m ? m[1]!.replace(/\\n/g, "\n").replace(/\\"/g, '"') : "";
}

function extractSystemName(src: string) {
  const m = src.match(/systemName:\s*"([^"]+)"/);
  return m ? m[1]! : "star";
}

function node(tag: string, cls: string, inner: string) {
  return `<div class="${cls}">${inner}</div>`.replace("div", tag === "span" ? "span" : "div");
}

function parseView(src: string): string {
  const trimmed = src.trim();
  if (!trimmed) return "";

  const call = trimmed.match(/^(VStack|HStack|ZStack|List|NavigationStack|ScrollView)\s*(?:\([^)]*\))?\s*\{/);
  if (call) {
    const kind = call[1]!;
    const body = blockBody(trimmed.slice(call[0].length - 1));
    const kids = splitTop(body).map(parseView).join("");
    const cls =
      kind === "HStack"
        ? "sw-h"
        : kind === "ZStack"
          ? "sw-z"
          : kind === "List"
            ? "sw-list"
            : "sw-v";
    const title = kind === "NavigationStack" ? `<header class="sw-nav">Playground</header>` : "";
    return `<div class="${cls}">${title}${kids}</div>`;
  }

  if (/^Text\s*\(/.test(trimmed)) {
    const t = extractString(trimmed) || " ";
    const big = /\.font\(\s*\.largeTitle/.test(trimmed) || /\.bold\(/.test(trimmed);
    return `<p class="sw-text${big ? " is-big" : ""}">${esc(t)}</p>`;
  }
  if (/^Button\s*\(/.test(trimmed)) {
    const t = extractString(trimmed) || "Botão";
    return `<button type="button" class="sw-btn">${esc(t)}</button>`;
  }
  if (/^Image\s*\(/.test(trimmed)) {
    const n = extractSystemName(trimmed);
    return `<div class="sw-img" title="${esc(n)}">􀋃 ${esc(n)}</div>`;
  }
  if (/^Spacer\s*\(/.test(trimmed)) return `<div class="sw-spacer"></div>`;
  if (/^Divider\s*\(/.test(trimmed)) return `<hr class="sw-hr" />`;
  if (/^Section\s*\(/.test(trimmed)) {
    const t = extractString(trimmed);
    const body = blockBody(trimmed.slice(trimmed.indexOf("{")));
    return `<section class="sw-sec"><h3>${esc(t)}</h3>${splitTop(body).map(parseView).join("")}</section>`;
  }
  return "";
}

function blockBody(src: string) {
  const start = src.indexOf("{");
  if (start < 0) return "";
  let n = 0;
  for (let i = start; i < src.length; i++) {
    if (src[i] === "{") n += 1;
    if (src[i] === "}") {
      n -= 1;
      if (n === 0) return src.slice(start + 1, i);
    }
  }
  return src.slice(start + 1);
}

function splitTop(src: string): string[] {
  const out: string[] = [];
  let buf = "";
  let depth = 0;
  let paren = 0;
  for (let i = 0; i < src.length; i++) {
    const ch = src[i]!;
    if (ch === "{") depth += 1;
    if (ch === "}") depth -= 1;
    if (ch === "(") paren += 1;
    if (ch === ")") paren -= 1;
    buf += ch;
    if (depth === 0 && paren === 0 && ch === "\n") {
      const piece = buf.trim();
      if (piece && !piece.startsWith("//") && !piece.startsWith(".")) out.push(piece);
      buf = "";
    }
  }
  const tail = buf.trim();
  if (tail && !tail.startsWith("//") && !tail.startsWith(".")) out.push(tail);
  return out.filter((s) => /^(VStack|HStack|ZStack|List|NavigationStack|ScrollView|Text|Button|Image|Spacer|Divider|Section)\b/.test(s));
}

function findBody(src: string) {
  const m = src.match(/var\s+body:\s*some\s+View\s*\{/);
  if (!m || m.index === undefined) return src;
  return blockBody(src.slice(m.index + m[0].length - 1));
}

export function isSwiftPath(path: string) {
  return path.toLowerCase().endsWith(".swift");
}

export function buildSwiftPlayground(source: string) {
  const body = findBody(source);
  const inner = splitTop(body).map(parseView).join("") || parseView(body.trim()) || `<p class="sw-empty">Nada pra renderizar. Use Text, VStack, Button…</p>`;
  return `<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Swift Playground</title>
<style>
  html, body { margin: 0; height: 100%; background: #0c0c0d; color: #f2f2f2; font-family: ui-sans-serif, system-ui, sans-serif; }
  .sw-root { min-height: 100%; padding: 24px 18px 40px; display: flex; justify-content: center; }
  .sw-phone { width: min(390px, 100%); min-height: 520px; border-radius: 28px; background: #1c1c1e; padding: 18px; box-shadow: 0 20px 50px rgb(0 0 0 / 0.45); }
  .sw-v { display: flex; flex-direction: column; gap: 12px; }
  .sw-h { display: flex; flex-direction: row; align-items: center; gap: 12px; }
  .sw-z { display: grid; }
  .sw-z > * { grid-area: 1 / 1; }
  .sw-list { display: flex; flex-direction: column; gap: 2px; }
  .sw-text { margin: 0; font-size: 17px; line-height: 1.35; }
  .sw-text.is-big { font-size: 32px; font-weight: 600; letter-spacing: -0.03em; }
  .sw-btn { min-height: 44px; padding: 0 16px; border: 0; border-radius: 12px; background: #0a84ff; color: #fff; font-size: 16px; }
  .sw-img { padding: 10px 0; color: #8e8e93; font-size: 13px; }
  .sw-spacer { flex: 1; min-height: 12px; }
  .sw-hr { border: 0; border-top: 1px solid rgb(255 255 255 / 0.12); margin: 4px 0; }
  .sw-nav { font-size: 13px; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; color: #8e8e93; margin-bottom: 8px; }
  .sw-sec h3 { margin: 0 0 8px; font-size: 13px; color: #8e8e93; }
  .sw-empty { color: #8e8e93; }
</style>
</head>
<body>
  <div class="sw-root"><div class="sw-phone">${inner}</div></div>
</body>
</html>`;
}
