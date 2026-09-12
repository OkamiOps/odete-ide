import { extOf } from "@/lib/utils";
import type { FileMap } from "./types";

export type PluginId =
  | "linter"
  | "todos"
  | "wrap"
  | "formatOnSave"
  | "breadcrumbs"
  | "whitespace"
  | "indent"
  | "lineNo"
  | "ruler"
  | "fold"
  | "colorHint"
  | "gitGutter"
  | "todoMark"
  | "rainbow"
  | "emmet"
  | "sticky"
  | "comment"
  | "urls";

export const PLUGINS: { id: PluginId; label: string; blurb: string }[] = [
  { id: "linter", label: "Linter", blurb: "JSON, JS, HTML, CSS e Swift com linha." },
  { id: "todos", label: "TODOs", blurb: "TODO, FIXME e HACK no workspace." },
  { id: "wrap", label: "Quebra de linha", blurb: "Word wrap no editor." },
  { id: "formatOnSave", label: "Formatar no ⌘S", blurb: "Indenta JSON e limpa espaços." },
  { id: "breadcrumbs", label: "Breadcrumbs", blurb: "Caminho do arquivo no topo." },
  { id: "whitespace", label: "Espaços visíveis", blurb: "Mostra espaço e tab no fim da linha." },
  { id: "indent", label: "Guias de indentação", blurb: "Marca o nível no gutter — desligado por padrão." },
  { id: "lineNo", label: "Números de linha", blurb: "Gutter com 1, 2, 3…" },
  { id: "ruler", label: "Régua 80", blurb: "Linha vertical em 80 colunas." },
  { id: "fold", label: "Fold", blurb: "Encolher blocos no gutter." },
  { id: "colorHint", label: "Preview de cor", blurb: "Mostra hex #rrggbb no CSS." },
  { id: "gitGutter", label: "Git no gutter", blurb: "Faixa verde/âmbar nas linhas mudadas." },
  { id: "todoMark", label: "Marca TODO", blurb: "Pinta TODO/FIXME no código." },
  { id: "rainbow", label: "Brackets coloridos", blurb: "Cada nível de () [] {} numa cor." },
  { id: "emmet", label: "Emmet", blurb: "Tab em div.card vira HTML." },
  { id: "sticky", label: "Sticky scroll", blurb: "Mostra a função/tag do topo da tela." },
  { id: "comment", label: "Comentar linha", blurb: "⌘/ comenta ou descomenta a seleção." },
  { id: "urls", label: "URLs", blurb: "Sublinha http(s) no código." },
];

export type Diag = {
  id: string;
  path: string;
  line: number;
  message: string;
  severity: "error" | "warn" | "todo";
};

function lineOf(text: string, index: number) {
  return text.slice(0, Math.max(0, index)).split("\n").length;
}

function braceLine(text: string, open: string, close: string) {
  let n = 0;
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    for (const ch of lines[i] ?? "") {
      if (ch === open) n += 1;
      if (ch === close) n -= 1;
      if (n < 0) return i + 1;
    }
  }
  return n === 0 ? 0 : lines.length;
}

export function lintFile(path: string, text: string): Diag[] {
  const out: Diag[] = [];
  const ext = extOf(path);
  if (ext === "json" || ext === "webmanifest") {
    try {
      JSON.parse(text || "null");
    } catch (e) {
      const msg = e instanceof Error ? e.message : "JSON inválido";
      const m = /position\s+(\d+)/i.exec(msg);
      const line = m ? lineOf(text, Number(m[1])) : 1;
      out.push({ id: `${path}:json`, path, line, message: msg, severity: "error" });
    }
  }
  if (["js", "jsx", "mjs", "cjs"].includes(ext)) {
    const stripped = text
      .replace(/^\s*import\s+[\s\S]*?from\s+['"][^'"]+['"]\s*;?/gm, "")
      .replace(/^\s*import\s+['"][^'"]+['"]\s*;?/gm, "")
      .replace(/^\s*export\s+\{[\s\S]*?\}\s*;?/gm, "")
      .replace(/^\s*export\s+(default\s+)?/gm, "");
    try {
      // parse only — Function is not invoked
      // eslint-disable-next-line no-new-func
      new Function(stripped);
    } catch (e) {
      const msg = e instanceof Error ? e.message : "JS inválido";
      const m = /:(\d+)/.exec(msg);
      out.push({
        id: `${path}:js`,
        path,
        line: m ? Number(m[1]) : 1,
        message: msg.replace(/^[\w]*Error:\s*/, "").slice(0, 120),
        severity: "error",
      });
    }
  }
  if (["js", "jsx", "ts", "tsx", "css", "json", "swift"].includes(ext)) {
    const brace = braceLine(text, "{", "}");
    if (brace) {
      out.push({ id: `${path}:brace`, path, line: brace, message: "chaves { } desbalanceadas", severity: "error" });
    }
    const paren = braceLine(text, "(", ")");
    if (paren) {
      out.push({ id: `${path}:paren`, path, line: paren, message: "parênteses desbalanceados", severity: "warn" });
    }
  }
  if (ext === "css") {
    if (text.includes("/*") && !text.includes("*/")) {
      out.push({ id: `${path}:css-com`, path, line: 1, message: "comentário CSS sem fechar", severity: "error" });
    }
  }
  if (ext === "html") {
    const voidTags = new Set(["br", "img", "input", "meta", "link", "hr", "source", "area", "base", "col", "embed", "wbr"]);
    const stack: { tag: string; line: number }[] = [];
    const re = /<!--[\s\S]*?-->|<\/?([a-zA-Z][\w-]*)\b[^>]*>/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(text))) {
      if (m[0].startsWith("<!--")) continue;
      const tag = m[1]!.toLowerCase();
      const line = lineOf(text, m.index);
      if (voidTags.has(tag) || m[0].endsWith("/>")) continue;
      if (m[0].startsWith("</")) {
        const last = stack.pop();
        if (!last) {
          out.push({ id: `${path}:html-x${m.index}`, path, line, message: `</${tag}> sem abertura`, severity: "warn" });
        } else if (last.tag !== tag) {
          out.push({
            id: `${path}:html-m${m.index}`,
            path,
            line,
            message: `fechou </${tag}> mas o aberto era <${last.tag}>`,
            severity: "error",
          });
        }
      } else {
        stack.push({ tag, line });
      }
    }
    for (const s of stack.slice(-4)) {
      out.push({ id: `${path}:html-o${s.line}`, path, line: s.line, message: `<${s.tag}> sem fechar`, severity: "warn" });
    }
  }
  if (ext === "swift") {
    if (/\bfunc\s+\w+[^{]*$/.test(text) && !text.includes("{")) {
      out.push({ id: `${path}:swift-fn`, path, line: 1, message: "func sem corpo", severity: "warn" });
    }
  }
  return out;
}

export function findTodos(path: string, text: string): Diag[] {
  const out: Diag[] = [];
  const re = /\b(TODO|FIXME|HACK|XXX)\b[:\s]?(.*)$/gm;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text))) {
    out.push({
      id: `${path}:${m.index}`,
      path,
      line: lineOf(text, m.index),
      message: `${m[1]} ${m[2]?.trim() || ""}`.trim(),
      severity: "todo",
    });
  }
  return out;
}

export function collectDiags(
  files: FileMap,
  opts: { linter: boolean; todos: boolean },
): Diag[] {
  const out: Diag[] = [];
  for (const [path, text] of Object.entries(files)) {
    if (opts.linter) out.push(...lintFile(path, text));
    if (opts.todos) out.push(...findTodos(path, text));
  }
  return out.sort((a, b) => a.path.localeCompare(b.path) || a.line - b.line);
}

export function formatFile(path: string, text: string) {
  const ext = extOf(path);
  if (ext === "json" || ext === "webmanifest") {
    try {
      return `${JSON.stringify(JSON.parse(text), null, 2)}\n`;
    } catch {
      return text;
    }
  }
  const lines = text.replace(/\t/g, "  ").replace(/[ \t]+$/gm, "");
  return lines.endsWith("\n") ? lines : `${lines}\n`;
}
