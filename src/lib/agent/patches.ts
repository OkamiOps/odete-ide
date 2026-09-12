import { create } from "zustand";
import { useWorkspace } from "@/lib/workspace/store";
import { useNav } from "@/lib/workspace/nav";
import { uid } from "@/lib/utils";
import { hunksOf, keepOnlyHunk } from "@/lib/workspace/hunks";

export type Patch = {
  id: string;
  path: string;
  before: string;
  after: string;
  status: "pending" | "accepted" | "rejected" | "undone";
};

type PatchState = {
  items: Patch[];
  queue: (path: string, before: string, after: string) => Patch;
  accept: (id: string) => void;
  reject: (id: string) => void;
  acceptHunk: (id: string, index: number) => void;
  undo: (id: string) => void;
  acceptAll: () => void;
  rejectAll: () => void;
  get: (id: string) => Patch | undefined;
};

export const usePatches = create<PatchState>((set, get) => ({
  items: [],
  queue: (path, before, after) => {
    const patch: Patch = { id: uid(), path, before, after, status: "pending" };
    set((s) => ({ items: [...s.items.filter((p) => p.status === "pending"), patch].slice(-20) }));
    return patch;
  },
  accept: (id) => {
    const patch = get().items.find((p) => p.id === id);
    if (!patch || patch.status !== "pending") return;
    useWorkspace.getState().writeFile(patch.path, patch.after);
    useWorkspace.getState().openFile(patch.path);
    const first = hunksOf(patch.before, patch.after)[0];
    useNav.getState().go(patch.path, first?.afterStart ?? 1);
    set((s) => ({
      items: s.items.map((p) => (p.id === id ? { ...p, status: "accepted" } : p)),
    }));
  },
  acceptHunk: (id, index) => {
    const patch = get().items.find((p) => p.id === id);
    if (!patch || patch.status !== "pending") return;
    const hunks = hunksOf(patch.before, patch.after);
    if (hunks.length <= 1) {
      get().accept(id);
      return;
    }
    const next = keepOnlyHunk(patch.before, patch.after, index);
    useWorkspace.getState().writeFile(patch.path, next);
    useWorkspace.getState().openFile(patch.path);
    const left = hunksOf(next, patch.after);
    set((s) => ({
      items: s.items.map((p) =>
        p.id === id
          ? { ...p, before: next, status: left.length ? "pending" : "accepted" }
          : p,
      ),
    }));
  },
  undo: (id) => {
    const patch = get().items.find((p) => p.id === id);
    if (!patch) return;
    useWorkspace.getState().writeFile(patch.path, patch.before);
    set((s) => ({
      items: s.items.map((p) => (p.id === id ? { ...p, status: "undone" } : p)),
    }));
  },
  reject: (id) => {
    set((s) => ({
      items: s.items.map((p) => (p.id === id ? { ...p, status: "rejected" } : p)),
    }));
  },
  acceptAll: () => {
    for (const p of get().items.filter((x) => x.status === "pending")) get().accept(p.id);
  },
  rejectAll: () => {
    set((s) => ({
      items: s.items.map((p) => (p.status === "pending" ? { ...p, status: "rejected" } : p)),
    }));
  },
  get: (id) => get().items.find((p) => p.id === id),
}));
