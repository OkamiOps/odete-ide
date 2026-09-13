import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import { uid } from "@/lib/utils";
import type { ChatItem } from "./loop";
import type { AgentMessage } from "./server";

export type ChatThread = {
  id: string;
  projectId: string;
  title: string;
  updated: number;
  items: ChatItem[];
  messages: AgentMessage[];
};

type ChatState = {
  threads: Record<string, ChatThread>;
  active: Record<string, string>;
  load: (projectId: string) => ChatThread;
  save: (projectId: string, items: ChatItem[], messages: AgentMessage[]) => void;
  list: (projectId: string) => ChatThread[];
  newChat: (projectId: string) => ChatThread;
  open: (projectId: string, threadId: string) => ChatThread | null;
  remove: (projectId: string, threadId: string) => ChatThread;
};

function titleOf(items: ChatItem[]) {
  const u = items.find((i) => i.kind === "user");
  if (u && u.kind === "user" && u.text.trim()) {
    const t = u.text.replace(/\s+/g, " ").trim();
    return t.length > 48 ? `${t.slice(0, 48)}…` : t;
  }
  return "Nova conversa";
}

function blank(projectId: string): ChatThread {
  return {
    id: uid(),
    projectId,
    title: "Nova conversa",
    updated: Date.now(),
    items: [],
    messages: [],
  };
}

function slimItems(items: ChatItem[]): ChatItem[] {
  return items.slice(-60).map((it) => {
    if (it.kind === "patch") {
      return {
        ...it,
        before: it.before.slice(0, 4000),
        after: it.after.slice(0, 4000),
      };
    }
    return it;
  });
}

export const useAgentChats = create<ChatState>()(
  persist(
    (set, get) => ({
      threads: {},
      active: {},
      load: (projectId) => {
        if (!projectId) return blank("");
        const s = get();
        const aid = s.active[projectId];
        if (aid && s.threads[aid]) return s.threads[aid]!;
        const t = blank(projectId);
        set({
          threads: { ...s.threads, [t.id]: t },
          active: { ...s.active, [projectId]: t.id },
        });
        return t;
      },
      save: (projectId, items, messages) => {
        if (!projectId) return;
        set((s) => {
          const id = s.active[projectId];
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
          .filter((t) => t.projectId === projectId)
          .sort((a, b) => b.updated - a.updated),
      newChat: (projectId) => {
        const cur = get().load(projectId);
        if (!cur.items.length && !cur.messages.length) return cur;
        const t = blank(projectId);
        set((s) => ({
          threads: { ...s.threads, [t.id]: t },
          active: { ...s.active, [projectId]: t.id },
        }));
        return t;
      },
      open: (projectId, threadId) => {
        const t = get().threads[threadId];
        if (!t || t.projectId !== projectId) return null;
        set((s) => ({ active: { ...s.active, [projectId]: threadId } }));
        return t;
      },
      remove: (projectId, threadId) => {
        const s = get();
        const threads = { ...s.threads };
        delete threads[threadId];
        let activeId = s.active[projectId];
        if (activeId === threadId) {
          const next = Object.values(threads)
            .filter((t) => t.projectId === projectId)
            .sort((a, b) => b.updated - a.updated)[0];
          if (next) activeId = next.id;
          else {
            const t = blank(projectId);
            threads[t.id] = t;
            activeId = t.id;
          }
        }
        set({ threads, active: { ...s.active, [projectId]: activeId } });
        return threads[activeId] ?? blank(projectId);
      },
    }),
    {
      name: "colo-chats-v2",
      version: 2,
      storage: createJSONStorage(() => localStorage),
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
          };
          active[pid] = id;
        }
        return { threads, active } as ChatState;
      },
    },
  ),
);

export function contextWindow(provider: string, model: string) {
  if (provider === "claude") return 200_000;
  if (/grok-4/.test(model)) return 256_000;
  return 128_000;
}

export function estimateTokens(opts: {
  messages: AgentMessage[];
  files: Record<string, string>;
  draft: string;
  images: number;
}) {
  let n = 1800;
  n += Math.ceil(Object.keys(opts.files).join("\n").length / 4);
  for (const m of opts.messages) {
    n += Math.ceil((m.content ?? "").length / 4);
    for (const c of m.tool_calls ?? []) {
      n += Math.ceil((c.function.arguments || "").length / 4) + 24;
    }
  }
  n += Math.ceil(opts.draft.length / 4);
  n += opts.images * 720;
  return n;
}

export function fmtTok(n: number) {
  if (n >= 10_000) return `${Math.round(n / 1000)}k`;
  if (n >= 1000) return `${(n / 1000).toFixed(1).replace(/\.0$/, "")}k`;
  return String(n);
}