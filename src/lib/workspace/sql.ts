import { create } from "zustand";
import { idbKv } from "./idb";

export type SqlBackend = "native" | "pglite" | "memory";

type NativeSql = {
  sql: (q: string, params?: unknown[]) => Promise<{ rows: Record<string, unknown>[] }>;
};

type Host = typeof globalThis & { coloNative?: NativeSql };

export const useSql = create<{ backend: SqlBackend; ok: boolean; lastError: string }>(() => ({
  backend: "memory",
  ok: true,
  lastError: "",
}));

let mem = new Map<string, string>();
let pg: { query: (q: string, p?: unknown[]) => Promise<{ rows: Record<string, unknown>[] }>; exec: (q: string) => Promise<unknown> } | null = null;
let ready: Promise<SqlBackend> | null = null;

function native(): NativeSql | null {
  const n = (globalThis as Host).coloNative;
  return n?.sql ? n : null;
}

function toPg(sql: string) {
  let i = 0;
  return sql.replace(/\?/g, () => `$${++i}`);
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS git_commits (
  project_id TEXT NOT NULL,
  id TEXT NOT NULL,
  sha TEXT,
  message TEXT NOT NULL,
  at BIGINT NOT NULL,
  files TEXT,
  PRIMARY KEY (project_id, id)
);
`;

async function bootPglite() {
  const { PGlite } = await import("@electric-sql/pglite");
  const db = new PGlite("idb://colo-sql");
  await db.waitReady;
  await db.exec(SCHEMA);
  pg = db as typeof pg;
}

async function bootNative() {
  const n = native();
  if (!n) return;
  for (const stmt of SCHEMA.split(";").map((s) => s.trim()).filter(Boolean)) {
    await n.sql(stmt, []);
  }
}

export async function initSql(): Promise<SqlBackend> {
  if (ready) return ready;
  ready = (async () => {
    try {
      if (native()) {
        await bootNative();
        useSql.setState({ backend: "native", ok: true, lastError: "" });
        return "native" as const;
      }
      await bootPglite();
      useSql.setState({ backend: "pglite", ok: true, lastError: "" });
      return "pglite" as const;
    } catch (e) {
      useSql.setState({
        backend: "memory",
        ok: true,
        lastError: e instanceof Error ? e.message : "sql wasm falhou — usando índice local",
      });
      return "memory" as const;
    }
  })();
  return ready;
}

export async function sqlQuery(sql: string, params: unknown[] = []): Promise<Record<string, unknown>[]> {
  await initSql();
  const n = native();
  if (n) {
    const r = await n.sql(sql, params);
    return r.rows ?? [];
  }
  if (pg) {
    const r = await pg.query(toPg(sql), params);
    return r.rows ?? [];
  }
  return memQuery(sql, params);
}

export async function sqlExec(sql: string, params: unknown[] = []): Promise<void> {
  await sqlQuery(sql, params);
}

export async function kvGet(key: string): Promise<string | null> {
  const rows = await sqlQuery("SELECT v FROM kv WHERE k = ?", [key]);
  const v = rows[0]?.v;
  return typeof v === "string" ? v : v == null ? null : String(v);
}

export async function kvSet(key: string, value: string): Promise<void> {
  await initSql();
  const n = native();
  if (n || pg) {
    await sqlQuery("INSERT INTO kv(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", [key, value]);
    return;
  }
  mem.set(key, value);
  try {
    await idbKv.setItem(key, value);
  } catch {
    /* quota */
  }
}

export async function kvDel(key: string): Promise<void> {
  await sqlQuery("DELETE FROM kv WHERE k = ?", [key]);
  mem.delete(key);
}

export const sqlKv = {
  getItem: async (name: string) => {
    await initSql();
    const v = await kvGet(name);
    if (v != null) return v;
    try {
      const old = await idbKv.getItem(name);
      if (old != null) {
        await kvSet(name, old);
        return old;
      }
    } catch {
      /* */
    }
    return null;
  },
  setItem: async (name: string, value: string) => {
    await kvSet(name, value);
  },
  removeItem: async (name: string) => {
    await kvDel(name);
  },
};

function memQuery(sql: string, params: unknown[]): Record<string, unknown>[] {
  const s = sql.replace(/\s+/g, " ").trim();
  if (/^CREATE TABLE/i.test(s)) return [];
  if (/^SELECT v FROM kv WHERE k = \?/i.test(s)) {
    const v = mem.get(String(params[0] ?? ""));
    return v == null ? [] : [{ v }];
  }
  if (/^INSERT INTO kv/i.test(s)) {
    mem.set(String(params[0] ?? ""), String(params[1] ?? ""));
    return [];
  }
  if (/^DELETE FROM kv WHERE k = \?/i.test(s)) {
    mem.delete(String(params[0] ?? ""));
    return [];
  }
  return [];
}
