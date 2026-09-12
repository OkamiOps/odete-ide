import { keymap, Decoration, EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { RangeSetBuilder, Prec, type Extension } from "@codemirror/state";
import { hunksOf } from "./hunks";

export function changeLineMarks(before: string, after: string) {
  const out: { line: number; kind: "A" | "M" }[] = [];
  for (const h of hunksOf(before, after)) {
    const kind: "A" | "M" = h.dels.length ? "M" : "A";
    for (let i = 0; i < h.adds.length; i++) out.push({ line: h.afterStart + i, kind });
  }
  return out;
}

export function gitGutter(before: string, after: string): Extension {
  const marks = changeLineMarks(before, after);
  const add = Decoration.line({ class: "cm-git-line-A" });
  const mod = Decoration.line({ class: "cm-git-line-M" });
  return EditorView.decorations.of((view) => {
    const b = new RangeSetBuilder<Decoration>();
    for (const m of marks) {
      if (m.line < 1 || m.line > view.state.doc.lines) continue;
      b.add(view.state.doc.line(m.line).from, view.state.doc.line(m.line).from, m.kind === "A" ? add : mod);
    }
    return b.finish();
  });
}

export function todoMarks(): Extension {
  const mark = Decoration.mark({ class: "cm-todo-mark" });
  return Prec.highest(
    EditorView.decorations.of((view) => {
      const b = new RangeSetBuilder<Decoration>();
      const re = /\b(TODO|FIXME|HACK|XXX)\b/g;
      for (let n = 1; n <= view.state.doc.lines; n++) {
        const line = view.state.doc.line(n);
        re.lastIndex = 0;
        let m: RegExpExecArray | null;
        while ((m = re.exec(line.text))) {
          b.add(line.from + m.index, line.from + m.index + m[0].length, mark);
        }
      }
      return b.finish();
    }),
  );
}

const RB_MARK = [0, 1, 2, 3].map((i) => Decoration.mark({ class: `cm-rb-${i}` }));

export function rainbowBrackets(): Extension {
  return Prec.highest(
    ViewPlugin.fromClass(
      class {
        deco: ReturnType<typeof Decoration.set>;
        constructor(view: EditorView) {
          this.deco = buildRainbow(view);
        }
        update(u: ViewUpdate) {
          if (u.docChanged) this.deco = buildRainbow(u.view);
        }
      },
      { decorations: (v) => v.deco },
    ),
  );
}

function buildRainbow(view: EditorView) {
  const b = new RangeSetBuilder<Decoration>();
  const pairs: Record<string, string> = { "(": ")", "[": "]", "{": "}", "<": ">" };
  const close = new Set([")", "]", "}", ">"]);
  let depth = 0;
  let quote: string | null = null;
  let escape = false;
  let lineComment = false;
  let block = false;
  const text = view.state.doc.toString();
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]!;
    const next = text[i + 1];
    if (lineComment) {
      if (ch === "\n") lineComment = false;
      continue;
    }
    if (block) {
      if (ch === "*" && next === "/") {
        block = false;
        i += 1;
      }
      continue;
    }
    if (quote) {
      if (escape) {
        escape = false;
        continue;
      }
      if (ch === "\\") {
        escape = true;
        continue;
      }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === "/" && next === "/") {
      lineComment = true;
      i += 1;
      continue;
    }
    if (ch === "/" && next === "*") {
      block = true;
      i += 1;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === "`") {
      quote = ch;
      continue;
    }
    if (pairs[ch]) {
      b.add(i, i + 1, RB_MARK[depth % 4]!);
      depth += 1;
    } else if (close.has(ch)) {
      depth = Math.max(0, depth - 1);
      b.add(i, i + 1, RB_MARK[depth % 4]!);
    }
  }
  return b.finish();
}

export function expandEmmet(abbr: string): string | null {
  const raw = abbr.trim();
  if (!raw || raw.length > 80 || /\s/.test(raw)) return null;
  const parts = raw.split(">");
  if (parts.length > 3) return null;
  const render = (token: string, inner: string): string | null => {
    const m = /^([a-zA-Z][\w-]*)((?:[.#][\w-]+)*)(?:\*(\d+))?$/.exec(token);
    if (!m) return null;
    const tag = m[1]!;
    const extras = m[2] ?? "";
    const count = Math.min(12, Number(m[3] ?? "1") || 1);
    let id = "";
    const cls: string[] = [];
    for (const piece of extras.match(/[.#][\w-]+/g) ?? []) {
      if (piece.startsWith("#")) id = piece.slice(1);
      else cls.push(piece.slice(1));
    }
    const attrs = `${id ? ` id="${id}"` : ""}${cls.length ? ` class="${cls.join(" ")}"` : ""}`;
    const body = inner || "";
    const one = `<${tag}${attrs}>${body}</${tag}>`;
    if (count === 1) return one;
    return Array.from({ length: count }, () => one).join("\n");
  };
  let inner = "";
  for (let i = parts.length - 1; i >= 0; i--) {
    const next = render(parts[i]!, inner);
    if (!next) return null;
    inner = i === 0 ? next : `\n  ${next.replace(/\n/g, "\n  ")}\n`;
  }
  return inner;
}

export function emmetTab(): Extension {
  return Prec.high(
    keymap.of([
      {
        key: "Tab",
        run: (view) => {
          const sel = view.state.selection.main;
          if (sel.from !== sel.to) return false;
          const line = view.state.doc.lineAt(sel.head);
          const before = line.text.slice(0, sel.head - line.from);
          const m = /([^\s]+)$/.exec(before);
          if (!m) return false;
          const expanded = expandEmmet(m[1]!);
          if (!expanded) return false;
          const from = sel.head - m[1]!.length;
          view.dispatch({
            changes: { from, to: sel.head, insert: expanded },
            selection: { anchor: from + expanded.length },
          });
          return true;
        },
      },
    ]),
  );
}

function isHeader(t: string) {
  if (!t) return false;
  if (t.startsWith("//") || t.startsWith("/*") || t.startsWith("*") || t.startsWith("}")) return false;
  if (/^(function |class |export |struct |enum |protocol |func |extension |type |interface )/.test(t)) return true;
  if (/^#{1,6}\s+\S/.test(t)) return true;
  if (/^<\/?[A-Za-z][\w:-]*([\s>/]|$)/.test(t)) return true;
  if (/^@(media|keyframes|supports|layer|container|font-face)\b/.test(t)) return true;
  if (/^:root\b/.test(t)) return true;
  if (/^[.#]?[\w-]+(\s*,\s*[.#:]?[\w-]+)*\s*\{/.test(t)) return true;
  return false;
}

function stickyLabel(view: EditorView) {
  if (!view.state.doc.length) return "";
  if (view.scrollDOM.scrollTop < 6) return "";
  const r = view.scrollDOM.getBoundingClientRect();
  const pos = view.posAtCoords({ x: r.left + Math.min(72, Math.max(24, r.width * 0.35)), y: r.top + 6 });
  if (pos == null) return "";
  const topLine = view.state.doc.lineAt(pos);
  for (let n = topLine.number - 1; n >= 1; n--) {
    const t = view.state.doc.line(n).text.trim();
    if (isHeader(t)) return t.slice(0, 88);
  }
  return "";
}

export function stickyContext(): Extension {
  return ViewPlugin.fromClass(
    class {
      bar: HTMLDivElement;
      scroller: HTMLElement;
      onScroll: () => void;
      constructor(view: EditorView) {
        this.bar = document.createElement("div");
        this.bar.className = "cm-sticky-bar";
        this.bar.hidden = true;
        view.dom.appendChild(this.bar);
        this.scroller = view.scrollDOM;
        this.onScroll = () => requestAnimationFrame(() => this.render(view));
        this.scroller.addEventListener("scroll", this.onScroll, { passive: true });
        this.render(view);
      }
      update(u: ViewUpdate) {
        if (u.docChanged || u.viewportChanged || u.geometryChanged) this.render(u.view);
      }
      render(view: EditorView) {
        try {
          const label = stickyLabel(view);
          this.bar.hidden = !label;
          this.bar.textContent = label;
        } catch {
          this.bar.hidden = true;
        }
      }
      destroy() {
        this.scroller.removeEventListener("scroll", this.onScroll);
        this.bar.remove();
      }
    },
  );
}
