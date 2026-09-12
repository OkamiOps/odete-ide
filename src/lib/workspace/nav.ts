import { create } from "zustand";
import type { EditorView } from "@codemirror/view";

let view: EditorView | null = null;

export function setActiveView(v: EditorView | null) {
  view = v;
}

export function activeView() {
  return view;
}

export const useNav = create<{
  path: string;
  line: number;
  n: number;
  blame: boolean;
  hist: boolean;
  quote: string;
  go: (path: string, line: number) => void;
  setBlame: (v: boolean) => void;
  setHist: (v: boolean) => void;
  setQuote: (v: string) => void;
}>((set) => ({
  path: "",
  line: 1,
  n: 0,
  blame: false,
  hist: false,
  quote: "",
  go: (path, line) => set((s) => ({ path, line: Math.max(1, line), n: s.n + 1 })),
  setBlame: (blame) => set({ blame }),
  setHist: (hist) => set({ hist }),
  setQuote: (quote) => set({ quote }),
}));

function insertInField(el: HTMLInputElement | HTMLTextAreaElement, text: string) {
  const start = el.selectionStart ?? el.value.length;
  const end = el.selectionEnd ?? start;
  const next = el.value.slice(0, start) + text + el.value.slice(end);
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  const desc = Object.getOwnPropertyDescriptor(proto, "value");
  desc?.set?.call(el, next);
  el.dispatchEvent(new Event("input", { bubbles: true }));
  const pos = start + text.length;
  el.setSelectionRange(pos, pos);
}

export function insertAtCursor(text: string) {
  const el = document.activeElement;
  if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
    insertInField(el, text);
    return;
  }
  if (!view) return;
  const { from, to } = view.state.selection.main;
  view.dispatch({
    changes: { from, to, insert: text },
    selection: { anchor: from + text.length },
  });
  view.focus();
}

export function moveCursor(dir: "l" | "r" | "u" | "d") {
  const el = document.activeElement;
  if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
    const pos = el.selectionStart ?? 0;
    const next = dir === "l" ? Math.max(0, pos - 1) : dir === "r" ? Math.min(el.value.length, pos + 1) : pos;
    el.setSelectionRange(next, next);
    return;
  }
  if (!view) return;
  const main = view.state.selection.main;
  const line = view.state.doc.lineAt(main.head);
  let head = main.head;
  if (dir === "l") head = Math.max(0, main.head - 1);
  if (dir === "r") head = Math.min(view.state.doc.length, main.head + 1);
  if (dir === "u") {
    const prev = line.number > 1 ? view.state.doc.line(line.number - 1) : line;
    head = Math.min(prev.from + (main.head - line.from), prev.to);
  }
  if (dir === "d") {
    const next = line.number < view.state.doc.lines ? view.state.doc.line(line.number + 1) : line;
    head = Math.min(next.from + (main.head - line.from), next.to);
  }
  view.dispatch({ selection: { anchor: head } });
  view.focus();
}

export function sendEscape() {
  const el = document.activeElement;
  if (el instanceof HTMLElement) el.blur();
  document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
}

export function sendTab() {
  insertAtCursor("  ");
}

export function currentSelection() {
  if (view) {
    const sel = view.state.selection.main;
    if (sel.from !== sel.to) return view.state.sliceDoc(sel.from, sel.to);
  }
  const el = document.activeElement;
  if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) {
    const a = el.selectionStart ?? 0;
    const b = el.selectionEnd ?? 0;
    if (b > a) return el.value.slice(a, b);
  }
  return window.getSelection()?.toString() ?? "";
}

export function quoteSelection() {
  const text = currentSelection().trim();
  if (!text) return false;
  useNav.getState().setQuote(text);
  return true;
}
