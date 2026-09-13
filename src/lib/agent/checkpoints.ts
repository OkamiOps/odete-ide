import { create } from "zustand";
import { persist, createJSONStorage } from "zustand/middleware";
import { useWorkspace } from "@/lib/workspace/store";
import { usePatches } from "./patches";
import type { FileMap } from "@/lib/workspace/types";
import { idbKv } from "@/lib/workspace/idb";
import { isNoisePath } from "@/lib/workspace/ignore";

type Snap = {
  id: string;
  at: number;
  title: string;
  files: FileMap;
};

type State = {
  items: Snap[];
  last: Snap | null;
  take: (title?: string) => void;
  undo: () => string;
  restore: (id: string) => string;
};

function slimFiles(files: FileMap): FileMap {
  const out: FileMap = {};
  let n = 0;
  for (const [k, v] of Object.entries(files)) {
    if (isNoisePath(k)) continue;
    if (v.length > 200_000) continue;
    if (n++ > 220) break;
    out[k] = v;
  }
  return out;
}

export const useCheckpoints = create<State>()(
  persist(
    (set, get) => ({
      items: [],
      last: null,
      take: (title = "turno") => {
        const files = slimFiles(useWorkspace.getState().files);
        const snap: Snap = { id: crypto.randomUUID(), at: Date.now(), title, files };
        set((s) => ({ last: snap, items: [snap, ...s.items].slice(0, 8) }));
      },
      undo: () => {
        const snap = get().last;
        if (!snap) return "nada pra desfazer";
        return get().restore(snap.id);
      },
      restore: (id) => {
        const snap = get().items.find((x) => x.id === id);
        if (!snap) return "checkpoint sumiu";
        const cur = useWorkspace.getState();
        const merged = { ...cur.files, ...snap.files };
        const first = snap.files[cur.openPath] !== undefined ? cur.openPath : Object.keys(snap.files)[0] ?? cur.openPath;
        const keep = cur.tabs.filter((p) => merged[p] !== undefined);
        useWorkspace.setState({
          files: merged,
          openPath: first,
          tabs: keep.length ? keep : [first],
        });
        usePatches.getState().rejectAll();
        set({ last: snap });
        return `voltou: ${snap.title}`;
      },
    }),
    {
      name: "colo-ck-v1",
      storage: createJSONStorage(() => idbKv),
      partialize: (s) => ({
        items: s.items.slice(0, 6).map((x) => ({ ...x, files: slimFiles(x.files) })),
        last: s.last ? { ...s.last, files: slimFiles(s.last.files) } : null,
      }),
    },
  ),
);
