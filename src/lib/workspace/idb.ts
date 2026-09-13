const DB = "colo-idb";
const STORE = "kv";

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
      if (value != null) return value;
    } catch {
      /* fall through */
    }
    try {
      return localStorage.getItem(name);
    } catch {
      return null;
    }
  },
  setItem: async (name: string, value: string) => {
    try {
      const db = await openDb();
      await new Promise<void>((resolve, reject) => {
        const tx = db.transaction(STORE, "readwrite");
        tx.objectStore(STORE).put(value, name);
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error);
      });
    } catch {
      try {
        localStorage.setItem(name, value);
      } catch {
        /* quota */
      }
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
