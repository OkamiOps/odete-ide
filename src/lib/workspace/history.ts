import { create } from "zustand";
import { persist } from "zustand/middleware";

export type Snap = { at: number; text: string };

type HistState = {
  byPath: Record<string, Snap[]>;
  record: (path: string, text: string) => void;
  list: (path: string) => Snap[];
  restore: (path: string, at: number) => void;
};

const MAX_FILES = 24;
const MAX_SNAPS = 10;
const MAX_CHARS = 24_000;

let timer = 0;
let pending: { path: string; text: string } | null = null;

export const useHistory = create<HistState>()(
  persist(
    (set, get) => ({
      byPath: {},
      record: (path, text) => {
        if (!path || text.length > MAX_CHARS) return;
        pending = { path, text };
        window.clearTimeout(timer);
        timer = window.setTimeout(() => {
          const job = pending;
          pending = null;
          if (!job) return;
          set((s) => {
            const prev = s.byPath[job.path] ?? [];
            const last = prev[0];
            if (last && last.text === job.text) return s;
            const next = [{ at: Date.now(), text: job.text }, ...prev].slice(0, MAX_SNAPS);
            const byPath = { ...s.byPath, [job.path]: next };
            const keys = Object.keys(byPath);
            if (keys.length > MAX_FILES) {
              for (const k of keys.slice(0, keys.length - MAX_FILES)) delete byPath[k];
            }
            return { byPath };
          });
        }, 900);
      },
      list: (path) => get().byPath[path] ?? [],
      restore: (path, at) => {
        const snap = (get().byPath[path] ?? []).find((s) => s.at === at);
        if (!snap) return;
        void import("./store").then((m) => m.useWorkspace.getState().writeFile(path, snap.text));
      },
    }),
    { name: "colo-history-v1" },
  ),
);

export function rememberEdit(path: string, text: string) {
  useHistory.getState().record(path, text);
}
