import { create } from "zustand";
import { persist } from "zustand/middleware";
import { createJSONStorage } from "zustand/middleware";
import { idbKv } from "./idb";

type View = null | "actions" | "pr" | "prs" | "compare" | "folder";

type Hub = {
  view: View;
  pr: number;
  compareA: string;
  compareB: string;
  folder: string;
  agentSplit: boolean;
  setView: (view: View) => void;
  setPr: (n: number) => void;
  setCompare: (a: string, b: string) => void;
  setFolder: (name: string) => void;
  toggleSplit: () => void;
};

export const useHub = create<Hub>()(
  persist(
    (set) => ({
      view: null,
      pr: 0,
      compareA: "",
      compareB: "",
      folder: "",
      agentSplit: false,
      setView: (view) => set({ view }),
      setPr: (pr) => set({ view: "pr", pr }),
      setCompare: (compareA, compareB) => set({ view: "compare", compareA, compareB }),
      setFolder: (folder) => set({ folder }),
      toggleSplit: () => set((s) => ({ agentSplit: !s.agentSplit })),
    }),
    {
      name: "colo-hub-v1",
      storage: createJSONStorage(() => idbKv),
      partialize: (s) => ({ agentSplit: s.agentSplit, folder: s.folder }),
    },
  ),
);
