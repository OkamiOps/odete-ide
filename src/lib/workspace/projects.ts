import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import { idbKv } from "./idb";
import { persistAuth } from "./secrets";
import type { FileMap } from "./types";
import { githubUser, type GithubUser } from "@/lib/github/api";
import { rebrandFiles, rebrandName } from "./brand";

export type RecentProject = {
  id: string;
  name: string;
  at: number;
  files: number;
  remote: string | null;
  snapshot: FileMap;
  branch: string;
  folder?: string;
};

export type ProjectSheet = false | "hub" | "recent" | "clone" | "github" | "new" | "open" | "library";

type ProjectsState = {
  recents: RecentProject[];
  library: RecentProject[];
  github: { token: string; user: GithubUser } | null;
  remember: (p: Omit<RecentProject, "at">) => void;
  forget: (id: string) => void;
  rename: (id: string, name: string) => void;
  duplicate: (id: string) => string | null;
  connect: (token: string) => Promise<void>;
  disconnect: () => void;
};

const MAX_RECENTS = 8;
const MAX_SNAP = 2_000_000;

function slimSnapshot(files: FileMap): FileMap {
  const out: FileMap = {};
  let used = 0;
  let cut = false;
  for (const [path, text] of Object.entries(files)) {
    const n = text.length;
    if (used + n > MAX_SNAP) {
      cut = true;
      continue;
    }
    out[path] = text;
    used += n;
  }
  if (cut) out[".odete/truncated"] = "snapshot cortado — arquivos grandes ficaram de fora dos Recentes.\n";
  return out;
}

export const useProjectUi = create<{
  sheet: ProjectSheet;
  setSheet: (s: ProjectSheet) => void;
}>((set) => ({
  sheet: false,
  setSheet: (sheet) => set({ sheet }),
}));

export function setSheet(sheet: ProjectSheet) {
  useProjectUi.getState().setSheet(sheet);
}

export const useProjects = create<ProjectsState>()(
  persist(
    (set, get) => ({
      recents: [],
      library: [],
      github: null,
      remember: (p) => {
        const prev = get().library.find((r) => r.id === p.id) ?? get().recents.find((r) => r.id === p.id);
        const next: RecentProject = {
          folder: prev?.folder,
          ...p,
          snapshot: slimSnapshot(p.snapshot),
          at: Date.now(),
        };
        const recents = [next, ...get().recents.filter((r) => r.id !== p.id)].slice(0, MAX_RECENTS);
        const library = [next, ...get().library.filter((r) => r.id !== p.id)].slice(0, 24);
        set({ recents, library });
      },
      forget: (id) =>
        set({
          recents: get().recents.filter((r) => r.id !== id),
          library: get().library.filter((r) => r.id !== id),
        }),
      rename: (id, name) => {
        const n = name.trim();
        if (!n) return;
        const bump = (list: RecentProject[]) => list.map((r) => (r.id === id ? { ...r, name: n } : r));
        set({ recents: bump(get().recents), library: bump(get().library) });
      },
      duplicate: (id) => {
        const src = get().library.find((r) => r.id === id) ?? get().recents.find((r) => r.id === id);
        if (!src) return null;
        const copy: RecentProject = {
          ...src,
          id: `${src.id}-copy-${Date.now()}`,
          name: `${src.name} cópia`,
          at: Date.now(),
          snapshot: { ...src.snapshot },
        };
        set({
          library: [copy, ...get().library].slice(0, 24),
          recents: [copy, ...get().recents].slice(0, MAX_RECENTS),
        });
        return copy.id;
      },
      connect: async (token) => {
        const user = await githubUser(token.trim());
        set({ github: { token: token.trim(), user } });
        void persistAuth();
      },
      disconnect: () => {
        set({ github: null });
        void persistAuth();
      },
    }),
    {
      name: "colo-projects-v2",
      partialize: (s) => ({ recents: s.recents, library: s.library, github: s.github }),
      storage: createJSONStorage(() => idbKv),
      merge: (persisted, current) => {
        const p = { ...(current as ProjectsState), ...((persisted ?? {}) as Partial<ProjectsState>) };
        const stamp = (r: RecentProject): RecentProject => ({
          ...r,
          name: rebrandName(r.name),
          snapshot: r.snapshot ? rebrandFiles(r.snapshot) : r.snapshot,
        });
        if (p.recents) p.recents = p.recents.map(stamp);
        if (p.library) p.library = p.library.map(stamp);
        return p;
      },
    },
  ),
);

export function snapshotCurrent() {
  return useProjects.getState();
}
