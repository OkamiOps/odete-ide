import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import { uid } from "@/lib/utils";
import { idbKv } from "@/lib/workspace/idb";
import type { ChatItem } from "./loop";
import type { AgentMessage } from "./server";
import { addUse, emptyUse, type TokenUse } from "./stream-types";

export type ChatThread = {
  id: string;
  projectId: string;
  title: string;
  updated: number;
  items: ChatItem[];
  messages: AgentMessage[];
  usage: TokenUse;
  lastInput: number;
};

type ChatState = {
  threads: Record<string, ChatThread>;
  active: Record<string, string>;
  load: (projectId: string, slot?: "a" | "b") => ChatThread;
  save: (projectId: string, items: ChatItem[], messages: AgentMessage[], slot?: "a" | "b") => void;
  list: (projectId: string) => ChatThread[];
  newChat: (projectId: string, slot?: "a" | "b") => ChatThread;
  open: (projectId: string, threadId: string, slot?: "a" | "b") => ChatThread | null;
  remove: (projectId: string, threadId: string) => ChatThread;
  addUsage: (projectId: string, use: TokenUse, slot?: "a" | "b") => void;
};

function titleOf(items: ChatItem[]) {
  const u = items.find((i) => i.kind === "user");
  if (u && u.kind === "user" && u.text.trim()) {
    const t = u.text.replace(/\s+/g, " ").trim();
    return t.length > 48 ? `${t.slice(0, 48)}…` : t;
  }
  return "Nova conversa";
}

function keyOf(projectId: string, slot: "a" | "b" = "a") {
  return slot === "b" ? `${projectId}#b` : projectId;
}

function blank(projectId: string): ChatThread {
  return {
    id: uid(),
    projectId,
    title: "Nova conversa",
    updated: Date.now(),
    items: [],
    messages: [],
    usage: emptyUse(),
    lastInput: 0,
  };
}

function slimItems(items: ChatItem[]): ChatItem[] {
  return items.slice(-80).map((it) => {
    if (it.kind === "user") {
      const imgs = it.images?.slice(0, 2).filter((s) => s.length < 180_000);
      return { ...it, images: imgs?.length ? imgs : undefined };
    }
    if (it.kind === "think") return { ...it, text: it.text.slice(-8000), live: false };
    if (it.kind === "assistant") return { ...it, text: it.text.slice(0, 20000) };
    if (it.kind === "patch") {
      return { ...it, before: it.before.slice(0, 4000), after: it.after.slice(0, 4000) };
    }
    return it;
  });
}

function safeStorage() {
  return {
    getItem: (name: string) => {
      try {
        return localStorage.getItem(name);
      } catch {
        return null;
      }
    },
    setItem: (name: string, value: string) => {
      try {
        localStorage.setItem(name, value);
      } catch {
        /* quota */
      }
    },
    removeItem: (name: string) => {
      try {
        localStorage.removeItem(name);
      } catch {
        /* ignore */
      }
    },
  };
}

export const useAgentChats = create<ChatState>()(
  persist(
    (set, get) => ({
      threads: {},
      active: {},
      load: (projectId, slot = "a") => {
        if (!projectId) return blank("");
        const s = get();
        const k = keyOf(projectId, slot);
        const aid = s.active[k];
        if (aid && s.threads[aid]) return s.threads[aid]!;
        const t = blank(projectId);
        set({
          threads: { ...s.threads, [t.id]: t },
          active: { ...s.active, [k]: t.id },
        });
        return t;
      },
      save: (projectId, items, messages, slot = "a") => {
        if (!projectId) return;
        set((s) => {
          const id = s.active[keyOf(projectId, slot)];
          if (!id || !s.threads[id]) return s;
          const prev = s.threads[id]!;
          return {
            threads: {
              ...s.threads,
              [id]: {
                ...prev,
                items: slimItems(items),
                messages: messages.slice(-40),
                title: prev.title === "Nova conversa" ? titleOf(items) : prev.title,
                updated: Date.now(),
              },
            },
          };
        });
      },
      list: (projectId) =>
        Object.values(get().threads)
          .filter((t) => t.projectId === projectId && (t.items.length || t.messages.length || t.id === get().active[projectId]))
          .sort((a, b) => b.updated - a.updated),
      newChat: (projectId, slot = "a") => {
        const cur = get().load(projectId, slot);
        if (!cur.items.length && !cur.messages.length) return cur;
        const t = blank(projectId);
        const k = keyOf(projectId, slot);
        set((s) => ({
          threads: { ...s.threads, [t.id]: t },
          active: { ...s.active, [k]: t.id },
        }));
        return t;
      },
      open: (projectId, threadId, slot = "a") => {
        const t = get().threads[threadId];
        if (!t || t.projectId !== projectId) return null;
        set((s) => ({ active: { ...s.active, [keyOf(projectId, slot)]: threadId } }));
        return t;
      },
      addUsage: (projectId, use, slot = "a") => {
        if (!projectId) return;
        set((s) => {
          const id = s.active[keyOf(projectId, slot)];
          if (!id || !s.threads[id]) return s;
          const prev = s.threads[id]!;
          return {
            threads: {
              ...s.threads,
              [id]: {
                ...prev,
                usage: addUse(prev.usage ?? emptyUse(), use),
                lastInput: use.input || prev.lastInput,
                updated: Date.now(),
              },
            },
          };
        });
      },
      remove: (projectId, threadId) => {
        const s = get();
        const threads = { ...s.threads };
        delete threads[threadId];
        const active = { ...s.active };
        for (const k of Object.keys(active)) {
          if (active[k] !== threadId) continue;
          const next = Object.values(threads)
            .filter((t) => t.projectId === projectId)
            .sort((a, b) => b.updated - a.updated)[0];
          if (next) active[k] = next.id;
          else {
            const t = blank(projectId);
            threads[t.id] = t;
            active[k] = t.id;
          }
        }
        set({ threads, active });
        const aid = active[keyOf(projectId, "a")] ?? active[projectId];
        return threads[aid ?? ""] ?? blank(projectId);
      },
    }),
    {
      name: "colo-chats-v2",
      version: 2,
      storage: createJSONStorage(() => idbKv),
      partialize: (s) => ({ threads: s.threads, active: s.active }),
      migrate: (persisted, version) => {
        const p = persisted as { threads?: Record<string, unknown>; active?: Record<string, string> };
        if (version >= 2) return p as ChatState;
        const threads: Record<string, ChatThread> = {};
        const active: Record<string, string> = {};
        for (const [pid, raw] of Object.entries(p.threads ?? {})) {
          const rec = raw as { items?: ChatItem[]; messages?: AgentMessage[] };
          if (!rec || !Array.isArray(rec.items)) continue;
          const id = uid();
          threads[id] = {
            id,
            projectId: pid,
            title: titleOf(rec.items),
            updated: Date.now(),
            items: rec.items,
            messages: rec.messages ?? [],
            usage: emptyUse(),
            lastInput: 0,
          };
          active[pid] = id;
        }
        return { threads, active } as ChatState;
      },
    },
  ),
);

const ctxCache = new Map<string, number>();

export function rememberCtx(provider: string, model: string, ctx?: number) {
  if (ctx && ctx > 1000) ctxCache.set(`${provider}:${model}`, ctx);
}

export function contextWindow(provider: string, model: string) {
  return ctxCache.get(`${provider}:${model}`) ?? 128_000;
}

export function estimateTokens(opts: {
  messages: AgentMessage[];
  draft: string;
  images: number;
}) {
  let n = 0;
  for (const m of opts.messages) {
    n += Math.ceil((m.content ?? "").length / 4);
    for (const c of m.tool_calls ?? []) {
      n += Math.ceil((c.function.arguments || "").length / 4);
    }
  }
  n += Math.ceil(opts.draft.length / 4);
  n += opts.images * 720;
  return n;
}

export function fmtTok(n: number) {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(n % 1_000_000 ? 1 : 0)}M`;
  if (n >= 10_000) return `${Math.round(n / 1000)}k`;
  if (n >= 1000) return `${(n / 1000).toFixed(1).replace(/\.0$/, "")}k`;
  return String(n);
}