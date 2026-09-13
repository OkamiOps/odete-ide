import { create } from "zustand";
import { persist, createJSONStorage } from "zustand/middleware";
import { useWorkspace } from "@/lib/workspace/store";
import { usePatches, type AgentSlot } from "./patches";
import type { FileMap } from "@/lib/workspace/types";
import { idbKv } from "@/lib/workspace/idb";
import { isNoisePath } from "@/lib/workspace/ignore";

type Snap = {
  id: string;
  at: number;
  title: string;
  files: FileMap;
  slot: AgentSlot;
};

type State = {
  items: Snap[];
  last: Snap | null;
  lastBySlot: { a: Snap | null; b: Snap | null };
  take: (title?: string, slot?: AgentSlot) => void;
  undo: (slot?: AgentSlot) => string;
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

function asSlot(s?: string): AgentSlot {
  return s === "b" ? "b" : "a";
}

export const useCheckpoints = create<State>()(
  persist(
    (set, get) => ({
      items: [],
      last: null,
      lastBySlot: { a: null, b: null },
      take: (title = "turno", slot: AgentSlot = "a") => {
        const files = slimFiles(useWorkspace.getState().files);
        const snap: Snap = { id: crypto.randomUUID(), at: Date.now(), title, files, slot };
        set((s) => {
          const mine = [snap, ...s.items.filter((x) => asSlot(x.slot) === slot)].slice(0, 8);
          const others = s.items.filter((x) => asSlot(x.slot) !== slot).slice(0, 8);
          const lastBySlot =
            slot === "b"
              ? { a: s.lastBySlot?.a ?? null, b: snap }
              : { a: snap, b: s.lastBySlot?.b ?? null };
          return {
            last: snap,
            lastBySlot,
            items: [...mine, ...others],
          };
        });
      },
      undo: (slot) => {
        const s = get();
        const bySlot = s.lastBySlot ?? { a: null, b: null };
        const snap = slot ? (bySlot[slot] ?? (s.last && asSlot(s.last.slot) === slot ? s.last : null)) : s.last;
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
        usePatches.getState().rejectAll(asSlot(snap.slot));
        const slot = asSlot(snap.slot);
        set((s) => ({
          last: snap,
          lastBySlot:
            slot === "b"
              ? { a: s.lastBySlot?.a ?? null, b: snap }
              : { a: snap, b: s.lastBySlot?.b ?? null },
        }));
        return `voltou: ${snap.title}`;
      },
    }),
    {
      name: "colo-ck-v1",
      storage: createJSONStorage(() => idbKv),
      partialize: (s) => ({
        items: s.items.slice(0, 12).map((x) => ({ ...x, files: slimFiles(x.files), slot: asSlot(x.slot) })),
        last: s.last ? { ...s.last, files: slimFiles(s.last.files), slot: asSlot(s.last.slot) } : null,
        lastBySlot: {
          a: s.lastBySlot?.a ? { ...s.lastBySlot.a, files: slimFiles(s.lastBySlot.a.files), slot: "a" as const } : null,
          b: s.lastBySlot?.b ? { ...s.lastBySlot.b, files: slimFiles(s.lastBySlot.b.files), slot: "b" as const } : null,
        },
      }),
    },
  ),
);
