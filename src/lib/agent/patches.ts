import { create } from "zustand";
import { persist, createJSONStorage } from "zustand/middleware";
import { useWorkspace } from "@/lib/workspace/store";
import { useNav } from "@/lib/workspace/nav";
import { uid } from "@/lib/utils";
import { hunksOf, keepOnlyHunk } from "@/lib/workspace/hunks";
import { sqlKv } from "@/lib/workspace/sql";

export type AgentSlot = "a" | "b";

export type Patch = {
  id: string;
  path: string;
  before: string;
  after: string;
  orig: string;
  status: "pending" | "accepted" | "rejected" | "undone";
  slot: AgentSlot;
  projectId?: string;
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
        const projectId = useWorkspace.getState().projectId;
        const patch: Patch = {
          id: uid(),
          path,
          before,
          after,
          orig: before,
          status: "pending",
          slot,
          projectId,
        };
        set((s) => {
          const done = s.items.filter((p) => p.status !== "pending").slice(-24);
          const pending = s.items.filter((p) => p.status === "pending");
          const mine = pending.filter((p) => asSlot(p.slot) === slot && (p.projectId ?? projectId) === projectId);
          const others = pending.filter((p) => !(asSlot(p.slot) === slot && (p.projectId ?? projectId) === projectId));
          return { items: [...done, ...others, ...mine.slice(-11), patch] };
        });
        return patch;
      },
      accept: (id) => {
        const patch = get().items.find((p) => p.id === id);
        if (!patch || patch.status !== "pending") return;
        if (patch.projectId && patch.projectId !== useWorkspace.getState().projectId) return;
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
            p.id === id ? { ...p, before: next, status: left.length ? "pending" : "accepted" } : p,
          ),
        }));
      },
      undo: (id) => {
        const patch = get().items.find((p) => p.id === id);
        if (!patch) return;
        if (patch.projectId && patch.projectId !== useWorkspace.getState().projectId) return;
        useWorkspace.getState().writeFile(patch.path, patch.orig || patch.before);
        set((s) => ({
          items: s.items.map((p) => (p.id === id ? { ...p, status: "undone" } : p)),
        }));
      },
      reject: (id) => {
        const patch = get().items.find((p) => p.id === id);
        if (patch && patch.status === "pending") {
          if (!patch.projectId || patch.projectId === useWorkspace.getState().projectId) {
            const cur = useWorkspace.getState().files[patch.path];
            if (cur === patch.after || cur === undefined) {
              useWorkspace.getState().writeFile(patch.path, patch.orig || patch.before);
            }
          }
        }
        set((s) => ({
          items: s.items.map((p) => (p.id === id ? { ...p, status: "rejected" } : p)),
        }));
      },
      acceptAll: (slot) => {
        const pid = useWorkspace.getState().projectId;
        const pending = get().items.filter(
          (x) =>
            x.status === "pending" &&
            (!slot || asSlot(x.slot) === slot) &&
            (!x.projectId || x.projectId === pid),
        );
        for (const p of pending) get().accept(p.id);
      },
      rejectAll: (slot) => {
        const pid = useWorkspace.getState().projectId;
        const pending = get()
          .items.filter(
            (x) =>
              x.status === "pending" &&
              (!slot || asSlot(x.slot) === slot) &&
              (!x.projectId || x.projectId === pid),
          )
          .reverse();
        for (const p of pending) get().reject(p.id);
      },
      get: (id) => get().items.find((p) => p.id === id),
    }),
    {
      name: "colo-patches-v1",
      storage: createJSONStorage(() => sqlKv),
      partialize: (s) => ({
        items: s.items.filter((p) => p.status === "pending" && clipOk(p)).slice(-16),
      }),
    },
  ),
);
