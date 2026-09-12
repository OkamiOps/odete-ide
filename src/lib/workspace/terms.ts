import { create } from "zustand";
import { uid } from "../utils";
import type { TermLine } from "./types";

export type TermTab = {
  id: string;
  name: string;
  lines: TermLine[];
  hist: string[];
};

function boot(name: string, n: number): TermTab {
  return {
    id: uid(),
    name: n <= 1 ? "term" : `term ${n}`,
    lines: [
      { id: uid(), kind: "ok", text: `colo  ${name}` },
      { id: uid(), kind: "out", text: "↑ histórico · Tab completa · help" },
    ],
    hist: [],
  };
}

type TermsState = {
  tabs: TermTab[];
  active: string;
  print: (kind: TermLine["kind"], text: string) => void;
  clear: () => void;
  pushHist: (cmd: string) => void;
  add: () => void;
  close: (id: string) => void;
  setActive: (id: string) => void;
};

export const useTerms = create<TermsState>((set, get) => {
  const first = boot("workspace local", 1);
  return {
    tabs: [first],
    active: first.id,
    print: (kind, text) =>
      set((s) => ({
        tabs: s.tabs.map((t) =>
          t.id === s.active
            ? { ...t, lines: [...t.lines.slice(-220), { id: uid(), kind, text }] }
            : t,
        ),
      })),
    clear: () =>
      set((s) => ({
        tabs: s.tabs.map((t) => (t.id === s.active ? { ...t, lines: [] } : t)),
      })),
    pushHist: (cmd) =>
      set((s) => ({
        tabs: s.tabs.map((t) =>
          t.id === s.active ? { ...t, hist: [...t.hist.filter((h) => h !== cmd), cmd].slice(-40) } : t,
        ),
      })),
    add: () => {
      const tab = boot("sessão", get().tabs.length + 1);
      set((s) => ({ tabs: [...s.tabs, tab], active: tab.id }));
    },
    close: (id) =>
      set((s) => {
        if (s.tabs.length === 1) return s;
        const tabs = s.tabs.filter((t) => t.id !== id);
        return { tabs, active: s.active === id ? tabs[tabs.length - 1]!.id : s.active };
      }),
    setActive: (active) => set({ active }),
  };
});
