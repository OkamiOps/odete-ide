import { create } from "zustand";
import type { FileSystemTree, WebContainer, WebContainerProcess } from "@webcontainer/api";
import { unpackBin } from "@/lib/github/api";
import { isNoisePath } from "./ignore";
import type { FileMap } from "./types";
import { useWorkspace } from "./store";

export type NodeStatus = "off" | "booting" | "ready" | "running" | "unsupported";

type NodeState = {
  status: NodeStatus;
  previewUrl: string;
  isolated: boolean;
  reason: string;
};

type Host = typeof globalThis & {
  __coloWc?: WebContainer;
  __coloWcBoot?: Promise<WebContainer | null>;
  __coloWcMount?: { projectId: string; lastFiles: FileMap };
};

const HOST = globalThis as Host;

export const useNodeRuntime = create<NodeState>(() => ({
  status: "off",
  previewUrl: "",
  isolated: false,
  reason: "",
}));

let wc: WebContainer | null = HOST.__coloWc ?? null;
let bootP: Promise<WebContainer | null> | null = HOST.__coloWcBoot ?? null;
let mountedFor = HOST.__coloWcMount?.projectId ?? "";
let lastFiles: FileMap = HOST.__coloWcMount?.lastFiles ?? {};
let running: WebContainerProcess | null = null;
let jobs = new Set<WebContainerProcess>();
let jobOwner = new WeakMap<WebContainerProcess, string>();
let jobSlot = "";
let pulling = false;
let unsubWs: (() => void) | null = null;
let unsubReady: (() => void) | null = null;

function isolatedNow() {
  return typeof window !== "undefined" && !!window.crossOriginIsolated && typeof SharedArrayBuffer !== "undefined";
}

function parentDir(path: string) {
  const i = path.lastIndexOf("/");
  return i <= 0 ? "" : path.slice(0, i);
}

function fileBytes(contents: string): string | Uint8Array {
  const bin = unpackBin(contents);
  if (!bin) return contents;
  const raw = atob(bin.b64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

function scriptBody(files: FileMap, name: string) {
  try {
    const pkg = JSON.parse(files["package.json"] || "{}") as { scripts?: Record<string, string> };
    return pkg.scripts?.[name] ?? "";
  } catch {
    return "";
  }
}

function rememberMount(projectId: string, files: FileMap) {
  mountedFor = projectId;
  lastFiles = { ...files };
  HOST.__coloWcMount = { projectId, lastFiles };
}

export function filesToTree(files: FileMap): FileSystemTree {
  const root: FileSystemTree = {};
  for (const [path, contents] of Object.entries(files)) {
    if (isNoisePath(path) || path.startsWith("__colo")) continue;
    const parts = path.split("/").filter(Boolean);
    let node = root;
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i]!;
      const last = i === parts.length - 1;
      if (last) {
        node[part] = { file: { contents: fileBytes(contents) } };
      } else {
        const cur = node[part];
        if (!cur || !("directory" in cur)) node[part] = { directory: {} };
        node = (node[part] as { directory: FileSystemTree }).directory;
      }
    }
  }
  return root;
}

function manager(files: FileMap, prefer?: string) {
  if (prefer === "pnpm" || files["pnpm-workspace.yaml"] || files["pnpm-lock.yaml"]) {
    return { bin: "pnpm", install: ["install"] as string[] };
  }
  if (prefer === "yarn" || (prefer !== "npm" && files["yarn.lock"])) {
    return { bin: "yarn", install: ["install"] as string[] };
  }
  return { bin: "npm", install: ["install"] as string[] };
}

function cleanChunk(chunk: string) {
  const esc = String.fromCharCode(27);
  const bel = String.fromCharCode(7);
  return String(chunk)
    .replace(new RegExp(`${esc}\\[[0-9;?]*[ -/]*[@-~]`, "g"), "")
    .replace(new RegExp(`${esc}\\][^${bel}]* (${bel}|${esc}\\\\)`, "g"), "")
    .replace(/\r/g, "");
}

function watchJob(proc: WebContainerProcess) {
  jobs.add(proc);
  if (jobSlot) jobOwner.set(proc, jobSlot);
  void proc.exit.then(() => jobs.delete(proc));
  return proc;
}

export function setNodeJobSlot(slot: string) {
  jobSlot = slot;
}

export function clearNodeJobSlot() {
  jobSlot = "";
}

async function stream(proc: WebContainerProcess, onLog: (s: string) => void) {
  const dec = proc.output.pipeTo(
    new WritableStream({
      write(chunk) {
        const text = cleanChunk(chunk);
        for (const line of text.split("\n")) {
          const t = line.trimEnd();
          if (!t || /^[|/\-\\]+$/.test(t.trim())) continue;
          onLog(t);
        }
      },
    }),
  );
  return dec.catch(() => undefined);
}

async function waitServer(ms: number) {
  if (!wc) return "";
  return new Promise<string>((resolve) => {
    const t = window.setTimeout(() => {
      off();
      resolve(useNodeRuntime.getState().previewUrl);
    }, ms);
    const off = wc!.on("server-ready", (_port, url) => {
      window.clearTimeout(t);
      off();
      useNodeRuntime.setState({ previewUrl: url, status: "running" });
      resolve(url);
    });
  });
}

async function hydrateFromDisk(projectId: string, files: FileMap): Promise<FileMap> {
  try {
    const { loadProject } = await import("./disk");
    const disk = await loadProject(projectId);
    if (!Object.keys(disk).length) return files;
    return { ...files, ...disk };
  } catch {
    return files;
  }
}

async function pullChanged(wcInst: WebContainer, dir = "", depth = 0, budget = { n: 0 }) {
  if (depth > 8 || budget.n > 400) return;
  const w = useWorkspace.getState();
  let names: string[] = [];
  try {
    names = await wcInst.fs.readdir(dir || ".");
  } catch {
    return;
  }
  for (const name of names) {
    if (name === "node_modules" || name === ".git" || name === "dist" || name === ".next" || name === "coverage") continue;
    const path = dir ? `${dir}/${name}` : name;
    if (isNoisePath(path)) continue;
    try {
      const txt = await wcInst.fs.readFile(path, "utf-8");
      if (txt && txt !== w.files[path]) w.writeFile(path, txt);
      budget.n += 1;
    } catch {
      await pullChanged(wcInst, path, depth + 1, budget);
    }
  }
}

async function pullManifest(wcInst: WebContainer) {
  pulling = true;
  try {
    await pullChanged(wcInst);
    try {
      const { saveProject } = await import("./disk");
      const snap = useWorkspace.getState();
      await saveProject(snap.projectId, snap.files);
    } catch {
      /* disco opcional */
    }
  } finally {
    pulling = false;
  }
}

async function mkdirp(path: string) {
  if (!wc || !path) return;
  try {
    await wc.fs.mkdir(path, { recursive: true });
  } catch {
    /* exists */
  }
}

async function syncFiles(files: FileMap, projectId: string) {
  if (!wc || pulling) return;
  if (mountedFor !== projectId) {
    await wc.mount(filesToTree(files));
    rememberMount(projectId, files);
    return;
  }
  const prev = lastFiles;
  const all = new Set([...Object.keys(prev), ...Object.keys(files)]);
  for (const path of all) {
    if (isNoisePath(path) || path.startsWith("__colo")) continue;
    const next = files[path];
    const old = prev[path];
    if (next === old) continue;
    if (next === undefined) {
      try {
        await wc.fs.rm(path, { force: true });
      } catch {
        /* gone */
      }
      continue;
    }
    await mkdirp(parentDir(path));
    try {
      await wc.fs.writeFile(path, fileBytes(next));
    } catch {
      await mkdirp(parentDir(path));
      await wc.fs.writeFile(path, fileBytes(next));
    }
  }
  rememberMount(projectId, files);
}

function watchWorkspace() {
  unsubWs?.();
  let timer = 0;
  unsubWs = useWorkspace.subscribe((s, prev) => {
    if (s.files === prev.files && s.projectId === prev.projectId) return;
    if (pulling) return;
    window.clearTimeout(timer);
    timer = window.setTimeout(() => {
      void syncFiles(s.files, s.projectId);
    }, 160);
  });
}

export function nodeUnsupportedReason() {
  if (typeof window === "undefined") return "sem janela";
  if (!window.crossOriginIsolated) {
    return "Node precisa do app em tela cheia com origem isolada. Nesta prévia embutida o Node real não sobe — cai no Preview da Odete.";
  }
  if (typeof SharedArrayBuffer === "undefined") return "SharedArrayBuffer indisponível neste WebView";
  return "";
}

export async function ensureNode(onLog?: (s: string) => void): Promise<WebContainer | null> {
  if (typeof window === "undefined") return null;
  const reason = nodeUnsupportedReason();
  if (reason) {
    useNodeRuntime.setState({ status: "unsupported", isolated: false, reason });
    return null;
  }
  if (HOST.__coloWc) {
    wc = HOST.__coloWc;
    mountedFor = HOST.__coloWcMount?.projectId ?? mountedFor;
    lastFiles = HOST.__coloWcMount?.lastFiles ?? lastFiles;
    watchWorkspace();
    if (useNodeRuntime.getState().status === "off" || useNodeRuntime.getState().status === "unsupported") {
      useNodeRuntime.setState({ status: "ready", isolated: true, reason: "" });
    }
    return wc;
  }
  if (wc) return wc;
  if (HOST.__coloWcBoot) return HOST.__coloWcBoot;
  if (bootP) return bootP;
  useNodeRuntime.setState({ status: "booting", isolated: true, reason: "" });
  onLog?.("Node: a arrancar no iPad…");
  bootP = (async () => {
    try {
      const { WebContainer } = await import("@webcontainer/api");
      const inst = await WebContainer.boot({
        coep: "credentialless",
        workdirName: "odete",
        forwardPreviewErrors: "exceptions-only",
      });
      wc = inst;
      HOST.__coloWc = inst;
      unsubReady?.();
      unsubReady = inst.on("server-ready", (_port, url) => {
        useNodeRuntime.setState({ previewUrl: url, status: "running" });
      });
      inst.on("error", (err) => {
        onLog?.(`Node: ${err.message}`);
      });
      const w = useWorkspace.getState();
      const files = await hydrateFromDisk(w.projectId, w.files);
      await inst.mount(filesToTree(files));
      rememberMount(w.projectId, files);
      watchWorkspace();
      useNodeRuntime.setState({ status: "ready", isolated: true, reason: "" });
      onLog?.("Node pronto. npm run dev usa o Node deste iPad.");
      return inst;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (/single WebContainer/i.test(msg) && HOST.__coloWc) {
        wc = HOST.__coloWc;
        useNodeRuntime.setState({ status: "ready", isolated: true, reason: "" });
        return wc;
      }
      useNodeRuntime.setState({ status: "unsupported", isolated: isolatedNow(), reason: msg });
      onLog?.(`Node falhou: ${msg}`);
      bootP = null;
      HOST.__coloWcBoot = undefined;
      wc = null;
      return null;
    }
  })();
  HOST.__coloWcBoot = bootP;
  return bootP;
}

export async function nodeSpawn(cmd: string, args: string[], onLog: (s: string) => void): Promise<{ used: boolean; code: number; out: string }> {
  const inst = await ensureNode(onLog);
  if (!inst) return { used: false, code: 1, out: nodeUnsupportedReason() };
  await syncFiles(
    await hydrateFromDisk(useWorkspace.getState().projectId, useWorkspace.getState().files),
    useWorkspace.getState().projectId,
  );
  const proc = await inst.spawn(cmd, args);
  watchJob(proc);
  await stream(proc, onLog);
  const code = await proc.exit;
  await pullManifest(inst);
  return { used: true, code, out: `${cmd} ${args.join(" ")} → ${code}` };
}

export async function nodeInstall(args: string[], onLog: (s: string) => void, prefer?: string) {
  const inst = await ensureNode(onLog);
  if (!inst) return { used: false, out: "" };
  await syncFiles(
    await hydrateFromDisk(useWorkspace.getState().projectId, useWorkspace.getState().files),
    useWorkspace.getState().projectId,
  );
  const m = manager(useWorkspace.getState().files, prefer);
  const argv = args.length
    ? m.bin === "yarn"
      ? ["add", ...args.filter((a) => a !== "i" && a !== "install")]
      : ["i", ...args]
    : m.install.length
      ? m.install
      : ["i"];
  onLog?.(`${m.bin} ${argv.join(" ")}`);
  const proc = await inst.spawn(m.bin, argv);
  watchJob(proc);
  await stream(proc, onLog);
  const code = await proc.exit;
  await pullManifest(inst);
  return { used: true, out: code === 0 ? `${m.bin} install ok` : `${m.bin} install saiu ${code}` };
}

export async function nodeRunScript(name: string, onLog: (s: string) => void, prefer?: string) {
  const inst = await ensureNode(onLog);
  if (!inst) return { used: false, openPreview: false, out: "" };
  await syncFiles(
    await hydrateFromDisk(useWorkspace.getState().projectId, useWorkspace.getState().files),
    useWorkspace.getState().projectId,
  );
  let hasMods = false;
  try {
    const names = await inst.fs.readdir("node_modules");
    hasMods = names.length > 0;
  } catch {
    hasMods = false;
  }
  if (!hasMods) {
    onLog("sem node_modules — instalando…");
    await nodeInstall([], onLog, prefer);
  }
  const m = manager(useWorkspace.getState().files, prefer);
  if (running) {
    try {
      running.kill();
    } catch {
      /* already dead */
    }
    running = null;
    useNodeRuntime.setState({ previewUrl: "", status: "ready" });
  }
  const proc = await inst.spawn(m.bin, ["run", name]);
  running = proc;
  watchJob(proc);
  void stream(proc, onLog);
  void proc.exit.then((code) => {
    if (running === proc) {
      running = null;
      useNodeRuntime.setState((s) => ({
        status: s.previewUrl ? "running" : "ready",
      }));
      onLog(`npm run ${name} saiu ${code}`);
    }
  });
  const cmd = scriptBody(useWorkspace.getState().files, name);
  const long =
    /dev|start|preview|serve/i.test(name) || /\b(vite|next|nest|astro|remix|nuxt|tanstack)\b/i.test(cmd);
  if (long) {
    onLog(`npm run ${name} — à espera do servidor…`);
    const url = await waitServer(90_000);
    if (url) {
      return { used: true, openPreview: true, out: `npm run ${name}\npreview no Node deste iPad` };
    }
    return {
      used: true,
      openPreview: true,
      out: `npm run ${name} a correr. se o Preview ficar vazio, espera o compile (Next demora no 1º boot).`,
    };
  }
  const code = await proc.exit;
  running = null;
  await pullManifest(inst);
  return { used: true, openPreview: false, out: `npm run ${name} → ${code}` };
}

export async function nodeExecFile(file: string, argv: string[], onLog: (s: string) => void) {
  return nodeSpawn("node", [file, ...argv], onLog);
}

export function abortNodeJobs(slot?: string) {
  for (const p of [...jobs]) {
    if (slot && jobOwner.get(p) !== slot) continue;
    try {
      p.kill();
    } catch {
      /* */
    }
    jobs.delete(p);
  }
  if (running && (!slot || jobOwner.get(running) === slot)) {
    running = null;
    useNodeRuntime.setState({ previewUrl: "", status: wc ? "ready" : "off" });
  }
}

export function stopNodeDev() {
  abortNodeJobs();
}
