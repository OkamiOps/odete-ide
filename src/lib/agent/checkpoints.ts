import { create } from "zustand";
import { useWorkspace } from "@/lib/workspace/store";
import { usePatches } from "./patches";
import type { FileMap } from "@/lib/workspace/types";

type Snap = {
  id: string;
  at: number;
  files: FileMap;
};

type State = {
  last: Snap | null;
  take: () => void;
  undo: () => string;
};

export const useCheckpoints = create<State>((set, get) => ({
  last: null,
  take: () => {
    const files = { ...useWorkspace.getState().files };
    set({ last: { id: crypto.randomUUID(), at: Date.now(), files } });
  },
  undo: () => {
    const snap = get().last;
    if (!snap) return "nada pra desfazer";
    useWorkspace.setState({ files: { ...snap.files } });
    usePatches.getState().rejectAll();
    set({ last: null });
    return "turno desfeito";
  },
}));
