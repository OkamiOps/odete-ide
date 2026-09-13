import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import { SEED_COMMIT_MESSAGE, SEED_FILES } from "./seed";
import { usePersistHealth } from "./idb";
import { workspaceStorage } from "./persist-storage";
import type { BlameLine, BranchSnap, Commit, Conflict, FileMap, StashEntry, TermLine } from "./types";
import { uid } from "../utils";
import { rememberEdit } from "./history";
import { discardHunk, keepOnlyHunk } from "./hunks";
import { useProjects } from "./projects";
import { scheduleSync } from "./folder";
import { useTerms } from "./terms";
import { lineDiff } from "./diff";
import { isNoisePath } from "./ignore";
import { virtualNpmFile, virtualNpmNames } from "./npm-lock";

function cloneFiles(files: FileMap): FileMap {
  return { ...files };
}

function persistFiles(files: FileMap): FileMap {
  const out: FileMap = {};
  for (const [k, v] of Object.entries(files)) {
    if (k.startsWith("node_modules/") || k.includes("/node_modules/")) continue;
    out[k] = v;
  }
  return out;
}

function persistCommit(c: Commit): Commit {
  return { ...c, files: persistFiles(c.files) };
}

function filesEqual(a: FileMap, b: FileMap) {
  const ak = Object.keys(a);
  const bk = Object.keys(b);
  if (ak.length !== bk.length) return false;
  return ak.every((k) => a[k] === b[k]);
}

function parentDir(path: string) {
  const i = path.lastIndexOf("/");
  return i <= 0 ? "" : path.slice(0, i);
}

function snapBranch(s: {
  files: FileMap;
  commits: Commit[];
  staged: string[];
  stagedBlobs: FileMap;
  lastPushedId: string | null;
  origin: Commit | null;
}): BranchSnap {
  return {
    files: cloneFiles(s.files),
    commits: s.commits,
    staged: [...s.staged],
    stagedBlobs: cloneFiles(s.stagedBlobs),
    lastPushedId: s.lastPushedId,
    origin: s.origin,
  };
}

function sanitizePath(path: string) {
  return path.replace(/^\/+/, "").replace(/\.\.\//g, "").trim();
}

export type WorkspaceState = {
  files: FileMap;
  openPath: string;
  tabs: string[];
  commits: Commit[];
  lastPushedId: string | null;
  origin: Commit | null;
  staged: string[];
  stagedBlobs: FileMap;
  branch: string;
  branchSnaps: Record<string, BranchSnap>;
  stash: StashEntry[];
  conflicts: Conflict[];
  terminal: TermLine[];
  cwd: string;
  projectId: string;
  projectName: string;
  remote: string | null;
  hydrated: boolean;
  openFile: (path: string) => void;
  closeTab: (path: string) => void;
  writeFile: (path: string, content: string) => string | undefined;
  createFile: (path: string) => string | undefined;
  deleteFile: (path: string) => string | undefined;
  readFile: (path: string) => string | undefined;
  listDir: (path?: string) => string[];
  mkdir: (path: string) => string;
  grep: (pattern: string, path?: string) => string;
  commit: (message: string, all?: boolean) => string;
  gitStatus: () => string;
  gitLog: () => string;
  gitPush: () => string;
  gitPull: () => string;
  gitFetch: () => string;
  gitSync: () => string;
  gitStage: (path: string) => void;
  gitUnstage: (path: string) => void;
  gitStageAll: () => void;
  gitUnstageAll: () => void;
  gitDiscard: (path: string) => string;
  gitDiscardAll: () => string;
  gitUndoCommit: () => string;
  gitBranchList: () => string[];
  gitBranchCreate: (name: string) => string;
  gitCheckout: (name: string) => string;
  gitStash: () => string;
  gitStashPop: () => string;
  gitCherryPick: (id: string) => string;
  gitBlame: (path: string) => BlameLine[];
  gitRestoreCommit: (id: string) => string;
  gitApplyHunk: (path: string, index: number, keep: boolean) => string;
  renameFile: (from: string, to: string) => string | undefined;
  replaceInFiles: (pattern: string, replacement: string, onlyPath?: string) => { files: number; hits: number };
  resolveConflict: (path: string, take: "ours" | "theirs" | "merged", merged?: string) => void;
  mergeRemote: (incoming: FileMap) => string;
  gitApplyFetch: (incoming: FileMap) => string;
  changedPaths: () => string[];
  fileDirty: (path: string) => boolean;
  termPrint: (kind: TermLine["kind"], text: string) => void;
  termClear: () => void;
  setCwd: (path: string) => void;
  loadProject: (p: {
    id: string;
    name: string;
    files: FileMap;
    remote?: string | null;
    branch?: string;
    message?: string;
    pushed?: boolean;
    history?: { sha: string; message: string; at: number; files?: FileMap }[];
  }) => void;
  newProject: (name: string) => void;
  closeProject: () => void;
  importFiles: (files: FileMap, replace?: boolean) => void;
  rememberNow: () => void;
  resetWorkspace: () => void;
  isDirty: () => boolean;
};

const bootLines: TermLine[] = [
  { id: "boot", kind: "ok", text: "colo  workspace local" },
  { id: "boot2", kind: "out", text: "digite help · npm i · git status" },
];

function freshState() {
  return {
    files: cloneFiles(SEED_FILES),
    openPath: "README.md",
    tabs: ["README.md"],
    commits: [
      {
        id: "seed",
        message: SEED_COMMIT_MESSAGE,
        at: Date.now(),
        files: cloneFiles(SEED_FILES),
      },
    ] as Commit[],
    lastPushedId: "seed",
    origin: {
      id: "seed",
      message: SEED_COMMIT_MESSAGE,
      at: Date.now(),
      files: cloneFiles(SEED_FILES),
    } as Commit,
    staged: [] as string[],
    stagedBlobs: {} as FileMap,
    branch: "main",
    cwd: "",
    projectId: "seed",
    projectName: "colo",
    remote: null as string | null,
    branchSnaps: {} as Record<string, BranchSnap>,
    stash: [] as StashEntry[],
    conflicts: [] as Conflict[],
  };
}

export const useWorkspace = create<WorkspaceState>()(
  persist(
    (set, get) => ({
      ...freshState(),
      terminal: bootLines,
      hydrated: false,
      openFile: (path) => {
        const { files } = get();
        if (files[path] === undefined) return;
        set((s) => ({
          openPath: path,
          tabs: s.tabs.includes(path) ? s.tabs : [...s.tabs, path],
        }));
      },
      closeTab: (path) => {
        set((s) => {
          const tabs = s.tabs.filter((t) => t !== path);
          const nextTabs = tabs.length ? tabs : [s.openPath === path ? "README.md" : s.openPath];
          const openPath =
            s.openPath === path ? (nextTabs[nextTabs.length - 1] ?? "README.md") : s.openPath;
          return { tabs: nextTabs, openPath };
        });
      },
      writeFile: (path, content) => {
        const clean = sanitizePath(path);
        if (!clean) return "caminho inválido";
        const quiet = clean.startsWith("node_modules/") || clean.includes("/node_modules/");
        set((s) => ({
          files: { ...s.files, [clean]: content },
          openPath: quiet || s.files[clean] !== undefined ? s.openPath : clean,
          tabs:
            quiet || s.files[clean] !== undefined || s.tabs.includes(clean)
              ? s.tabs
              : [...s.tabs, clean],
        }));
        rememberEdit(clean, content);
        scheduleSync({ ...get().files, [clean]: content }, get().projectId);
        return undefined;
      },
      createFile: (path) => {
        const clean = sanitizePath(path);
        if (!clean) return "caminho inválido";
        if (get().files[clean] !== undefined) return "já existe";
        return get().writeFile(clean, "");
      },
      deleteFile: (path) => {
        const { files, openPath, tabs } = get();
        if (files[path] === undefined) return "arquivo não existe";
        const next = { ...files };
        delete next[path];
        const nextTabs = tabs.filter((t) => t !== path);
        const fallback = nextTabs[0] ?? Object.keys(next)[0] ?? "README.md";
        set({
          files: next,
          tabs: nextTabs.length ? nextTabs : [fallback],
          openPath: openPath === path ? fallback : openPath,
        });
        scheduleSync(next, get().projectId);
        void import("./folder").then((m) => m.removeFromFolder(path, get().projectId));
        return undefined;
      },
      readFile: (path) => get().files[path] ?? virtualNpmFile(path, get().files),
      listDir: (path = "") => {
        const prefix = path.replace(/^\/+|\/+$/g, "");
        const { files } = get();
        const names = new Set<string>(virtualNpmNames(prefix, files));
        for (const p of Object.keys(files).sort()) {
          if (isNoisePath(p) && prefix !== "node_modules" && !prefix.startsWith("node_modules/")) continue;
          if (prefix) {
            if (p === prefix) {
              names.add(p);
              continue;
            }
            if (!p.startsWith(prefix + "/")) continue;
            const rest = p.slice(prefix.length + 1);
            names.add(rest.split("/")[0]!);
          } else {
            names.add(p.split("/")[0]!);
          }
        }
        return [...names];
      },
      mkdir: (path) => {
        const p = sanitizePath(path).replace(/\/+$/g, "");
        if (!p) return "mkdir: caminho?";
        const keep = `${p}/.gitkeep`;
        const { files } = get();
        if (files[keep] !== undefined || Object.keys(files).some((k) => k === p || k.startsWith(p + "/"))) {
          return `ok ${p}/`;
        }
        const next = { ...files, [keep]: "" };
        set({ files: next });
        scheduleSync(next, get().projectId);
        return `criado ${p}/`;
      },
      grep: (pattern, path) => {
        let re: RegExp;
        try {
          re = new RegExp(pattern, "i");
        } catch {
          return "regex inválida";
        }
        const { files } = get();
        const hits: string[] = [];
        for (const [p, content] of Object.entries(files)) {
          if (isNoisePath(p)) continue;
          if (path && p !== path && !p.startsWith(path.replace(/\/+$/, "") + "/")) {
            continue;
          }
          const lines = content.split("\n");
          lines.forEach((line, i) => {
            if (re.test(line) && hits.length < 40) {
              hits.push(`${p}:${i + 1}: ${line.trimEnd()}`);
            }
          });
        }
        return hits.length ? hits.join("\n") : "sem resultados";
      },
      commit: (message, all = false) => {
        const msg = message.trim();
        if (!msg) return "informe a mensagem";
        const { files, commits, staged, stagedBlobs } = get();
        const head = commits[commits.length - 1];
        const headFiles = head?.files ?? {};
        const changed = get().changedPaths();
        const pick = all ? changed : staged.filter((p) => changed.includes(p) || stagedBlobs[p] !== undefined);
        if (!pick.length) return all ? "nada para commitar" : "nada staged — usa Stage ou git commit -a";
        const next = cloneFiles(headFiles);
        for (const p of pick) {
          const blob = all ? files[p] : (stagedBlobs[p] !== undefined ? stagedBlobs[p] : files[p]);
          if (blob === undefined) delete next[p];
          else next[p] = blob;
        }
        if (head && filesEqual(next, head.files)) return "nada para commitar";
        const c: Commit = {
          id: uid().slice(0, 8),
          message: msg,
          at: Date.now(),
          files: next,
        };
        const leftBlobs = { ...stagedBlobs };
        for (const p of pick) delete leftBlobs[p];
        set({
          commits: [...commits, c],
          staged: staged.filter((p) => !pick.includes(p)),
          stagedBlobs: leftBlobs,
        });
        return `[${c.id}] ${pick.length} arquivo(s) · ${c.message}`;
      },
      gitStatus: () => {
        const { files, commits, lastPushedId, staged, stagedBlobs, branch, origin } = get();
        const changed = get().changedPaths();
        const aheadN = (() => {
          if (!lastPushedId) return commits.length;
          const i = commits.findIndex((c) => c.id === lastPushedId);
          if (i < 0) return commits.length;
          return Math.max(0, commits.length - 1 - i);
        })();
        const behind = origin && !commits.some((c) => c.id === origin.id);
        const rel = [
          aheadN > 0 ? `ahead of origin by ${aheadN}` : null,
          behind ? "behind origin" : null,
          !aheadN && !behind ? "up to date with origin" : null,
        ]
          .filter(Boolean)
          .join(", ");
        const unstaged = changed.filter((p) => !staged.includes(p));
        const stagedThen = staged.filter((p) => stagedBlobs[p] !== undefined && files[p] !== stagedBlobs[p]);
        const lines = [
          `on branch ${branch}`,
          rel,
          staged.length ? "changes to be committed:" : "",
          ...staged.map((p) => `  staged:     ${p}`),
          stagedThen.length ? "staged then modified:" : "",
          ...stagedThen.map((p) => `  modified:   ${p}`),
          unstaged.length ? "changes not staged:" : "",
          ...unstaged.map((p) => `  modified:   ${p}`),
          !changed.length && !staged.length ? "working tree clean" : "",
        ].filter(Boolean);
        return lines.join("\n");
      },
      gitLog: () => {
        const { commits } = get();
        return [...commits]
          .reverse()
          .map((c) => `${c.id}  ${c.message}`)
          .join("\n");
      },
      gitPush: () => {
        const { commits, origin } = get();
        const head = commits[commits.length - 1];
        if (!head) return "nada para enviar";
        if (origin?.id === head.id) return "Everything up-to-date";
        set({
          lastPushedId: head.id,
          origin: { ...head, files: cloneFiles(head.files) },
        });
        return `gravado localmente ${head.id} · ${head.message}\n(não foi pro GitHub)`;
      },
      gitFetch: () => {
        const { origin, commits } = get();
        const behind = origin && !commits.some((c) => c.id === origin.id);
        if (behind) return `origin está à frente (fetch)\nconecta o GitHub pra puxar a rede`;
        return "fetch local — sem GitHub, origin não muda";
      },
      gitPull: () => {
        const { origin, commits, files } = get();
        const head = commits[commits.length - 1];
        if (!origin) {
          if (head) set({ origin: { ...head, files: cloneFiles(head.files) }, lastPushedId: head.id });
          return "Already up to date.";
        }
        if (head && origin.id === head.id) return "Already up to date.";
        if (commits.some((c) => c.id === origin.id)) return "Already up to date.";
        if (head && !filesEqual(files, head.files)) {
          return "error: suas mudanças locais seriam sobrescritas. commite ou descarte antes.";
        }
        set({
          commits: [...commits, origin],
          files: cloneFiles(origin.files),
          lastPushedId: origin.id,
          staged: [],
          stagedBlobs: {},
        });
        return `Updating ${head?.id ?? "000"}..${origin.id}\nFast-forward\nAlready on main`;
      },
      gitSync: () => {
        const pull = get().gitPull();
        if (pull.startsWith("error")) return pull;
        const push = get().gitPush();
        return `${pull}\n${push}`;
      },
      gitStage: (path) =>
        set((s) => ({
          staged: s.staged.includes(path) ? s.staged : [...s.staged, path],
          stagedBlobs: { ...s.stagedBlobs, [path]: s.files[path] ?? "" },
        })),
      gitUnstage: (path) =>
        set((s) => {
          const blobs = { ...s.stagedBlobs };
          delete blobs[path];
          return { staged: s.staged.filter((p) => p !== path), stagedBlobs: blobs };
        }),
      gitStageAll: () => {
        const paths = get().changedPaths();
        const files = get().files;
        const blobs: FileMap = {};
        for (const p of paths) blobs[p] = files[p] ?? "";
        set({ staged: paths, stagedBlobs: blobs });
      },
      gitUnstageAll: () => set({ staged: [], stagedBlobs: {} }),
      gitDiscard: (path) => {
        const { commits, files, staged, stagedBlobs } = get();
        const head = commits[commits.length - 1];
        const next = { ...files };
        if (!head || head.files[path] === undefined) delete next[path];
        else next[path] = head.files[path];
        const blobs = { ...stagedBlobs };
        delete blobs[path];
        set({ files: next, staged: staged.filter((p) => p !== path), stagedBlobs: blobs });
        scheduleSync(next, get().projectId);
        return `descartado ${path}`;
      },
      gitDiscardAll: () => {
        const { commits } = get();
        const head = commits[commits.length - 1];
        if (!head) return "nada para descartar";
        set({ files: cloneFiles(head.files), staged: [], stagedBlobs: {} });
        scheduleSync(head.files, get().projectId);
        return "working tree restaurada para HEAD";
      },
      gitUndoCommit: () => {
        const { commits, lastPushedId } = get();
        if (commits.length < 2) return "não há commit para desfazer";
        const dropped = commits[commits.length - 1]!;
        const prev = commits[commits.length - 2]!;
        const keys = new Set([...Object.keys(dropped.files), ...Object.keys(prev.files)]);
        const staged = [...keys].filter((k) => dropped.files[k] !== prev.files[k]);
        set({
          commits: commits.slice(0, -1),
          staged,
          lastPushedId: lastPushedId === dropped.id ? prev.id : lastPushedId,
        });
        return `HEAD agora em ${prev.id} (soft)`;
      },
      gitBranchList: () => {
        const { branch, branchSnaps } = get();
        return [...new Set([branch, ...Object.keys(branchSnaps)])].sort();
      },
      gitBranchCreate: (name) => {
        const n = name.trim().replace(/\s+/g, "-");
        if (!n) return "nome inválido";
        const { branch, branchSnaps } = get();
        if (n === branch || branchSnaps[n]) return `branch já existe: ${n}`;
        set({
          branchSnaps: { ...branchSnaps, [branch]: snapBranch(get()), [n]: snapBranch(get()) },
          branch: n,
        });
        return `criada e em ${n}`;
      },
      gitCheckout: (name) => {
        const n = name.trim();
        const s = get();
        if (!n) return "informe o branch";
        if (n === s.branch) return `já em ${n}`;
        if (get().isDirty()) return "error: commit ou stash antes de trocar de branch";
        const snaps = { ...s.branchSnaps, [s.branch]: snapBranch(s) };
        const dest = snaps[n];
        if (!dest) return `branch desconhecida: ${n}`;
        set({
          branchSnaps: snaps,
          branch: n,
          files: cloneFiles(dest.files),
          commits: dest.commits,
          staged: dest.staged,
          stagedBlobs: dest.stagedBlobs ? cloneFiles(dest.stagedBlobs) : {},
          lastPushedId: dest.lastPushedId,
          origin: dest.origin,
        });
        scheduleSync(dest.files, get().projectId);
        return `trocou para ${n}`;
      },
      gitStash: () => {
        const s = get();
        const changed = get().changedPaths();
        if (!changed.length) return "nada para stash";
        const head = s.commits[s.commits.length - 1];
        if (!head) return "sem HEAD";
        const entry: StashEntry = {
          id: uid().slice(0, 8),
          message: `WIP on ${s.branch}`,
          files: cloneFiles(s.files),
          staged: [...s.staged],
          stagedBlobs: cloneFiles(s.stagedBlobs),
        };
        set({
          stash: [entry, ...s.stash].slice(0, 12),
          files: cloneFiles(head.files),
          staged: [],
          stagedBlobs: {},
        });
        scheduleSync(head.files, get().projectId);
        return `stash@{0}: ${entry.message}`;
      },
      gitStashPop: () => {
        const s = get();
        const top = s.stash[0];
        if (!top) return "stash vazio";
        if (get().isDirty()) return "error: commit ou descarte antes do stash pop";
        set({
          files: cloneFiles(top.files),
          staged: top.staged,
          stagedBlobs: top.stagedBlobs ? cloneFiles(top.stagedBlobs) : {},
          stash: s.stash.slice(1),
        });
        scheduleSync(top.files, get().projectId);
        return `aplicado ${top.id}`;
      },
      gitCherryPick: (id) => {
        const { commits, files } = get();
        const i = commits.findIndex((c) => c.id === id);
        if (i < 0) return "commit não encontrado";
        const cur = commits[i]!;
        const prev = i > 0 ? commits[i - 1] : undefined;
        const next = { ...files };
        for (const [k, v] of Object.entries(cur.files)) {
          if (!prev || prev.files[k] !== v) next[k] = v;
        }
        if (prev) {
          for (const k of Object.keys(prev.files)) {
            if (cur.files[k] === undefined) delete next[k];
          }
        }
        set({
          files: next,
          staged: [...new Set([...Object.keys(next), ...Object.keys(files)])].filter(
            (k) => next[k] !== files[k],
          ),
        });
        return get().commit(`cherry-pick ${id}: ${cur.message}`);
      },
      gitBlame: (path) => {
        const { commits, files } = get();
        const working = (files[path] ?? "").split("\n");
        let prevText = "";
        let prevBlame: BlameLine[] = [];
        for (const c of commits) {
          const cur = c.files[path];
          if (cur === undefined && !prevText) continue;
          const curText = cur ?? "";
          const curLines = curText.split("\n");
          const next: BlameLine[] = curLines.map((text, i) => ({
            line: i + 1,
            text,
            id: c.id,
            message: c.message,
            at: c.at,
          }));
          if (prevBlame.length) {
            const diff = lineDiff(prevText, curText);
            let pi = 0;
            let ni = 0;
            for (const row of diff) {
              if (row.kind === "eq") {
                const keep = prevBlame[pi];
                if (keep && next[ni]) next[ni] = { ...keep, line: ni + 1, text: row.text };
                pi += 1;
                ni += 1;
              } else if (row.kind === "del") {
                pi += 1;
              } else {
                ni += 1;
              }
            }
          }
          prevText = curText;
          prevBlame = next;
        }
        const workText = files[path] ?? "";
        if (!prevBlame.length) {
          return working.map((text, i) => ({
            line: i + 1,
            text,
            id: "—",
            message: "uncommitted",
            at: 0,
          }));
        }
        const out: BlameLine[] = working.map((text, i) => ({
          line: i + 1,
          text,
          id: "—",
          message: "uncommitted",
          at: 0,
        }));
        const diff = lineDiff(prevText, workText);
        let pi = 0;
        let ni = 0;
        for (const row of diff) {
          if (row.kind === "eq") {
            const keep = prevBlame[pi];
            if (keep && out[ni]) out[ni] = { ...keep, line: ni + 1, text: row.text };
            pi += 1;
            ni += 1;
          } else if (row.kind === "del") {
            pi += 1;
          } else {
            ni += 1;
          }
        }
        return out;
      },
      gitRestoreCommit: (id) => {
        const c = get().commits.find((x) => x.id === id || x.sha === id || x.sha?.startsWith(id));
        if (!c) return "commit não encontrado";
        if (c.files && Object.keys(c.files).length) {
          set({ files: cloneFiles(c.files), staged: [], stagedBlobs: {} });
          scheduleSync(c.files, get().projectId);
          return `arquivos restaurados de ${c.id}  ${c.message}`;
        }
        return `PENDING_SHA:${c.sha || c.id}`;
      },
      gitApplyHunk: (path, index, keep) => {
        const { files, commits } = get();
        const head = commits[commits.length - 1]?.files[path] ?? "";
        const current = files[path];
        if (current === undefined) return "arquivo não existe";
        const next = keep ? keepOnlyHunk(head, current, index) : discardHunk(head, current, index);
        get().writeFile(path, next);
        return keep ? `hunk ${index + 1} aplicado` : `hunk ${index + 1} descartado`;
      },
      renameFile: (from, to) => {
        const src = sanitizePath(from);
        const dest = sanitizePath(to);
        if (!src || !dest) return "caminho inválido";
        const { files, tabs, openPath, staged } = get();
        if (files[src] === undefined) return "arquivo não existe";
        if (src === dest) return undefined;
        if (files[dest] !== undefined) return "já existe";
        const next = { ...files, [dest]: files[src] };
        delete next[src];
        set({
          files: next,
          tabs: tabs.map((t) => (t === src ? dest : t)),
          openPath: openPath === src ? dest : openPath,
          staged: staged.map((t) => (t === src ? dest : t)),
        });
        scheduleSync(next, get().projectId);
        void import("./folder").then((m) => m.removeFromFolder(src, get().projectId));
        return undefined;
      },
      replaceInFiles: (pattern, replacement, onlyPath) => {
        let re: RegExp;
        try {
          re = new RegExp(pattern, "gi");
        } catch {
          return { files: 0, hits: 0 };
        }
        const files = { ...get().files };
        let fileCount = 0;
        let hits = 0;
        for (const [p, text] of Object.entries(files)) {
          if (isNoisePath(p)) continue;
          if (onlyPath && p !== onlyPath) continue;
          const next = text.replace(re, () => {
            hits += 1;
            return replacement;
          });
          if (next !== text) {
            files[p] = next;
            fileCount += 1;
          }
        }
        if (fileCount) {
          set({ files });
          scheduleSync(files, get().projectId);
        }
        return { files: fileCount, hits };
      },
      resolveConflict: (path, take, merged) => {
        const s = get();
        const c = s.conflicts.find((x) => x.path === path);
        if (!c) return;
        const body = take === "ours" ? c.ours : take === "theirs" ? c.theirs : (merged ?? c.ours);
        const files = { ...s.files, [path]: body };
        set({ files, conflicts: s.conflicts.filter((x) => x.path !== path) });
        scheduleSync(files, get().projectId);
      },
      mergeRemote: (incoming) => {
        const s = get();
        const head = s.commits[s.commits.length - 1];
        const origin = s.origin;
        const conflicts: Conflict[] = [];
        const files = { ...s.files };
        if (origin) {
          for (const path of Object.keys(origin.files)) {
            if (incoming[path] === undefined && (files[path] === undefined || files[path] === origin.files[path])) {
              delete files[path];
            }
          }
        }
        for (const [path, theirs] of Object.entries(incoming)) {
          const ours = files[path];
          const base = origin?.files[path] ?? head?.files[path];
          if (ours !== undefined && ours !== base && theirs === base) {
            continue;
          }
          if (ours === undefined || ours === theirs || ours === base) {
            files[path] = theirs;
            continue;
          }
          if (base !== theirs && ours !== base) {
            conflicts.push({ path, ours, theirs });
            files[path] = `<<<<<<< HEAD\n${ours}\n=======\n${theirs}\n>>>>>>> origin\n`;
          } else {
            files[path] = theirs;
          }
        }
        if (conflicts.length) {
          set({ files, conflicts });
          scheduleSync(files, get().projectId);
          return `error: merge com ${conflicts.length} conflito(s) — resolve antes de sync`;
        }
        if (head && filesEqual(files, head.files)) {
          set({
            origin: { id: head.id, message: "origin", at: Date.now(), files: cloneFiles(incoming) },
            lastPushedId: s.lastPushedId ?? head.id,
            conflicts: [],
          });
          return `Already up to date. · ${Object.keys(incoming).length} arquivos`;
        }
        const clean = !head || filesEqual(s.files, head.files);
        const ff = clean && origin && filesEqual(s.files, origin.files);
        const commit: Commit = {
          id: uid().slice(0, 8),
          message: ff ? "pull origin" : "merge origin",
          at: Date.now(),
          files: cloneFiles(files),
        };
        set({
          files,
          commits: [...s.commits, commit],
          origin: { id: commit.id, message: "origin", at: commit.at, files: cloneFiles(incoming) },
          lastPushedId: ff ? commit.id : s.lastPushedId,
          conflicts: [],
          staged: [],
          stagedBlobs: {},
        });
        scheduleSync(files, get().projectId);
        return `pull ok · ${Object.keys(incoming).length} arquivos`;
      },
      gitApplyFetch: (incoming) => {
        const prev = get().origin;
        if (prev && filesEqual(prev.files, incoming)) {
          return `fetch origin  já atualizado · ${Object.keys(incoming).length} arquivos`;
        }
        const origin: Commit = {
          id: `fetch-${uid().slice(0, 6)}`,
          message: "origin",
          at: Date.now(),
          files: cloneFiles(incoming),
        };
        set({ origin });
        return `fetch origin  ${Object.keys(incoming).length} arquivos`;
      },
      changedPaths: () => {
        const { files, commits } = get();
        const head = commits[commits.length - 1];
        if (!head) return Object.keys(files).filter((k) => !isNoisePath(k));
        const keys = new Set([...Object.keys(files), ...Object.keys(head.files)]);
        const changed: string[] = [];
        for (const k of keys) {
          if (isNoisePath(k)) continue;
          if (files[k] !== head.files[k]) changed.push(k);
        }
        return changed.sort();
      },
      fileDirty: (path) => {
        const { files, commits } = get();
        const head = commits[commits.length - 1];
        if (!head) return true;
        return files[path] !== head.files[path];
      },
      termPrint: (kind, text) => {
        useTerms.getState().print(kind, text);
        set((s) => ({
          terminal: [...s.terminal.slice(-40), { id: uid(), kind, text }],
        }));
      },
      termClear: () => {
        useTerms.getState().clear();
        set({ terminal: [] });
      },
      setCwd: (path) => {
        const clean = path.replace(/^\/+|\/+$/g, "");
        set({ cwd: clean });
      },
      rememberNow: () => {
        const s = get();
        useProjects.getState().remember({
          id: s.projectId,
          name: s.projectName,
          files: Object.keys(s.files).length,
          remote: s.remote,
          branch: s.branch,
          snapshot: cloneFiles(s.files),
        });
      },
      loadProject: (p) => {
        get().rememberNow();
        const files = cloneFiles(p.files);
        const first = Object.keys(files).sort().find((k) => k === "README.md") ?? Object.keys(files).sort()[0] ?? "README.md";
        const history: Commit[] | null = p.history?.length
          ? p.history.map((h, i, arr) => ({
              id: h.sha.slice(0, 8),
              sha: h.sha,
              message: h.message,
              at: h.at,
              files:
                h.files && Object.keys(h.files).length
                  ? cloneFiles(h.files)
                  : i === arr.length - 1
                    ? cloneFiles(files)
                    : {},
            }))
          : null;
        const commit: Commit = history?.at(-1) ?? {
          id: uid().slice(0, 8),
          message: p.message || `abrir ${p.name}`,
          at: Date.now(),
          files: cloneFiles(files),
        };
        if (history) history[history.length - 1] = { ...commit, files: cloneFiles(files), sha: commit.sha ?? history.at(-1)?.sha };
        set({
          files,
          openPath: files[first] !== undefined ? first : Object.keys(files)[0] ?? "README.md",
          tabs: [first],
          commits: history ?? [commit],
          lastPushedId: p.pushed === false ? null : commit.id,
          origin: { ...commit, files: cloneFiles(files) },
          staged: [],
          stagedBlobs: {},
          branch: p.branch || "main",
          cwd: "",
          projectId: p.id,
          projectName: p.name,
          remote: p.remote ?? null,
          branchSnaps: {},
          stash: [],
          conflicts: [],
          terminal: [{ id: uid(), kind: "ok", text: `projeto ${p.name}` }],
        });
        scheduleSync(files, get().projectId);
      },
      newProject: (name) => {
        const title = name.trim() || "sem título";
        get().loadProject({
          id: uid(),
          name: title,
          files: { "README.md": `# ${title}\n\nProjeto novo na Odete.\n` },
          remote: null,
          branch: "main",
          message: "chore: projeto novo",
        });
      },
      closeProject: () => {
        get().newProject("vazio");
      },
      importFiles: (incoming, replace = false) => {
        const files = replace ? cloneFiles(incoming) : { ...get().files, ...incoming };
        const first = Object.keys(files).sort()[0] ?? "README.md";
        set({
          files,
          openPath: files[get().openPath] !== undefined ? get().openPath : first,
          tabs: replace ? [first] : get().tabs,
        });
        scheduleSync(files, get().projectId);
      },
      resetWorkspace: () =>
        set({
          ...freshState(),
          terminal: [{ id: uid(), kind: "ok", text: "workspace restaurado" }],
        }),
      isDirty: () => {
        const { files, commits } = get();
        const head = commits[commits.length - 1];
        return !head || !filesEqual(files, head.files);
      },
    }),
    {
      name: "colo-workspace-v2",
      storage: createJSONStorage(() => workspaceStorage),
      partialize: (s) => ({
        files: persistFiles(s.files),
        openPath: s.openPath,
        tabs: s.tabs.filter((t) => !t.startsWith("node_modules/")),
        commits: s.commits.slice(-12).map(persistCommit),
        lastPushedId: s.lastPushedId,
        origin: s.origin ? persistCommit(s.origin) : s.origin,
        branch: s.branch,
        cwd: s.cwd,
        projectId: s.projectId,
        projectName: s.projectName,
        remote: s.remote,
        branchSnaps: Object.fromEntries(
          Object.entries(s.branchSnaps).slice(-6).map(([k, v]) => [
            k,
            {
              ...v,
              files: persistFiles(v.files),
              commits: v.commits.slice(-8).map(persistCommit),
              stagedBlobs: persistFiles(v.stagedBlobs ?? {}),
            },
          ]),
        ),
        stash: s.stash.slice(0, 4).map((x) => ({
          ...x,
          files: persistFiles(x.files),
          stagedBlobs: persistFiles(x.stagedBlobs ?? {}),
        })),
        conflicts: s.conflicts,
        staged: s.staged,
        stagedBlobs: persistFiles(s.stagedBlobs ?? {}),
      }),
      onRehydrateStorage: () => (state) => {
        if (!state) return;
        if (!state.files || Object.keys(state.files).length === 0) {
          if (usePersistHealth.getState().freeze || (state as { disk?: boolean }).disk) {
            state.hydrated = true;
            return;
          }
          Object.assign(state, freshState());
        }
        if (!state.tabs?.length) {
          state.tabs = [state.openPath || "README.md"];
        }
        if (!state.origin) {
          const head = state.commits?.[state.commits.length - 1];
          state.origin = head
            ? { ...head, files: { ...head.files } }
            : {
                id: "seed",
                message: SEED_COMMIT_MESSAGE,
                at: Date.now(),
                files: { ...SEED_FILES },
              };
        }
        if (!state.staged) state.staged = [];
        if (!state.stagedBlobs) state.stagedBlobs = {};
        if (!state.branch) state.branch = "main";
        if (!state.branchSnaps) state.branchSnaps = {};
        if (!state.stash) state.stash = [];
        if (!state.conflicts) state.conflicts = [];
        if (!state.projectId) state.projectId = "seed";
        if (!state.projectName) state.projectName = "colo";
        if (state.remote === undefined) state.remote = null;
        state.hydrated = true;
      },
    },
  ),
);

export function pathExists(path: string) {
  return useWorkspace.getState().files[path] !== undefined;
}

export { parentDir };
