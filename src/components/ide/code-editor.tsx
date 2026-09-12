import { useEffect, useMemo, useRef, useState, type PointerEvent as PE, type RefObject } from "react";
import { EditorView, Decoration, highlightTrailingWhitespace, highlightWhitespace, keymap } from "@codemirror/view";
import { EditorState, RangeSetBuilder } from "@codemirror/state";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { highlightSelectionMatches, search, SearchQuery, setSearchQuery, findNext, findPrevious, replaceNext, replaceAll } from "@codemirror/search";
import { startCompletion } from "@codemirror/autocomplete";
import { tags as t } from "@lezer/highlight";
import { Check, X } from "lucide-react";
import { extOf } from "@/lib/utils";
import { usePatches } from "@/lib/agent/patches";
import { chipsFor, coloCompletions } from "@/lib/workspace/complete";
import { linter, lintGutter } from "@codemirror/lint";
import { lintFile } from "@/lib/workspace/plugins";
import { emmetTab, extractColors, gitGutter, lineComment, rainbowBrackets, stickyContext, todoMarks, urlMarks } from "@/lib/workspace/editor-plugins";
import { useChrome } from "@/lib/workspace/chrome";
import { addedLines, hunksOf } from "@/lib/workspace/hunks";
import { useHistory } from "@/lib/workspace/history";
import { indentGuides } from "@/lib/workspace/indent-guides";
import { setActiveView, useNav } from "@/lib/workspace/nav";
import { themeById } from "@/lib/workspace/themes";
import { useWorkspace } from "@/lib/workspace/store";

const syn = syntaxHighlighting(
  HighlightStyle.define([
    { tag: t.keyword, color: "var(--syn-keyword)" },
    { tag: t.controlKeyword, color: "var(--syn-keyword)" },
    { tag: t.definitionKeyword, color: "var(--syn-keyword)" },
    { tag: t.operatorKeyword, color: "var(--syn-keyword)" },
    { tag: t.moduleKeyword, color: "var(--syn-keyword)" },
    { tag: t.string, color: "var(--syn-string)" },
    { tag: t.comment, color: "var(--syn-comment)", fontStyle: "italic" },
    { tag: t.lineComment, color: "var(--syn-comment)", fontStyle: "italic" },
    { tag: t.blockComment, color: "var(--syn-comment)", fontStyle: "italic" },
    { tag: t.number, color: "var(--syn-number)" },
    { tag: t.bool, color: "var(--syn-number)" },
    { tag: t.null, color: "var(--syn-number)" },
    { tag: t.function(t.variableName), color: "var(--syn-func)" },
    { tag: t.function(t.propertyName), color: "var(--syn-func)" },
    { tag: t.definition(t.variableName), color: "var(--syn-func)" },
    { tag: t.typeName, color: "var(--syn-type)" },
    { tag: t.className, color: "var(--syn-type)" },
    { tag: t.propertyName, color: "var(--color-fg)" },
    { tag: t.variableName, color: "var(--color-fg)" },
    { tag: t.operator, color: "var(--syn-keyword)" },
    { tag: t.tagName, color: "var(--syn-keyword)" },
    { tag: t.angleBracket, color: "var(--syn-comment)" },
    { tag: t.attributeName, color: "var(--syn-number)" },
    { tag: t.heading, color: "var(--syn-keyword)", fontWeight: "600" },
    { tag: t.link, color: "var(--syn-func)" },
    { tag: t.url, color: "var(--syn-func)" },
    { tag: t.emphasis, fontStyle: "italic" },
    { tag: t.strong, fontWeight: "600" },
    { tag: t.processingInstruction, color: "var(--syn-comment)" },
    { tag: t.meta, color: "var(--syn-comment)" },
    { tag: t.punctuation, color: "var(--color-fg-muted)" },
    { tag: t.bracket, color: "var(--color-fg-muted)" },
  ]),
);

type CmMod = typeof import("@uiw/react-codemirror");
type LangMod = {
  javascript?: typeof import("@codemirror/lang-javascript").javascript;
  html?: typeof import("@codemirror/lang-html").html;
  css?: typeof import("@codemirror/lang-css").css;
  markdown?: typeof import("@codemirror/lang-markdown").markdown;
  json?: typeof import("@codemirror/lang-json").json;
};
type AcMod = { autocompletion?: typeof import("@codemirror/autocomplete").autocompletion };

const EMPTY_SNAPS: { at: number; text: string }[] = [];

function languageFor(path: string, langs: LangMod) {
  const ext = extOf(path);
  if (ext === "html" && langs.html) return langs.html({ autoCloseTags: true });
  if (ext === "css" && langs.css) return langs.css();
  if ((ext === "json" || ext === "webmanifest") && langs.json) return langs.json();
  if ((ext === "md" || ext === "mdx") && langs.markdown) return langs.markdown();
  if (langs.javascript) {
    return langs.javascript({
      jsx: ext === "jsx" || ext === "tsx",
      typescript: ext === "ts" || ext === "tsx" || ext === "swift",
    });
  }
  return [];
}

export function CodeEditor({ path }: { path?: string }) {
  const openPath = useWorkspace((s) => s.openPath);
  const files = useWorkspace((s) => s.files);
  const writeFile = useWorkspace((s) => s.writeFile);
  const wrap = useChrome((s) => s.pluginWrap);
  const space = useChrome((s) => s.pluginSpace);
  const indent = useChrome((s) => s.pluginIndent);
  const lineNo = useChrome((s) => s.pluginLineNo);
  const ruler = useChrome((s) => s.pluginRuler);
  const fold = useChrome((s) => s.pluginFold);
  const minimap = useChrome((s) => s.minimap);
  const center = useChrome((s) => s.center);
  const colorHint = useChrome((s) => s.pluginColorHint);
  const gitOn = useChrome((s) => s.pluginGitGutter);
  const todoOn = useChrome((s) => s.pluginTodoMark);
  const rainbowOn = useChrome((s) => s.pluginRainbow);
  const emmetOn = useChrome((s) => s.pluginEmmet);
  const stickyOn = useChrome((s) => s.pluginSticky);
  const commentOn = useChrome((s) => s.pluginComment);
  const urlsOn = useChrome((s) => s.pluginUrls);
  const findOpen = useChrome((s) => s.findOpen);
  const linterOn = useChrome((s) => s.pluginLinter);
  const themeId = useChrome((s) => s.theme);
  const dark = themeById(themeId).dark;
  const active = path ?? openPath;
  const value = files[active] ?? "";
  const viewRef = useRef<EditorView | null>(null);
  const pending = usePatches((s) => s.items.find((p) => p.status === "pending" && p.path === active) ?? null);
  const jumpN = useNav((s) => s.n);
  const jumpPath = useNav((s) => s.path);
  const jumpLine = useNav((s) => s.line);
  const blameOn = useNav((s) => s.blame);
  const histOn = useNav((s) => s.hist);
  const snaps = useHistory((s) => s.byPath[active] ?? EMPTY_SNAPS);
  const shown = pending ? pending.after : value;
  const commits = useWorkspace((s) => s.commits);
  const headBody = commits.at(-1)?.files[active] ?? "";
  const blameRows = useMemo(
    () => (blameOn ? useWorkspace.getState().gitBlame(active) : []),
    [blameOn, active, commits, value],
  );

  const [cm, setCm] = useState<CmMod | null>(null);
  const [langs, setLangs] = useState<LangMod>({});
  const [ac, setAc] = useState<AcMod>({});

  const chromeTheme = useMemo(
    () =>
      EditorView.theme(
        {
          "&": {
            backgroundColor: "var(--color-bg)",
            color: "var(--color-fg)",
            height: "100%",
          },
          ".cm-scroller": { overflow: "auto" },
          ".cm-gutters": {
            backgroundColor: "var(--color-bg)",
            color: "var(--color-fg-subtle)",
            border: "none",
          },
          ".cm-activeLine": { backgroundColor: "var(--color-bg-elevated)" },
          ".cm-activeLineGutter": {
            backgroundColor: "var(--color-bg-elevated)",
            color: "var(--color-fg-muted)",
          },
          ".cm-patch-add": {
            backgroundColor: "color-mix(in srgb, var(--color-ok) 18%, transparent)",
          },
          "&.cm-focused .cm-cursor": { borderLeftColor: "var(--color-accent)" },
          ".cm-selectionBackground": {
            backgroundColor: "color-mix(in srgb, var(--color-accent) 45%, transparent) !important",
          },
          "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground": {
            backgroundColor: "color-mix(in srgb, var(--color-accent) 45%, transparent) !important",
          },
          ".cm-selectionLayer .cm-selectionBackground": {
            backgroundColor: "color-mix(in srgb, var(--color-accent) 45%, transparent) !important",
          },
          ".cm-scroller ::selection, .cm-content ::selection": {
            backgroundColor: "color-mix(in srgb, var(--color-accent) 55%, var(--color-bg)) !important",
            color: "var(--color-fg) !important",
          },
          ".cm-content": { caretColor: "var(--color-accent)" },
          ".cm-highlightSpace": {
            backgroundImage:
              "radial-gradient(circle at 50% 55%, var(--color-fg-subtle) 0.85px, transparent 1px)",
            backgroundPosition: "center",
            backgroundRepeat: "no-repeat",
            backgroundSize: "0.55em 0.85em",
          },
          ".cm-highlightTab": {
            backgroundImage:
              "linear-gradient(to right, var(--color-fg-subtle) 0 1px, transparent 1px), linear-gradient(to bottom, transparent 40%, var(--color-fg-subtle) 40% 60%, transparent 60%)",
            backgroundSize: "1.8em 100%",
            backgroundRepeat: "no-repeat",
          },
        },
        { dark },
      ),
    [dark],
  );

  useEffect(() => {
    let alive = true;
    void Promise.all([
      import("@uiw/react-codemirror"),
      import("@codemirror/lang-javascript"),
      import("@codemirror/lang-html"),
      import("@codemirror/lang-css"),
      import("@codemirror/lang-markdown"),
      import("@codemirror/lang-json"),
      import("@codemirror/autocomplete"),
    ]).then(([mod, js, html, css, md, json, auto]) => {
      if (!alive) return;
      setCm(mod);
      setLangs({
        javascript: js.javascript,
        html: html.html,
        css: css.css,
        markdown: md.markdown,
        json: json.json,
      });
      setAc({ autocompletion: auto.autocompletion });
    });
    return () => {
      alive = false;
    };
  }, []);

  const patchDeco = useMemo(() => {
    if (!pending) return [];
    const lines = addedLines(pending.before, pending.after);
    const mark = Decoration.line({ class: "cm-patch-add" });
    return EditorView.decorations.of((view) => {
      const b = new RangeSetBuilder<Decoration>();
      for (const n of lines) {
        if (n < 1 || n > view.state.doc.lines) continue;
        const from = view.state.doc.line(n).from;
        b.add(from, from, mark);
      }
      return b.finish();
    });
  }, [pending]);

  useEffect(() => {
    if (!jumpN || jumpPath !== active) return;
    const view = viewRef.current;
    if (!view) return;
    const line = Math.min(Math.max(1, jumpLine), view.state.doc.lines);
    const pos = view.state.doc.line(line).from;
    view.dispatch({
      selection: { anchor: pos },
      effects: EditorView.scrollIntoView(pos, { y: "center" }),
    });
    view.focus();
  }, [jumpN, jumpPath, jumpLine, active, cm]);

  if (!cm) {
    return (
      <pre className="h-full overflow-auto p-4 font-mono text-sm leading-relaxed text-fg-muted">
        {value || "arquivo vazio"}
      </pre>
    );
  }

  const Editor = cm.default;
  const mapOn = !path && minimap !== "off" && center !== "dual";
  const uniqueColors = colorHint ? extractColors(value) : [];
  const chips = chipsFor(active);
  function insertChip(text: string) {
    const view = viewRef.current;
    if (!view) {
      writeFile(active, `${value}${value && !value.endsWith("\n") ? "\n" : ""}${text}`);
      return;
    }
    const { from, to } = view.state.selection.main;
    view.dispatch({
      changes: { from, to, insert: text },
      selection: { anchor: from + text.length },
    });
    view.focus();
  }
  return (
    <div className={mapOn ? `code-wrap has-map is-${minimap}` : "code-wrap"}>
      {findOpen && !path ? <FindBar viewRef={viewRef} /> : null}
      <div className="code-stage">
      <Editor
        key={`${active}:${themeId}:${lineNo}:${fold}:${pending?.id ?? "x"}`}
        value={shown}
        height="100%"
        theme="none"
        extensions={[
          chromeTheme,
          syn,
          wrap ? EditorView.lineWrapping : [],
          space ? [highlightWhitespace(), highlightTrailingWhitespace()] : [],
          indent ? indentGuides() : [],
          highlightSelectionMatches(),
          search(),
          ruler
            ? EditorView.theme({
                ".cm-content": {
                  backgroundImage:
                    "linear-gradient(to right, transparent 80ch, var(--color-border-strong) 80ch, var(--color-border-strong) calc(80ch + 1px), transparent calc(80ch + 1px))",
                  backgroundAttachment: "local",
                },
              })
            : [],
          languageFor(active, langs),
          EditorState.languageData.of(() => [{ autocomplete: coloCompletions(active) }]),
          ac.autocompletion
            ? ac.autocompletion({ activateOnTyping: true, icons: true })
            : [],
          keymap.of([
            {
              key: "Ctrl-Space",
              run: startCompletion,
            },
          ]),
          gitOn ? gitGutter(headBody, shown) : [],
          todoOn ? todoMarks() : [],
          rainbowOn ? rainbowBrackets() : [],
          emmetOn ? emmetTab() : [],
          stickyOn ? stickyContext() : [],
          commentOn ? lineComment(active) : [],
          urlsOn ? urlMarks() : [],
          linterOn ? [lintGutter(), fileLinter(active), lintLineMarks(active, shown)] : [],
          patchDeco,
        ].flat()}
        basicSetup={{
          lineNumbers: lineNo,
          foldGutter: fold,
          highlightActiveLine: true,
          syntaxHighlighting: false,
          bracketMatching: true,
          closeBrackets: true,
          autocompletion: true,
        }}
        onCreateEditor={(view) => {
          viewRef.current = view;
          setActiveView(view);
        }}
        onChange={(next) => {
          if (pending) usePatches.getState().accept(pending.id);
          writeFile(active, next);
        }}
      />
      </div>
      <div className="ed-tools">
        {pending ? (
          <div className="patch-bar-ed">
            <span>Agente em {active.split("/").pop()}</span>
            <button type="button" onClick={() => usePatches.getState().accept(pending.id)}>
              <Check size={14} /> aceitar
            </button>
            <button type="button" onClick={() => usePatches.getState().reject(pending.id)}>
              <X size={14} /> rejeitar
            </button>
            {hunksOf(pending.before, pending.after).map((h, i) => (
              <button
                key={h.id}
                type="button"
                onClick={() => useNav.getState().go(active, h.afterStart)}
              >
                hunk {i + 1}
              </button>
            ))}
          </div>
        ) : null}
        {chips.length ? (
          <div className="snip-bar" role="toolbar" aria-label="snippets">
            {chips.map((c) => (
              <button key={c.id} type="button" onClick={() => insertChip(c.insert)}>
                {c.label}
              </button>
            ))}
          </div>
        ) : null}
        {histOn ? (
          <div className="hist-list">
            {snaps.length === 0 ? (
              <p>sem histórico ainda</p>
            ) : (
              snaps.map((s) => (
                <button
                  key={s.at}
                  type="button"
                  onClick={() => useHistory.getState().restore(active, s.at)}
                >
                  {new Date(s.at).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit", second: "2-digit" })}
                  <span>{s.text.split("\n").length} linhas</span>
                </button>
              ))
            )}
          </div>
        ) : null}
        {blameOn ? (
          <div className="blame-list">
            {blameRows.slice(0, 48).map((r) => (
              <button key={r.line} type="button" onClick={() => useNav.getState().go(active, r.line)}>
                <code>{r.id}</code>
                <b>{r.line}</b>
                <span>{r.text.slice(0, 48)}</span>
              </button>
            ))}
          </div>
        ) : null}
      </div>
      {mapOn ? <MiniMap text={shown} path={active} linter={linterOn} viewRef={viewRef} size={minimap} /> : null}
      {uniqueColors.length ? (
        <div className="color-hints">
          {uniqueColors.map((c) => (
            <span key={c} title={c} style={{ background: c }} />
          ))}
        </div>
      ) : null}
    </div>
  );
}

function lintLineMarks(path: string, text: string) {
  const diags = lintFile(path, text);
  const err = Decoration.line({ class: "cm-lint-error" });
  const warn = Decoration.line({ class: "cm-lint-warn" });
  return EditorView.decorations.of((view) => {
    const b = new RangeSetBuilder<Decoration>();
    const seen = new Set<number>();
    for (const d of diags) {
      if (d.line < 1 || d.line > view.state.doc.lines || seen.has(d.line)) continue;
      seen.add(d.line);
      const from = view.state.doc.line(d.line).from;
      b.add(from, from, d.severity === "error" ? err : warn);
    }
    return b.finish();
  });
}

function fileLinter(path: string) {
  return linter(
    (view) => {
      const text = view.state.doc.toString();
      return lintFile(path, text).map((d) => {
        const n = Math.min(Math.max(1, d.line), view.state.doc.lines);
        const line = view.state.doc.line(n);
        return {
          from: line.from,
          to: line.to,
          severity: d.severity === "error" ? ("error" as const) : ("warning" as const),
          message: d.message,
        };
      });
    },
    { delay: 200 },
  );
}

function FindBar({ viewRef }: { viewRef: RefObject<EditorView | null> }) {
  const [q, setQ] = useState("");
  const [rep, setRep] = useState("");
  function run(fn: (v: EditorView) => boolean) {
    const v = viewRef.current;
    if (!v) return;
    v.dispatch({ effects: setSearchQuery.of(new SearchQuery({ search: q, replace: rep, caseSensitive: false })) });
    fn(v);
    v.focus();
  }
  return (
    <div className="find-bar">
      <input
        autoFocus
        value={q}
        placeholder="buscar"
        onChange={(e) => setQ(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            run(e.shiftKey ? findPrevious : findNext);
          }
          if (e.key === "Escape") useChrome.getState().setFindOpen(false);
        }}
      />
      <input
        value={rep}
        placeholder="substituir"
        onChange={(e) => setRep(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            run(replaceNext);
          }
          if (e.key === "Escape") useChrome.getState().setFindOpen(false);
        }}
      />
      <button type="button" onClick={() => run(findPrevious)}>
        ↑
      </button>
      <button type="button" onClick={() => run(findNext)}>
        ↓
      </button>
      <button type="button" onClick={() => run(replaceNext)}>
        um
      </button>
      <button type="button" onClick={() => run(replaceAll)}>
        todos
      </button>
      <button type="button" aria-label="fechar busca" onClick={() => useChrome.getState().setFindOpen(false)}>
        <X size={14} />
      </button>
    </div>
  );
}

const MAP_UNIT = { s: 2.2, m: 3.6, l: 5.4 } as const;
const MAP_FONT = { s: 1.8, m: 2.9, l: 4.4 } as const;

function MiniMap({
  text,
  path,
  linter,
  viewRef,
  size,
}: {
  text: string;
  path: string;
  linter: boolean;
  viewRef: RefObject<EditorView | null>;
  size: "s" | "m" | "l";
}) {
  const box = useRef<HTMLDivElement>(null);
  const pre = useRef<HTMLPreElement>(null);
  const shift = useRef(0);
  const [vp, setVp] = useState({ top: 0, h: 24, off: 0 });
  const marks = linter ? lintFile(path, text) : [];

  function layout() {
    const map = box.current;
    const node = pre.current;
    const view = viewRef.current;
    if (!map || !node) return;
    const lines = Math.max(1, view?.state.doc.lines ?? text.split("\n").length);
    const mapH = map.clientHeight;
    const lh = MAP_UNIT[size];
    const fs = MAP_FONT[size];
    const contentH = lines * lh;
    node.style.lineHeight = `${lh}px`;
    node.style.fontSize = `${fs}px`;
    node.style.height = `${contentH}px`;
    node.style.width = "100%";

    let from = 1;
    let to = Math.min(lines, Math.ceil(mapH / lh));
    if (view) {
      const sr = view.scrollDOM.getBoundingClientRect();
      const nums: number[] = [];
      view.scrollDOM.querySelectorAll(".cm-lineNumbers .cm-gutterElement").forEach((n) => {
        const r = n.getBoundingClientRect();
        if (r.bottom <= sr.top + 1 || r.top >= sr.bottom - 1) return;
        const v = Number(n.textContent);
        if (v > 0) nums.push(v);
      });
      if (nums.length) {
        from = Math.min(...nums);
        to = Math.max(...nums);
      } else {
        const cr = view.contentDOM.getBoundingClientRect();
        const x = cr.left + Math.min(16, Math.max(4, cr.width * 0.15));
        const start = view.posAtCoords({ x, y: sr.top + 2 });
        const end = view.posAtCoords({ x, y: sr.bottom - 2 });
        from = start == null ? 1 : view.state.doc.lineAt(start).number;
        to = end == null ? lines : view.state.doc.lineAt(end).number;
      }
    }

    const vpTop = (from - 1) * lh;
    const vpH = Math.max(lh * 2, (to - from + 1) * lh);
    let offset = 0;
    if (contentH > mapH) {
      const center = vpTop + vpH / 2;
      offset = Math.min(0, Math.max(mapH - contentH, mapH / 2 - center));
    }
    shift.current = offset;
    node.style.transform = `translateY(${offset}px)`;
    setVp({ top: vpTop + offset, h: Math.min(vpH, mapH), off: offset });
  }

  useEffect(() => {
    layout();
    const map = box.current;
    const ro = map ? new ResizeObserver(() => layout()) : null;
    if (map) ro?.observe(map);
    const view = viewRef.current;
    view?.scrollDOM.addEventListener("scroll", layout);
    const id = window.setInterval(layout, 200);
    return () => {
      ro?.disconnect();
      view?.scrollDOM.removeEventListener("scroll", layout);
      window.clearInterval(id);
    };
  }, [text, size, viewRef]);

  function jumpTo(clientY: number) {
    const view = viewRef.current;
    const map = box.current;
    if (!view || !map) return;
    const lines = view.state.doc.lines;
    const lh = MAP_UNIT[size];
    const contentH = lines * lh;
    const y = clientY - map.getBoundingClientRect().top - shift.current;
    const ratio = Math.max(0, Math.min(0.999, y / Math.max(contentH, 1)));
    const line = Math.max(1, Math.min(lines, Math.floor(ratio * lines) + 1));
    view.dispatch({
      effects: EditorView.scrollIntoView(view.state.doc.line(line).from, { y: "start" }),
    });
    view.focus();
    window.requestAnimationFrame(layout);
  }

  function onPointerDown(e: PE<HTMLDivElement>) {
    e.currentTarget.setPointerCapture(e.pointerId);
    jumpTo(e.clientY);
  }

  function onPointerMove(e: PE<HTMLDivElement>) {
    if (!e.currentTarget.hasPointerCapture(e.pointerId)) return;
    jumpTo(e.clientY);
  }

  return (
    <div
      ref={box}
      className={`minimap is-${size}`}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      title="Minimap — arrasta pra navegar"
    >
      <pre ref={pre}>{text}</pre>
      {marks.map((d) => (
        <i
          key={d.id}
          className={`minimap-lint is-${d.severity}`}
          style={{ top: (d.line - 1) * MAP_UNIT[size] + vp.off }}
        />
      ))}
      <i className="minimap-vp" style={{ top: vp.top, height: vp.h }} />
    </div>
  );
}
