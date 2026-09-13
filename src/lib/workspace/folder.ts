import { unpackBin } from "@/lib/github/api";
import type { FileMap } from "./types";

const DB = "colo-handles";
const STORE = "h";

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => {
      if (!req.result.objectStoreNames.contains(STORE)) req.result.createObjectStore(STORE);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function putHandle(dir: FileSystemDirectoryHandle, projectId: string) {
  const db = await openDb();
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(STORE, "readwrite");
    tx.objectStore(STORE).put(dir, `dir:${projectId}`);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

export async function getHandle(opts?: { prompt?: boolean; projectId?: string }): Promise<FileSystemDirectoryHandle | null> {
  const projectId = opts?.projectId || "root";
  try {
    const db = await openDb();
    const dir = await new Promise<FileSystemDirectoryHandle | undefined>((resolve, reject) => {
      const tx = db.transaction(STORE, "readonly");
      const store = tx.objectStore(STORE);
      const g = store.get(`dir:${projectId}`);
      g.onsuccess = () => {
        if (g.result) {
          resolve(g.result as FileSystemDirectoryHandle);
          return;
        }
        if (projectId === "root") {
          resolve(undefined);
          return;
        }
        const legacy = store.get("root");
        legacy.onsuccess = () => resolve(legacy.result as FileSystemDirectoryHandle | undefined);
        legacy.onerror = () => reject(legacy.error);
      };
      g.onerror = () => reject(g.error);
    });
    if (!dir) return null;
    const fs = dir as FileSystemDirectoryHandle & {
      queryPermission: (o: { mode: string }) => Promise<PermissionState>;
      requestPermission: (o: { mode: string }) => Promise<PermissionState>;
    };
    const q = await fs.queryPermission({ mode: "readwrite" });
    if (q === "granted") return dir;
    if (!opts?.prompt) return null;
    const req = await fs.requestPermission({ mode: "readwrite" });
    return req === "granted" ? dir : null;
  } catch {
    return null;
  }
}

async function ensurePath(root: FileSystemDirectoryHandle, path: string) {
  const parts = path.split("/").filter(Boolean);
  const file = parts.pop()!;
  let dir = root;
  for (const p of parts) {
    dir = await dir.getDirectoryHandle(p, { create: true });
  }
  return dir.getFileHandle(file, { create: true });
}

function bytesOf(content: string) {
  const bin = unpackBin(content);
  if (bin) {
    const raw = atob(bin.b64);
    const out = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out;
  }
  return new TextEncoder().encode(content);
}

async function getWritten(projectId: string): Promise<string[]> {
  try {
    const db = await openDb();
    return await new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, "readonly");
      const g = tx.objectStore(STORE).get(`written:${projectId}`);
      g.onsuccess = () => resolve((g.result as string[] | undefined) ?? []);
      g.onerror = () => reject(g.error);
    });
  } catch {
    return [];
  }
}

async function putWritten(projectId: string, paths: string[]) {
  try {
    const db = await openDb();
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE, "readwrite");
      tx.objectStore(STORE).put(paths, `written:${projectId}`);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  } catch {
    /* ignore */
  }
}

async function dropPath(root: FileSystemDirectoryHandle, path: string) {
  const parts = path.split("/").filter(Boolean);
  const file = parts.pop();
  if (!file) return;
  let cur = root;
  for (const p of parts) cur = await cur.getDirectoryHandle(p);
  await cur.removeEntry(file);
}

export async function writeTree(dir: FileSystemDirectoryHandle, files: FileMap, projectId = "root") {
  const prev = await getWritten(projectId);
  for (const path of prev) {
    if (files[path] !== undefined) continue;
    try {
      await dropPath(dir, path);
    } catch {
      /* already gone */
    }
  }
  const skipNm = paused > 0;
  for (const [path, body] of Object.entries(files)) {
    if (skipNm && (path.startsWith("node_modules/") || path.includes("/node_modules/"))) continue;
    const fh = await ensurePath(dir, path);
    const w = await fh.createWritable();
    await w.write(bytesOf(body));
    await w.close();
  }
  await putWritten(projectId, Object.keys(files));
}

export async function removeFromFolder(path: string, projectId?: string) {
  const dir = await getHandle({ projectId });
  if (!dir) return;
  try {
    await dropPath(dir, path);
  } catch {
    /* ignore */
  }
}

export async function saveHandle(dir: FileSystemDirectoryHandle, projectId?: string) {
  await putHandle(dir, projectId || "root");
}

export async function bindFolder(projectId?: string) {
  const w = window as Window & {
    showDirectoryPicker?: (opts?: { mode?: string }) => Promise<FileSystemDirectoryHandle>;
  };
  if (!w.showDirectoryPicker) throw new Error("este browser não abre pasta do Files");
  const dir = await w.showDirectoryPicker({ mode: "readwrite" });
  await putHandle(dir, projectId || "root");
  return dir;
}

let timer: number | null = null;
let paused = 0;
let pending: { files: FileMap; projectId: string } | null = null;

export function pauseSync() {
  paused += 1;
}

export function resumeSync(files: FileMap, projectId: string) {
  paused = Math.max(0, paused - 1);
  if (!paused) scheduleSync(files, projectId);
}

export function scheduleSync(files: FileMap, projectId = "root") {
  if (paused) {
    pending = { files, projectId };
    return;
  }
  if (timer) window.clearTimeout(timer);
  const id = projectId;
  const snap = files;
  timer = window.setTimeout(() => {
    void getHandle({ projectId: id }).then((dir) => {
      if (dir) return writeTree(dir, snap, id);
    });
  }, 800);
}
