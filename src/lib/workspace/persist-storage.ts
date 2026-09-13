import { sqlKv } from "./sql";
import { usePersistHealth } from "./idb";
import { initDisk, loadProject, saveProject, useDisk } from "./disk";
import { isNoisePath } from "./ignore";
import { loadGit, saveGit } from "./git-sql";
import type { Commit } from "./types";

function persistFiles(files: Record<string, string>) {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(files)) {
    if (k.startsWith("node_modules/") || k.includes("/node_modules/") || isNoisePath(k)) continue;
    out[k] = v;
  }
  return out;
}

const LAST = "colo-last-project";

export const workspaceStorage = {
  getItem: async (name: string) => {
    await initDisk();
    let raw: string | null = null;
    try {
      raw = await sqlKv.getItem(name);
    } catch (e) {
      usePersistHealth.setState({
        ok: false,
        freeze: true,
        lastError: e instanceof Error ? e.message : "não leu o índice",
      });
    }
    let parsed: { state?: Record<string, unknown>; version?: number } = {};
    if (raw) {
      try {
        parsed = JSON.parse(raw) as { state?: Record<string, unknown>; version?: number };
      } catch {
        parsed = {};
      }
    }
    const pid =
      (typeof parsed.state?.projectId === "string" && parsed.state.projectId) ||
      (await sqlKv.getItem(LAST).catch(() => null)) ||
      "seed";
    const diskFiles = await loadProject(pid);
    const git = await loadGit(pid).catch(() => ({ commits: [] as Commit[], origin: null as Commit | null }));
    if (Object.keys(diskFiles).length || git.commits.length) {
      const prev = (parsed.state ?? {}) as Record<string, unknown>;
      const state = {
        ...prev,
        projectId: pid,
        files: Object.keys(diskFiles).length ? diskFiles : ((prev.files as Record<string, string>) ?? {}),
        commits: git.commits.length ? git.commits : prev.commits,
        origin: git.origin ?? prev.origin,
      };
      return JSON.stringify({ ...parsed, state });
    }
    if (parsed.state && (parsed.state as { disk?: boolean }).disk) {
      usePersistHealth.setState({
        ok: false,
        freeze: true,
        lastError: "disco do projeto veio vazio — não vou gravar o seed por cima",
      });
      return JSON.stringify({ ...parsed, state: { ...parsed.state, files: parsed.state.files ?? {} } });
    }
    if (raw) return raw;
    return null;
  },
  setItem: async (name: string, value: string) => {
    if (usePersistHealth.getState().freeze) return;
    let parsed: { state?: Record<string, unknown>; version?: number };
    try {
      parsed = JSON.parse(value) as { state?: Record<string, unknown>; version?: number };
    } catch {
      return;
    }
    const state = parsed.state ?? {};
    const pid = typeof state.projectId === "string" ? state.projectId : "seed";
    const files = persistFiles((state.files as Record<string, string>) ?? {});
    const diskOk = await saveProject(pid, files);
    const commits = (state.commits as Commit[] | undefined) ?? [];
    const origin = (state.origin as Commit | null | undefined) ?? null;
    try {
      await saveGit(pid, commits, origin);
    } catch {
      /* git sql opcional — commits ainda vão no índice */
    }
    try {
      await sqlKv.setItem(LAST, pid);
    } catch {
      /* tiny key */
    }
    const metaCommits = commits.slice(-12).map((c) => ({
      id: c.id,
      sha: c.sha,
      message: c.message,
      at: c.at,
      files: {},
    }));
    const slim = {
      ...parsed,
      state: {
        ...state,
        files: diskOk ? {} : files,
        disk: diskOk,
        commits: metaCommits,
        origin: origin
          ? { id: origin.id, sha: origin.sha, message: origin.message, at: origin.at, files: {} }
          : origin,
      },
    };
    try {
      await sqlKv.setItem(name, JSON.stringify(slim));
    } catch (e) {
      if (!diskOk) {
        usePersistHealth.setState({
          ok: false,
          freeze: true,
          lastError: e instanceof Error ? e.message : "quota",
        });
        throw e;
      }
      useDisk.setState((s) => ({
        ...s,
        lastError: s.lastError || "índice cheio — arquivos estão no disco",
      }));
    }
  },
  removeItem: async (name: string) => {
    await sqlKv.removeItem(name);
  },
};
