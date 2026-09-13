import { create } from "zustand";

const DB = "colo-idb";
const STORE = "kv";

export const usePersistHealth = create<{
  ok: boolean;
  lastError: string;
  freeze: boolean;
}>(() => ({
  ok: true,
  lastError: "",
  freeze: false,
}));

let cached: IDBDatabase | null = null;

function openDb(): Promise<IDBDatabase> {
  if (cached) return Promise.resolve(cached);
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => {
      if (!req.result.objectStoreNames.contains(STORE)) req.result.createObjectStore(STORE);
    };
    req.onsuccess = () => {
      cached = req.result;
      cached.onclose = () => {
        cached = null;
      };
      resolve(cached);
    };
    req.onerror = () => reject(req.error);
  });
}

function markErr(e: unknown) {
  const msg = e instanceof Error ? e.message : "persistência falhou";
  usePersistHealth.setState({ ok: false, lastError: msg });
}

export const idbKv = {
  getItem: async (name: string) => {
    try {
      const db = await openDb();
      const value = await new Promise<string | null>((resolve, reject) => {
        const tx = db.transaction(STORE, "readonly");
        const g = tx.objectStore(STORE).get(name);
        g.onsuccess = () => resolve((g.result as string) ?? null);
        g.onerror = () => reject(g.error);
      });
      if (value != null) {
        usePersistHealth.setState({ ok: true, lastError: "", freeze: false });
        return value;
      }
    } catch (e) {
      markErr(e);
      usePersistHealth.setState({ freeze: name.startsWith("colo-workspace") });
      if (name.startsWith("colo-workspace")) throw e;
    }
    if (name.startsWith("colo-workspace")) return null;
    try {
      return localStorage.getItem(name);
    } catch {
      return null;
    }
  },
  setItem: async (name: string, value: string) => {
    if (usePersistHealth.getState().freeze && name.startsWith("colo-workspace")) {
      return;
    }
    try {
      const db = await openDb();
      await new Promise<void>((resolve, reject) => {
        const tx = db.transaction(STORE, "readwrite");
        tx.objectStore(STORE).put(value, name);
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
      });
      usePersistHealth.setState({ ok: true, lastError: "" });
      return;
    } catch (e) {
      markErr(e);
      if (name.startsWith("colo-workspace")) throw e;
    }
    try {
      localStorage.setItem(name, value);
    } catch (e) {
      markErr(e);
      throw e;
    }
  },
  removeItem: async (name: string) => {
    try {
      const db = await openDb();
      await new Promise<void>((resolve, reject) => {
        const tx = db.transaction(STORE, "readwrite");
        tx.objectStore(STORE).delete(name);
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
      });
    } catch {
      try {
        localStorage.removeItem(name);
      } catch {
        /* ignore */
      }
    }
  },
};
