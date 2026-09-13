import { create } from "zustand";
import { useWorkspace } from "@/lib/workspace/store";
import { usePatches } from "./patches";
import type { FileMap } from "@/lib/workspace/types";

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

export const useCheckpoints = create<State>((set, get) => ({
  items: [],
  last: null,
  take: (title = "turno") => {
    const files = { ...useWorkspace.getState().files };
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
    useWorkspace.setState({ files: { ...snap.files } });
    usePatches.getState().rejectAll();
    set({ last: snap });
    return `voltou: ${snap.title}`;
  },
}));
