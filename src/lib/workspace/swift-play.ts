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

function extractStates(src: string) {
  const out: Record<string, string> = {};
  const re = /@State(?:\s*\([^)]*\))?\s+(?:private\s+)?var\s+(\w+)\s*(?::\s*[^=]+)?\s*=\s*([^\n]+)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src))) {
    const name = m[1]!;
    let raw = m[2]!.trim().replace(/;+$/, "");
    if (/^true|false$/.test(raw)) out[name] = raw;
    else if (/^-?\d+(?:\.\d+)?$/.test(raw)) out[name] = raw;
    else if (raw.startsWith("\"")) out[name] = JSON.stringify(extractString(raw) || "");
    else out[name] = "0";
  }
  return out;
}

function interp(text: string) {
  return text.replace(/\\\((\w+)\)/g, (_a, n) => `<span data-bind="${n}">0</span>`);
}

function extractSystemName(src: string) {
  const m = src.match(/systemName:\s*"([^"]+)"/);
  return m ? m[1]! : "star";
}

function parseView(src: string): string {
  const trimmed = src.trim();
  if (!trimmed) return "";

  const call = trimmed.match(/^(VStack|HStack|ZStack|List|NavigationStack|ScrollView|Form)\s*(?:\([^)]*\))?\s*\{/);
  if (call) {
    const kind = call[1]!;
    const body = blockBody(trimmed.slice(call[0].length - 1));
    const kids = splitTop(body).map(parseView).join("");
    const cls =
      kind === "HStack"
        ? "sw-h"
        : kind === "ZStack"
          ? "sw-z"
          : kind === "List" || kind === "Form"
            ? "sw-list"
            : "sw-v";
    const title = kind === "NavigationStack" ? `<header class="sw-nav">Playground</header>` : "";
    return `<div class="${cls}">${title}${kids}</div>`;
  }

  if (/^Text\s*\(/.test(trimmed)) {
    const t = extractString(trimmed) || trimmed.match(/Text\(\s*\\?\((\w+)\)/)?.[0] || " ";
    const bind = trimmed.match(/\\\((\w+)\)/);
    const big = /\.font\(\s*\.largeTitle/.test(trimmed) || /\.bold\(/.test(trimmed) || /\.font\(\s*\.title/.test(trimmed);
    const pad = /\.padding\(/.test(trimmed);
    const inner = bind ? interp(extractString(trimmed) || `\\(${bind[1]})`) : esc(extractString(trimmed) || " ");
    return `<p class="sw-text${big ? " is-big" : ""}${pad ? " is-pad" : ""}">${inner || esc(t)}</p>`;
  }
  if (/^Button\s*\(/.test(trimmed)) {
    const t = extractString(trimmed) || "Botão";
    const inc = trimmed.match(/(\w+)\s*\+=\s*(\d+)/);
    const dec = trimmed.match(/(\w+)\s*-=\s*(\d+)/);
    const tog = trimmed.match(/(\w+)\s*\.toggle\(\)/);
    const attr = inc
      ? `data-act="inc" data-var="${inc[1]}" data-by="${inc[2]}"`
      : dec
        ? `data-act="dec" data-var="${dec[1]}" data-by="${dec[2]}"`
        : tog
          ? `data-act="tog" data-var="${tog[1]}"`
          : `data-act="inc" data-var="count" data-by="1"`;
    return `<button type="button" class="sw-btn" ${attr}>${esc(t)}</button>`;
  }
  if (/^Toggle\s*\(/.test(trimmed)) {
    const t = extractString(trimmed) || "Toggle";
    const bind = trimmed.match(/isOn:\s*\$(\w+)/);
    return `<label class="sw-tog"><input type="checkbox" data-var="${bind?.[1] || ""}" /> ${esc(t)}</label>`;
  }
  if (/^TextField\s*\(/.test(trimmed)) {
    const t = extractString(trimmed) || "";
    const bind = trimmed.match(/text:\s*\$(\w+)/);
    return `<input class="sw-field" placeholder="${esc(t)}" data-var="${bind?.[1] || ""}" />`;
  }
  if (/^Slider\s*\(/.test(trimmed)) {
    const bind = trimmed.match(/value:\s*\$(\w+)/);
    return `<input type="range" class="sw-slider" min="0" max="100" data-var="${bind?.[1] || ""}" />`;
  }
  if (/^Stepper\s*\(/.test(trimmed)) {
    const t = extractString(trimmed) || "";
    const bind = trimmed.match(/value:\s*\$(\w+)/);
    return `<div class="sw-step"><button type="button" data-act="dec" data-var="${bind?.[1] || "count"}" data-by="1">−</button><span>${esc(t)}</span><button type="button" data-act="inc" data-var="${bind?.[1] || "count"}" data-by="1">+</button></div>`;
  }
  if (/^ProgressView\s*\(/.test(trimmed)) {
    const bind = trimmed.match(/value:\s*\$?(\w+)/);
    return `<progress class="sw-prog" max="1" value="0.4" data-var="${bind?.[1] || ""}"></progress>`;
  }
  if (/^Label\s*\(/.test(trimmed)) {
    const t = extractString(trimmed) || "";
    return `<div class="sw-label">${esc(t)}</div>`;
  }
  if (/^Circle\s*\(/.test(trimmed)) return `<div class="sw-circle"></div>`;
  if (/^Capsule\s*\(/.test(trimmed) || /^RoundedRectangle/.test(trimmed)) return `<div class="sw-cap"></div>`;
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
  if (/^ForEach\s*\(/.test(trimmed)) {
    const body = blockBody(trimmed.slice(trimmed.indexOf("{")));
    return `<div class="sw-list">${splitTop(body).map(parseView).join("")}</div>`;
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
      if (piece.startsWith(".")) {
        if (out.length) out[out.length - 1] = `${out[out.length - 1]} ${piece}`;
      } else if (piece && !piece.startsWith("//")) out.push(piece);
      buf = "";
    }
  }
  const tail = buf.trim();
  if (tail && !tail.startsWith("//") && !tail.startsWith(".")) out.push(tail);
  return out.filter((s) =>
    /^(VStack|HStack|ZStack|List|NavigationStack|ScrollView|Form|Text|Button|Image|Spacer|Divider|Section|Toggle|TextField|Slider|Stepper|ProgressView|Label|Circle|Capsule|RoundedRectangle|ForEach)\b/.test(s),
  );
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
  const inner = splitTop(body).map(parseView).join("") || parseView(body.trim()) || `<p class="sw-empty">Nada pra renderizar. Use Text, VStack, Button, @State…</p>`;
  const states = extractStates(source);
  return `<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Swift Playground</title>
<style>
  html, body { margin: 0; height: 100%; background: #0c0c0d; color: #f2f2f2; font-family: ui-sans-serif, system-ui, sans-serif; }
  .sw-root { min-height: 100%; padding: 24px 18px 40px; display: flex; justify-content: center; }
  .sw-phone { width: min(390px, 100%); min-height: 520px; border-radius: 28px; background: #1c1c1e; padding: 18px; box-shadow: 0 20px 50px rgb(0 0 0 / 0.45); position: relative; }
  .sw-banner { font-size: 11px; color: #8e8e93; letter-spacing: .04em; margin: 0 0 12px; }
  .sw-v { display: flex; flex-direction: column; gap: 12px; }
  .sw-h { display: flex; flex-direction: row; align-items: center; gap: 12px; }
  .sw-z { display: grid; }
  .sw-z > * { grid-area: 1 / 1; }
  .sw-list { display: flex; flex-direction: column; gap: 2px; }
  .sw-text { margin: 0; font-size: 17px; line-height: 1.35; }
  .sw-text.is-big { font-size: 32px; font-weight: 600; letter-spacing: -0.03em; }
  .sw-btn { min-height: 44px; padding: 0 16px; border: 0; border-radius: 12px; background: #0a84ff; color: #fff; font-size: 16px; }
  .sw-tog { display: flex; align-items: center; gap: 10px; min-height: 44px; font-size: 16px; }
  .sw-field { min-height: 44px; width: 100%; padding: 0 12px; border-radius: 10px; border: 1px solid rgb(255 255 255 / 0.16); background: #2c2c2e; color: #fff; }
  .sw-slider, .sw-prog { width: 100%; }
  .sw-step { display: flex; align-items: center; gap: 10px; }
  .sw-step button { width: 44px; height: 44px; border: 0; border-radius: 10px; background: #2c2c2e; color: #fff; font-size: 20px; }
  .sw-circle { width: 48px; height: 48px; border-radius: 50%; background: #0a84ff; }
  .sw-cap { height: 28px; border-radius: 999px; background: #2c2c2e; }
  .sw-label { font-size: 15px; }
  .sw-text.is-pad { padding: 8px 0; }
  .sw-img { padding: 10px 0; color: #8e8e93; font-size: 13px; }
  .sw-spacer { flex: 1; min-height: 12px; }
  .sw-hr { border: 0; border-top: 1px solid rgb(255 255 255 / 0.12); margin: 4px 0; }
  .sw-nav { font-size: 13px; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; color: #8e8e93; margin-bottom: 8px; }
  .sw-sec h3 { margin: 0 0 8px; font-size: 13px; color: #8e8e93; }
  .sw-empty { color: #8e8e93; }
</style>
</head>
<body>
  <div class="sw-root"><div class="sw-phone">
    <p class="sw-banner">Playground SwiftUI · não é o compilador do Xcode</p>
    ${inner}
  </div></div>
<script>
(function(){
  var st = ${JSON.stringify(states)};
  function paint(){
    document.querySelectorAll("[data-bind]").forEach(function(el){
      var k = el.getAttribute("data-bind");
      if (k in st) el.textContent = String(st[k]);
    });
    document.querySelectorAll("input[data-var], progress[data-var]").forEach(function(el){
      var k = el.getAttribute("data-var");
      if (!k || !(k in st)) return;
      if (el.type === "checkbox") el.checked = !!st[k];
      else if (el.tagName === "PROGRESS") el.value = Number(st[k]) || 0;
      else el.value = st[k];
    });
  }
  function act(el){
    var a = el.getAttribute("data-act");
    var k = el.getAttribute("data-var");
    var by = Number(el.getAttribute("data-by") || 1);
    if (!k) return;
    if (typeof st[k] === "undefined") st[k] = 0;
    if (a === "inc") st[k] = Number(st[k]) + by;
    if (a === "dec") st[k] = Number(st[k]) - by;
    if (a === "tog") st[k] = !st[k];
    paint();
  }
  document.querySelectorAll("[data-act]").forEach(function(b){
    b.addEventListener("click", function(){ act(b); });
  });
  document.querySelectorAll("input[data-var]").forEach(function(i){
    i.addEventListener("input", function(){
      var k = i.getAttribute("data-var");
      if (!k) return;
      st[k] = i.type === "checkbox" ? i.checked : (i.type === "range" ? Number(i.value) : i.value);
      paint();
    });
  });
  paint();
})();
</script>
</body>
</html>`;
}
