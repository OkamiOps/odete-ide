function esc(s: string) {
  return s
    .replace(/&/g, "\u0026amp;")
    .replace(/</g, "\u0026lt;")
    .replace(/>/g, "\u0026gt;")
    .replace(/"/g, "\u0026quot;");
}

function inline(raw: string) {
  let s = esc(raw);
  s = s.replace(/`([^`]+)`/g, "<code>$1</code>");
  s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/__([^_]+)__/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^\w])\*([^*]+)\*(?=\W|$)/g, "$1<em>$2</em>");
  s = s.replace(/(^|[^\w])_([^_]+)_(?=\W|$)/g, "$1<em>$2</em>");
  s = s.replace(/~~([^~]+)~~/g, "<del>$1</del>");
  s = s.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>');
  return s;
}

export function renderMarkdown(src: string) {
  const lines = src.replace(/\r\n/g, "\n").split("\n");
  const out: string[] = [];
  let i = 0;
  let para: string[] = [];
  let list: { type: "ul" | "ol"; items: string[] } | null = null;
  let code: string[] | null = null;
  let table: string[][] | null = null;

  const flushPara = () => {
    if (!para.length) return;
    out.push(`<p>${inline(para.join(" "))}</p>`);
    para = [];
  };
  const flushList = () => {
    if (!list) return;
    const tag = list.type;
    out.push(`<${tag}>${list.items.map((t) => `<li>${inline(t)}</li>`).join("")}</${tag}>`);
    list = null;
  };
  const flushTable = () => {
    if (!table || table.length < 2) {
      table = null;
      return;
    }
    const [head, , ...rows] = table[1]?.every((c) => /^:?-+:?$/.test(c))
      ? [table[0], table[1], ...table.slice(2)]
      : [table[0], [], ...table.slice(1)];
    const th = (head ?? []).map((c) => `<th>${inline(c)}</th>`).join("");
    const body = rows
      .filter((r) => r.some((c) => c.trim()))
      .map((r) => `<tr>${r.map((c) => `<td>${inline(c)}</td>`).join("")}</tr>`)
      .join("");
    out.push(`<table><thead><tr>${th}</tr></thead><tbody>${body}</tbody></table>`);
    table = null;
  };

  while (i < lines.length) {
    const line = lines[i] ?? "";

    if (code) {
      if (/^```/.test(line)) {
        out.push(`<pre><code>${esc(code.join("\n"))}</code></pre>`);
        code = null;
      } else code.push(line);
      i += 1;
      continue;
    }
    if (/^```/.test(line)) {
      flushPara();
      flushList();
      flushTable();
      code = [];
      i += 1;
      continue;
    }

    const row = /^\s*\|(.+)\|\s*$/.exec(line);
    if (row) {
      flushPara();
      flushList();
      const cells = row[1]!.split("|").map((c) => c.trim());
      table = table ?? [];
      table.push(cells);
      i += 1;
      continue;
    }
    if (table) flushTable();

    if (/^\s*$/.test(line)) {
      flushPara();
      flushList();
      i += 1;
      continue;
    }
    if (/^---+$|^\*\*\*+$|^___+$/.test(line.trim())) {
      flushPara();
      flushList();
      out.push("<hr />");
      i += 1;
      continue;
    }
    const h = /^(#{1,3})\s+(.+)$/.exec(line);
    if (h) {
      flushPara();
      flushList();
      const n = h[1]!.length;
      out.push(`<h${n}>${inline(h[2]!)}</h${n}>`);
      i += 1;
      continue;
    }
    if (/^>\s?/.test(line)) {
      flushPara();
      flushList();
      const bits: string[] = [];
      while (i < lines.length && /^>\s?/.test(lines[i] ?? "")) {
        bits.push((lines[i] ?? "").replace(/^>\s?/, ""));
        i += 1;
      }
      out.push(`<blockquote>${bits.map((b) => `<p>${inline(b)}</p>`).join("")}</blockquote>`);
      continue;
    }
    const ul = /^\s*[-*+]\s+(.+)$/.exec(line);
    if (ul) {
      flushPara();
      if (!list || list.type !== "ul") {
        flushList();
        list = { type: "ul", items: [] };
      }
      list.items.push(ul[1]!);
      i += 1;
      continue;
    }
    const ol = /^\s*\d+[.)]\s+(.+)$/.exec(line);
    if (ol) {
      flushPara();
      if (!list || list.type !== "ol") {
        flushList();
        list = { type: "ol", items: [] };
      }
      list.items.push(ol[1]!);
      i += 1;
      continue;
    }
    flushList();
    para.push(line.trim());
    i += 1;
  }
  flushPara();
  flushList();
  flushTable();
  if (code) out.push(`<pre><code>${esc(code.join("\n"))}</code></pre>`);
  return out.join("\n");
}

export function markdownPage(src: string) {
  return `<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Markdown</title>
<style>
  html, body { margin: 0; background: #111214; color: #ece8df; }
  .md {
    max-width: 720px;
    margin: 0 auto;
    padding: 28px 22px 64px;
    font-family: ui-sans-serif, system-ui, sans-serif;
    font-size: 16px;
    line-height: 1.55;
  }
  .md h1 { font-size: 28px; line-height: 1.2; margin: 0 0 16px; letter-spacing: -0.03em; }
  .md h2 { font-size: 20px; margin: 28px 0 10px; }
  .md h3 { font-size: 16px; margin: 22px 0 8px; color: #c8c2b6; }
  .md p { margin: 0 0 12px; }
  .md ul, .md ol { margin: 0 0 14px; padding: 0 0 0 22px; }
  .md li { margin: 0 0 6px; }
  .md strong { font-weight: 700; }
  .md em { font-style: italic; color: #d9d3c7; }
  .md code {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 0.86em;
    background: #1c1d21;
    padding: 1px 6px;
    border-radius: 6px;
  }
  .md pre {
    margin: 0 0 16px;
    padding: 14px;
    border-radius: 12px;
    background: #1c1d21;
    overflow: auto;
  }
  .md pre code { background: none; padding: 0; font-size: 13px; }
  .md blockquote {
    margin: 0 0 16px;
    padding: 8px 14px;
    border-left: 3px solid #e4572e;
    color: #c8c2b6;
    background: #18191d;
    border-radius: 0 10px 10px 0;
  }
  .md table { width: 100%; border-collapse: collapse; margin: 0 0 18px; font-size: 14px; }
  .md th, .md td { border: 1px solid #2a2c31; padding: 8px 10px; text-align: left; }
  .md th { background: #1c1d21; }
  .md tr:nth-child(even) td { background: #16171b; }
  .md hr { border: 0; border-top: 1px solid #2a2c31; margin: 22px 0; }
  .md a { color: #7eb8ff; }
</style>
</head>
<body><article class="md">${renderMarkdown(src) || "<p>arquivo vazio</p>"}</article></body>
</html>`;
}

export function isMdPath(path: string) {
  return /\.(md|mdx|markdown)$/i.test(path);
}
