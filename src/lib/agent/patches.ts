import { create } from "zustand";
import { persist, createJSONStorage } from "zustand/middleware";
import { useWorkspace } from "@/lib/workspace/store";
import { useNav } from "@/lib/workspace/nav";
import { uid } from "@/lib/utils";
import { hunksOf, keepOnlyHunk } from "@/lib/workspace/hunks";
import { idbKv } from "@/lib/workspace/idb";

export type AgentSlot = "a" | "b";

export type Patch = {
  id: string;
  path: string;
  before: string;
  after: string;
  orig: string;
  status: "pending" | "accepted" | "rejected" | "undone";
  slot: AgentSlot;
};

type PatchState = {
  items: Patch[];
  queue: (path: string, before: string, after: string, slot?: AgentSlot) => Patch;
  accept: (id: string) => void;
  reject: (id: string) => void;
  acceptHunk: (id: string, index: number) => void;
  undo: (id: string) => void;
  acceptAll: (slot?: AgentSlot) => void;
  rejectAll: (slot?: AgentSlot) => void;
  get: (id: string) => Patch | undefined;
};

function clipOk(p: Patch) {
  return p.before.length + p.after.length < 80_000;
}

function asSlot(s?: string): AgentSlot {
  return s === "b" ? "b" : "a";
}

export const usePatches = create<PatchState>()(
  persist(
    (set, get) => ({
      items: [],
      queue: (path, before, after, slot = "a") => {
        const patch: Patch = { id: uid(), path, before, after, orig: before, status: "pending", slot };
        set((s) => {
          const pending = s.items.filter((p) => p.status === "pending");
          const mine = pending.filter((p) => asSlot(p.slot) === slot);
          const others = pending.filter((p) => asSlot(p.slot) !== slot);
          return { items: [...others, ...mine, patch].slice(-24) };
        });
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
        useWorkspace.getState().writeFile(patch.path, patch.orig || patch.before);
        set((s) => ({
          items: s.items.map((p) => (p.id === id ? { ...p, status: "undone" } : p)),
        }));
      },
      reject: (id) => {
        set((s) => ({
          items: s.items.map((p) => (p.id === id ? { ...p, status: "rejected" } : p)),
        }));
      },
      acceptAll: (slot) => {
        const pending = get().items.filter(
          (x) => x.status === "pending" && (!slot || asSlot(x.slot) === slot),
        );
        for (const p of pending) get().accept(p.id);
      },
      rejectAll: (slot) => {
        set((s) => ({
          items: s.items.map((p) =>
            p.status === "pending" && (!slot || asSlot(p.slot) === slot) ? { ...p, status: "rejected" } : p,
          ),
        }));
      },
      get: (id) => get().items.find((p) => p.id === id),
    }),
    {
      name: "colo-patches-v1",
      storage: createJSONStorage(() => idbKv),
      partialize: (s) => ({
        items: s.items.filter((p) => p.status === "pending" && clipOk(p)).slice(-16),
      }),
    },
  ),
);
