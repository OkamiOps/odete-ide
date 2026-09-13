import { jsxLanguage, javascriptLanguage, tsxLanguage, typescriptLanguage } from "@codemirror/lang-javascript";
import { cssLanguage } from "@codemirror/lang-css";
import { jsonLanguage } from "@codemirror/lang-json";
import { extOf } from "@/lib/utils";
import type { Diag } from "./plugins";

function lineOf(text: string, index: number) {
  return text.slice(0, Math.max(0, index)).split("\n").length;
}

function syntaxErrors(parser: { parse(input: string): { iterate(spec: { enter: (n: { type: { isError: boolean }; from: number; to: number }) => boolean | void }): void } }, path: string, text: string): Diag[] {
  const tree = parser.parse(text);
  const out: Diag[] = [];
  tree.iterate({
    enter(n) {
      if (!n.type.isError) return;
      const line = lineOf(text, n.from) || 1;
      const around = text
        .slice(Math.max(0, n.from - 8), Math.min(text.length, n.from + 24))
        .replace(/\s+/g, " ")
        .trim()
        .slice(0, 42);
      out.push({
        id: `${path}:syn:${n.from}`,
        path,
        line,
        message: around ? `sintaxe inválida perto de «${around}»` : "sintaxe inválida",
        severity: "error",
      });
      return false;
    },
  });
  return out.slice(0, 40);
}

function braceScan(text: string, open: string, close: string) {
  let n = 0;
  let inStr: string | null = null;
  let escape = false;
  let lineC = false;
  let block = false;
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? "";
    for (let j = 0; j < line.length; j++) {
      const ch = line[j]!;
      const next = line[j + 1];
      if (lineC) continue;
      if (block) {
        if (ch === "*" && next === "/") {
          block = false;
          j += 1;
        }
        continue;
      }
      if (inStr) {
        if (escape) {
          escape = false;
          continue;
        }
        if (ch === "\\") {
          escape = true;
          continue;
        }
        if (ch === inStr) inStr = null;
        continue;
      }
      if (ch === "/" && next === "/") {
        lineC = true;
        continue;
      }
      if (ch === "/" && next === "*") {
        block = true;
        j += 1;
        continue;
      }
      if (ch === "'" || ch === '"' || ch === "`") {
        inStr = ch;
        continue;
      }
      if (ch === open) n += 1;
      if (ch === close) n -= 1;
      if (n < 0) return i + 1;
    }
    lineC = false;
  }
  if (inStr) return lines.length;
  if (block) return lines.length;
  return n === 0 ? 0 : lines.length;
}

function lintJson(path: string, text: string): Diag[] {
  try {
    JSON.parse(text || "null");
    return [];
  } catch (e) {
    const msg = e instanceof Error ? e.message : "JSON inválido";
    const pos = /position\s+(\d+)/i.exec(msg);
    const lineTok = /line\s+(\d+)/i.exec(msg);
    const line = lineTok ? Number(lineTok[1]) : pos ? lineOf(text, Number(pos[1])) : 1;
    return [{ id: `${path}:json`, path, line, message: msg.replace(/^JSON\.parse:\s*/i, "").slice(0, 140), severity: "error" }];
  }
}

function lintJsStyle(path: string, text: string): Diag[] {
  const lines = text.split("\n");
  const semis = (text.match(/;/g) || []).length;
  if (semis < 8) return [];
  const out: Diag[] = [];
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i] ?? "";
    const t = raw.replace(/\/\/.*$/, "").trim();
    if (!t || t.startsWith("*") || t.startsWith("/*") || t.startsWith("#")) continue;
    if (/[,{\(\[\\]$/.test(t)) continue;
    if (/^(\}|\)|\])/.test(t)) continue;
    if (/^(else|catch|finally|do)\b/.test(t)) continue;
    if (t.startsWith("<") || t.endsWith(">") || t.endsWith("/>")) continue;
    if (/^(import |export |type |interface |enum |declare )/.test(t)) continue;
    if (/;$/.test(t) || /\{$/.test(t)) continue;
    if (/^(return|break|continue|throw|const |let |var |await |yield )\b/.test(t) || /^(if|for|while|switch|function|class)\b/.test(t)) {
      const next = (lines[i + 1] ?? "").trim();
      if (!next || next.startsWith("{") || next.startsWith("//")) continue;
      if (/^[(\[`+\-]/.test(next)) {
        out.push({
          id: `${path}:asi:${i}`,
          path,
          line: i + 1,
          message: "falta ';' — a próxima linha pode grudar nesta",
          severity: "warn",
        });
      } else if (/^(const |let |var |return |throw |await )/.test(t) && !t.endsWith(",") && !t.endsWith("{")) {
        out.push({
          id: `${path}:semi:${i}`,
          path,
          line: i + 1,
          message: `falta ';' no fim da linha`,
          severity: "warn",
        });
      }
    }
  }
  return out.slice(0, 20);
}

function lintCssExtra(path: string, text: string): Diag[] {
  const out: Diag[] = [];
  const lines = text.split("\n");
  let block = false;
  let str: string | null = null;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? "";
    let t = "";
    for (let j = 0; j < line.length; j++) {
      const ch = line[j]!;
      const next = line[j + 1];
      if (block) {
        if (ch === "*" && next === "/") {
          block = false;
          j += 1;
        }
        continue;
      }
      if (str) {
        if (ch === "\\") {
          j += 1;
          continue;
        }
        if (ch === str) str = null;
        continue;
      }
      if (ch === "/" && next === "*") {
        block = true;
        j += 1;
        continue;
      }
      if (ch === "/" && next === "/") break;
      if (ch === "'" || ch === '"') {
        str = ch;
        continue;
      }
      t += ch;
    }
    const s = t.trim();
    if (!s || s.startsWith("@") || s === "{" || s === "}") continue;
    const inner = s.includes("{")
      ? s.replace(/^[^{]*\{/, "").replace(/\}.*$/, "").trim()
      : s.endsWith("{")
        ? ""
        : s;
    if (!inner || inner.endsWith("{") || inner.endsWith(",") || inner.endsWith("(")) continue;
    if (inner.includes(":") && !inner.endsWith(";")) {
      const last = inner.split(";").pop()?.trim() ?? "";
      const prop = last.split(":")[0]!.trim();
      if (/^-?[\w-]+$/.test(prop) && last.split(":")[1]?.trim()) {
        out.push({
          id: `${path}:css-semi:${i}`,
          path,
          line: i + 1,
          message: `falta ';' depois de ${prop}`,
          severity: "error",
        });
      }
    }
  }
  if (block) out.push({ id: `${path}:css-com`, path, line: lines.length, message: "comentário /* sem fechar */", severity: "error" });
  if (str) out.push({ id: `${path}:css-str`, path, line: lines.length, message: "string sem fechar", severity: "error" });
  return out;
}

function lintSwift(path: string, text: string): Diag[] {
  const out: Diag[] = [];
  const brace = braceScan(text, "{", "}");
  if (brace) out.push({ id: `${path}:swift-brace`, path, line: brace, message: "chaves { } desbalanceadas", severity: "error" });
  const paren = braceScan(text, "(", ")");
  if (paren) out.push({ id: `${path}:swift-paren`, path, line: paren, message: "parênteses desbalanceados", severity: "error" });
  const brack = braceScan(text, "[", "]");
  if (brack) out.push({ id: `${path}:swift-brack`, path, line: brack, message: "colchetes [ ] desbalanceados", severity: "error" });

  const lines = text.split("\n");
  let block = false;
  let str: string | null = null;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? "";
    let code = "";
    for (let j = 0; j < line.length; j++) {
      const ch = line[j]!;
      const next = line[j + 1];
      if (block) {
        if (ch === "*" && next === "/") {
          block = false;
          j += 1;
        }
        continue;
      }
      if (str) {
        if (ch === "\\") {
          j += 1;
          continue;
        }
        if (ch === str) str = null;
        continue;
      }
      if (ch === "/" && next === "/") break;
      if (ch === "/" && next === "*") {
        block = true;
        j += 1;
        continue;
      }
      if (ch === '"') {
        str = '"';
        continue;
      }
      code += ch;
    }
    const t = code.trim();
    if (/^func\s+\w+/.test(t) && !t.includes("{") && !t.endsWith(",") && !t.endsWith(")")) {
      const nxt = (lines[i + 1] ?? "").trim();
      if (!nxt.startsWith("{") && !nxt.startsWith("where")) {
        out.push({ id: `${path}:swift-fn:${i}`, path, line: i + 1, message: "func sem corpo `{ … }`", severity: "error" });
      }
    }
    if (/^func\s+\w+\s*\([^)]*$/.test(t) && !t.includes("{")) {
      /* signature continua na próxima */
    }
    if (/^import\s*$/.test(t)) {
      out.push({ id: `${path}:swift-imp:${i}`, path, line: i + 1, message: "import sem módulo", severity: "error" });
    }
    if (/\bguard\b/.test(t) && !/\belse\b/.test(t) && !`${lines[i + 1] ?? ""}`.includes("else")) {
      if (t.includes("guard")) {
        out.push({ id: `${path}:swift-guard:${i}`, path, line: i + 1, message: "guard precisa de else", severity: "warn" });
      }
    }
  }
  if (block) out.push({ id: `${path}:swift-com`, path, line: lines.length, message: "comentário /* sem fechar */", severity: "error" });
  if (str) out.push({ id: `${path}:swift-str`, path, line: lines.length, message: "string sem fechar", severity: "error" });
  return out;
}

export function lintSyntaxFile(path: string, text: string): Diag[] {
  const ext = extOf(path);
  if (ext === "json" || ext === "webmanifest") {
    const parsed = lintJson(path, text);
    if (parsed.length) return parsed;
    return syntaxErrors(jsonLanguage.parser, path, text);
  }
  if (ext === "css" || ext === "scss") {
    return [...syntaxErrors(cssLanguage.parser, path, text), ...lintCssExtra(path, text)];
  }
  if (ext === "tsx") return [...syntaxErrors(tsxLanguage.parser, path, text), ...lintJsStyle(path, text)];
  if (ext === "jsx") return [...syntaxErrors(jsxLanguage.parser, path, text), ...lintJsStyle(path, text)];
  if (ext === "ts") return [...syntaxErrors(typescriptLanguage.parser, path, text), ...lintJsStyle(path, text)];
  if (ext === "js" || ext === "mjs" || ext === "cjs") {
    return [...syntaxErrors(javascriptLanguage.parser, path, text), ...lintJsStyle(path, text)];
  }
  if (ext === "swift") return lintSwift(path, text);
  return [];
}
