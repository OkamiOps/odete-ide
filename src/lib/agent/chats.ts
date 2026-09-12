import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import type { ChatItem } from "./loop";
import type { AgentMessage } from "./server";

type Thread = {
  items: ChatItem[];
  messages: AgentMessage[];
};

type ChatState = {
  threads: Record<string, Thread>;
  save: (projectId: string, items: ChatItem[], messages: AgentMessage[]) => void;
  load: (projectId: string) => Thread;
  clear: (projectId: string) => void;
};

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
      save: (projectId, items, messages) => {
        if (!projectId) return;
        set((s) => ({
          threads: {
            ...s.threads,
            [projectId]: {
              items: slimItems(items),
              messages: messages.slice(-40),
            },
          },
        }));
      },
      load: (projectId) => get().threads[projectId] ?? { items: [], messages: [] },
      clear: (projectId) =>
        set((s) => {
          const threads = { ...s.threads };
          delete threads[projectId];
          return { threads };
        }),
    }),
    {
      name: "colo-chats-v1",
      storage: createJSONStorage(() => localStorage),
      partialize: (s) => ({ threads: s.threads }),
    },
  ),
);
