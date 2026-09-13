import { sqlKv } from "./sql";
import { usePersistHealth } from "./idb";
import { initDisk, loadProject, saveProject, useDisk } from "./disk";
import { isNoisePath } from "./ignore";

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
    if (Object.keys(diskFiles).length) {
      const state = { ...(parsed.state ?? {}), projectId: pid, files: diskFiles };
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
    try {
      await sqlKv.setItem(LAST, pid);
    } catch {
      /* tiny key */
    }
    const slim = {
      ...parsed,
      state: {
        ...state,
        files: diskOk ? {} : files,
        disk: diskOk,
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
