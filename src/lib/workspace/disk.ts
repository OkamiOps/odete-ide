import { create } from "zustand";

export type DiskBackend = "native" | "opfs" | "idb" | "memory";

export type NativeDisk = {
  readText: (path: string) => Promise<string | null>;
  writeText: (path: string, text: string) => Promise<void>;
  remove: (path: string) => Promise<void>;
  list: (prefix?: string) => Promise<string[]>;
  pickFolder?: (projectId: string) => Promise<string>;
  sql?: (q: string, params?: unknown[]) => Promise<{ rows: Record<string, unknown>[] }>;
  secretGet?: (key: string) => Promise<string | null>;
  secretSet?: (key: string, value: string) => Promise<void>;
  secretDelete?: (key: string) => Promise<void>;
};

type Host = typeof globalThis & {
  coloNative?: NativeDisk;
};

export const useDisk = create<{
  backend: DiskBackend;
  ok: boolean;
  lastError: string;
}>(() => ({
  backend: "memory",
  ok: true,
  lastError: "",
}));

export function nativeDisk(): NativeDisk | null {
  const g = globalThis as Host;
  if (g.coloNative) return g.coloNative;
  return null;
}

function native(): NativeDisk | null {
  return nativeDisk();
}

let mem = new Map<string, string>();
let opfsRoot: FileSystemDirectoryHandle | null = null;
let opfsTried = false;
let lastSaved: Record<string, string> = {};
let lastProject = "";

async function ensureOpfs(): Promise<FileSystemDirectoryHandle | null> {
  if (opfsRoot) return opfsRoot;
  if (opfsTried) return null;
  opfsTried = true;
  try {
    const storage = navigator.storage;
    if (!storage?.getDirectory) return null;
    const root = await storage.getDirectory();
    opfsRoot = await root.getDirectoryHandle("colo-disk", { create: true });
    return opfsRoot;
  } catch {
    opfsRoot = null;
    return null;
  }
}

async function opfsWalk(
  dir: FileSystemDirectoryHandle,
  prefix: string,
): Promise<FileSystemDirectoryHandle> {
  if (!prefix) return dir;
  let cur = dir;
  for (const part of prefix.split("/").filter(Boolean)) {
    cur = await cur.getDirectoryHandle(part, { create: true });
  }
  return cur;
}

async function opfsWrite(abs: string, text: string) {
  const root = await ensureOpfs();
  if (!root) throw new Error("opfs indisponível");
  const i = abs.lastIndexOf("/");
  const dirPath = i < 0 ? "" : abs.slice(0, i);
  const name = i < 0 ? abs : abs.slice(i + 1);
  const dir = await opfsWalk(root, dirPath);
  const fh = await dir.getFileHandle(name, { create: true });
  const w = await fh.createWritable();
  await w.write(text);
  await w.close();
}

async function opfsRead(abs: string): Promise<string | null> {
  const root = await ensureOpfs();
  if (!root) return null;
  try {
    const i = abs.lastIndexOf("/");
    const dirPath = i < 0 ? "" : abs.slice(0, i);
    const name = i < 0 ? abs : abs.slice(i + 1);
    const dir = await opfsWalk(root, dirPath);
    const fh = await dir.getFileHandle(name);
    const file = await fh.getFile();
    return await file.text();
  } catch {
    return null;
  }
}

async function opfsRemove(abs: string) {
  const root = await ensureOpfs();
  if (!root) return;
  try {
    const i = abs.lastIndexOf("/");
    const dirPath = i < 0 ? "" : abs.slice(0, i);
    const name = i < 0 ? abs : abs.slice(i + 1);
    const dir = dirPath ? await opfsWalk(root, dirPath) : root;
    await dir.removeEntry(name);
  } catch {
    /* gone */
  }
}

async function opfsList(prefix: string): Promise<string[]> {
  const root = await ensureOpfs();
  if (!root) return [];
  const out: string[] = [];
  async function walk(dir: FileSystemDirectoryHandle, base: string) {
    const anyDir = dir as FileSystemDirectoryHandle & {
      values: () => AsyncIterable<FileSystemHandle>;
    };
    if (typeof anyDir.values !== "function") return;
    for await (const entry of anyDir.values()) {
      const p = base ? `${base}/${entry.name}` : entry.name;
      if (entry.kind === "file") out.push(p);
      else if (entry.kind === "directory") {
        await walk(entry as FileSystemDirectoryHandle, p);
      }
    }
  }
  try {
    const start = prefix ? await opfsWalk(root, prefix) : root;
    await walk(start, prefix.replace(/\/+$/, ""));
  } catch {
    return out;
  }
  return out;
}

async function pickBackend(): Promise<DiskBackend> {
  if (native()) return "native";
  if (await ensureOpfs()) return "opfs";
  if (typeof indexedDB !== "undefined") return "idb";
  return "memory";
}

const IDB_NAME = "colo-disk";
const IDB_STORE = "files";
let idbDb: IDBDatabase | null = null;

function openIdb(): Promise<IDBDatabase> {
  if (idbDb) return Promise.resolve(idbDb);
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(IDB_NAME, 1);
    req.onupgradeneeded = () => {
      if (!req.result.objectStoreNames.contains(IDB_STORE)) req.result.createObjectStore(IDB_STORE);
    };
    req.onsuccess = () => {
      idbDb = req.result;
      resolve(req.result);
    };
    req.onerror = () => reject(req.error);
  });
}

async function idbPut(k: string, v: string) {
  const db = await openIdb();
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(IDB_STORE, "readwrite");
    tx.objectStore(IDB_STORE).put(v, k);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function idbGet(k: string): Promise<string | null> {
  const db = await openIdb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(IDB_STORE, "readonly");
    const g = tx.objectStore(IDB_STORE).get(k);
    g.onsuccess = () => resolve((g.result as string) ?? null);
    g.onerror = () => reject(g.error);
  });
}

async function idbDel(k: string) {
  const db = await openIdb();
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(IDB_STORE, "readwrite");
    tx.objectStore(IDB_STORE).delete(k);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function idbKeys(prefix: string): Promise<string[]> {
  const db = await openIdb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(IDB_STORE, "readonly");
    const req = tx.objectStore(IDB_STORE).getAllKeys();
    req.onsuccess = () => {
      resolve((req.result as IDBValidKey[]).map(String).filter((k) => k.startsWith(prefix)));
    };
    req.onerror = () => reject(req.error);
  });
}

async function writeOne(abs: string, text: string) {
  const n = native();
  if (n) {
    await n.writeText(abs, text);
    return;
  }
  const b = useDisk.getState().backend;
  if (b === "opfs" || b === "memory") {
    const root = await ensureOpfs();
    if (root) {
      await opfsWrite(abs, text);
      return;
    }
  }
  try {
    await idbPut(abs, text);
  } catch {
    mem.set(abs, text);
  }
}

async function readOne(abs: string): Promise<string | null> {
  const n = native();
  if (n) return n.readText(abs);
  const fromOpfs = await opfsRead(abs);
  if (fromOpfs != null) return fromOpfs;
  try {
    const v = await idbGet(abs);
    if (v != null) return v;
  } catch {
    /* */
  }
  return mem.get(abs) ?? null;
}

async function removeOne(abs: string) {
  const n = native();
  if (n) {
    await n.remove(abs);
    return;
  }
  await opfsRemove(abs);
  try {
    await idbDel(abs);
  } catch {
    /* */
  }
  mem.delete(abs);
}

export async function initDisk(): Promise<DiskBackend> {
  const b = await pickBackend();
  useDisk.setState({ backend: b, ok: true, lastError: "" });
  return b;
}

export async function saveProject(projectId: string, files: Record<string, string>): Promise<boolean> {
  try {
    if (!useDisk.getState().backend || useDisk.getState().backend === "memory") await initDisk();
    const prefix = `proj/${projectId}`;
    if (lastProject !== projectId) lastSaved = {};
    lastProject = projectId;
    const nextKeys = new Set(Object.keys(files));
    for (const [path, text] of Object.entries(files)) {
      if (lastSaved[path] === text) continue;
      await writeOne(`${prefix}/${path}`, text);
      lastSaved[path] = text;
    }
    for (const path of Object.keys(lastSaved)) {
      if (nextKeys.has(path)) continue;
      await removeOne(`${prefix}/${path}`);
      delete lastSaved[path];
    }
    useDisk.setState({ ok: true, lastError: "" });
    return true;
  } catch (e) {
    const msg = e instanceof Error ? e.message : "disco falhou";
    useDisk.setState({ ok: false, lastError: msg });
    return false;
  }
}

export async function loadProject(projectId: string): Promise<Record<string, string>> {
  try {
    if (useDisk.getState().backend === "memory") await initDisk();
    const prefix = `proj/${projectId}`;
    const n = native();
    const files: Record<string, string> = {};
    if (n) {
      const names = await n.list(prefix);
      for (const abs of names) {
        const rel = abs.startsWith(prefix + "/") ? abs.slice(prefix.length + 1) : abs;
        const txt = await n.readText(abs);
        if (txt != null) files[rel] = txt;
      }
      lastSaved = { ...files };
      lastProject = projectId;
      return files;
    }
    const listed = await opfsList(prefix);
    if (listed.length) {
      for (const abs of listed) {
        const rel = abs.startsWith(prefix + "/") ? abs.slice(prefix.length + 1) : abs;
        const txt = await opfsRead(abs);
        if (txt != null) files[rel] = txt;
      }
      lastSaved = { ...files };
      lastProject = projectId;
      if (Object.keys(files).length) return files;
    }
    const keys = await idbKeys(prefix + "/");
    for (const abs of keys) {
      const rel = abs.slice(prefix.length + 1);
      const txt = await idbGet(abs);
      if (txt != null) files[rel] = txt;
    }
    lastSaved = { ...files };
    lastProject = projectId;
    useDisk.setState({ ok: true, lastError: "" });
    return files;
  } catch (e) {
    useDisk.setState({ ok: false, lastError: e instanceof Error ? e.message : "leitura falhou" });
    return {};
  }
}

export function diskLabel(b: DiskBackend) {
  if (b === "native") return "arquivos nativos (Swift)";
  if (b === "opfs") return "disco privado do app (OPFS)";
  if (b === "idb") return "IndexedDB (fallback)";
  return "memória (não persiste)";
}
