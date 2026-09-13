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

async function putHandle(dir: FileSystemDirectoryHandle) {
  const db = await openDb();
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(STORE, "readwrite");
    tx.objectStore(STORE).put(dir, "root");
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

export async function getHandle(): Promise<FileSystemDirectoryHandle | null> {
  try {
    const db = await openDb();
    const dir = await new Promise<FileSystemDirectoryHandle | undefined>((resolve, reject) => {
      const tx = db.transaction(STORE, "readonly");
      const g = tx.objectStore(STORE).get("root");
      g.onsuccess = () => resolve(g.result as FileSystemDirectoryHandle | undefined);
      g.onerror = () => reject(g.error);
    });
    if (!dir) return null;
    const q = await dir.queryPermission({ mode: "readwrite" });
    if (q === "granted") return dir;
    const req = await dir.requestPermission({ mode: "readwrite" });
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

export async function writeTree(dir: FileSystemDirectoryHandle, files: FileMap) {
  for (const [path, body] of Object.entries(files)) {
    const fh = await ensurePath(dir, path);
    const w = await fh.createWritable();
    await w.write(bytesOf(body));
    await w.close();
  }
}

export async function saveHandle(dir: FileSystemDirectoryHandle) {
  await putHandle(dir);
}

export async function bindFolder() {
  const w = window as Window & {
    showDirectoryPicker?: (opts?: { mode?: string }) => Promise<FileSystemDirectoryHandle>;
  };
  if (!w.showDirectoryPicker) throw new Error("este browser não abre pasta do Files");
  const dir = await w.showDirectoryPicker({ mode: "readwrite" });
  await putHandle(dir);
  return dir;
}

let timer: number | null = null;
export function scheduleSync(files: FileMap) {
  if (timer) window.clearTimeout(timer);
  timer = window.setTimeout(() => {
    void getHandle().then((dir) => {
      if (dir) return writeTree(dir, files);
    });
  }, 800);
}
