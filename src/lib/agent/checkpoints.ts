import { create } from "zustand";
import { persist, createJSONStorage } from "zustand/middleware";
import { useWorkspace } from "@/lib/workspace/store";
import { usePatches, type AgentSlot } from "./patches";
import type { FileMap } from "@/lib/workspace/types";
import { sqlKv } from "@/lib/workspace/sql";
import { isNoisePath } from "@/lib/workspace/ignore";

type Snap = {
  id: string;
  at: number;
  title: string;
  files: FileMap;
  paths: string[];
  slot: AgentSlot;
  projectId?: string;
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
        const ws = useWorkspace.getState();
        const files = slimFiles(ws.files);
        const paths = Object.keys(ws.files).filter((k) => !isNoisePath(k));
        const snap: Snap = {
          id: crypto.randomUUID(),
          at: Date.now(),
          title,
          files,
          paths,
          slot,
          projectId: ws.projectId,
        };
        set((s) => {
          const mine = [snap, ...s.items.filter((x) => asSlot(x.slot) === slot && x.projectId === snap.projectId)].slice(
            0,
            8,
          );
          const others = s.items.filter((x) => !(asSlot(x.slot) === slot && x.projectId === snap.projectId)).slice(0, 8);
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
        const pid = useWorkspace.getState().projectId;
        const bySlot = s.lastBySlot ?? { a: null, b: null };
        const snap = slot
          ? (bySlot[slot] && bySlot[slot]!.projectId === pid ? bySlot[slot] : null) ??
            (s.last && asSlot(s.last.slot) === slot && s.last.projectId === pid ? s.last : null)
          : s.last && s.last.projectId === pid
            ? s.last
            : null;
        if (!snap) return "nada pra desfazer";
        return get().restore(snap.id);
      },
      restore: (id) => {
        const snap = get().items.find((x) => x.id === id);
        if (!snap) return "checkpoint sumiu";
        const cur = useWorkspace.getState();
        if (snap.projectId && snap.projectId !== cur.projectId) return "checkpoint de outro projeto";
        const next: FileMap = { ...cur.files };
        if (snap.paths?.length) {
          for (const k of Object.keys(next)) {
            if (!snap.paths.includes(k) && !isNoisePath(k)) delete next[k];
          }
        }
        Object.assign(next, snap.files);
        const first = snap.files[cur.openPath] !== undefined ? cur.openPath : Object.keys(snap.files)[0] ?? cur.openPath;
        const keep = cur.tabs.filter((p) => next[p] !== undefined);
        cur.importFiles(next, true);
        useWorkspace.setState({
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
      storage: createJSONStorage(() => sqlKv),
      partialize: (s) => ({
        items: s.items.slice(0, 12).map((x) => ({
          ...x,
          files: slimFiles(x.files),
          slot: asSlot(x.slot),
          paths: x.paths ?? Object.keys(x.files),
          projectId: x.projectId ?? "",
        })),
        last: s.last
          ? {
              ...s.last,
              files: slimFiles(s.last.files),
              slot: asSlot(s.last.slot),
              paths: s.last.paths ?? Object.keys(s.last.files),
              projectId: s.last.projectId ?? "",
            }
          : null,
        lastBySlot: {
          a: s.lastBySlot?.a
            ? {
                ...s.lastBySlot.a,
                files: slimFiles(s.lastBySlot.a.files),
                slot: "a" as const,
                paths: s.lastBySlot.a.paths ?? Object.keys(s.lastBySlot.a.files),
                projectId: s.lastBySlot.a.projectId ?? "",
              }
            : null,
          b: s.lastBySlot?.b
            ? {
                ...s.lastBySlot.b,
                files: slimFiles(s.lastBySlot.b.files),
                slot: "b" as const,
                paths: s.lastBySlot.b.paths ?? Object.keys(s.lastBySlot.b.files),
                projectId: s.lastBySlot.b.projectId ?? "",
              }
            : null,
        },
      }),
    },
  ),
);
