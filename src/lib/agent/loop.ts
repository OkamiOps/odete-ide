import { executeTool } from "./execute";
import { agentTurn, type AgentImage, type AgentMessage } from "./server";
import type { StreamEvt } from "./stream-types";
import type { AgentId } from "./providers";
import type { AgentMode } from "./tools";
import { useWorkspace } from "@/lib/workspace/store";
import { usePatches } from "./patches";
import { allSkills, formatSkillsPrompt } from "@/lib/workspace/skills";

const MAX_ROUNDS = 8;

export type ChatItem =
  | { id: string; kind: "user"; text: string; images?: string[] }
  | { id: string; kind: "assistant"; text: string }
  | { id: string; kind: "think"; text: string; live?: boolean }
  | { id: string; kind: "tool"; name: string; detail: string }
  | { id: string; kind: "error"; text: string }
  | { id: string; kind: "patch"; patchId: string; path: string; before: string; after: string };

export type LoopAuth = {
  provider: AgentId;
  model: string;
  access?: string;
  accountId?: string;
  mode?: AgentMode;
  effort?: string;
};

async function streamTurn(
  payload: {
    messages: AgentMessage[];
    fileList: string;
    skills: string;
    provider: AgentId;
    model: string;
    access?: string;
    accountId?: string;
    mode?: AgentMode;
    effort?: string;
  },
  onEvt: (e: StreamEvt) => void,
  shouldStop?: () => boolean,
): Promise<AgentTurnLike> {
  try {
    const res = await fetch("/api/agent", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    if (!res.ok || !res.body) {
      return agentTurn({ data: payload });
    }
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    let thinking = "";
    let text = "";
    let tool_calls: AgentMessage["tool_calls"];
    let err = "";
    while (true) {
      if (shouldStop?.()) break;
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const parts = buf.split("\n\n");
      buf = parts.pop() ?? "";
      for (const part of parts) {
        const line = part.replace(/^data:\s*/, "").trim();
        if (!line) continue;
        let ev: StreamEvt;
        try {
          ev = JSON.parse(line) as StreamEvt;
        } catch {
          continue;
        }
        if (ev.t === "think") {
          thinking += ev.c;
          onEvt(ev);
        } else if (ev.t === "text") {
          text += ev.c;
          onEvt(ev);
        } else if (ev.t === "tools") {
          tool_calls = ev.calls;
          onEvt(ev);
        } else if (ev.t === "error") {
          err = ev.e;
        }
      }
    }
    if (err) return { ok: false, error: err };
    return {
      ok: true,
      message: {
        role: "assistant",
        content: text,
        thinking: thinking || undefined,
        tool_calls,
      },
    };
  } catch {
    return agentTurn({ data: payload });
  }
}

type AgentTurnLike =
  | { ok: true; message: AgentMessage }
  | { ok: false; error: string };

export async function runAgentLoop(
  history: AgentMessage[],
  userText: string,
  onItems: (items: ChatItem[]) => void,
  auth: LoopAuth,
  shouldStop?: () => boolean,
  images?: AgentImage[],
): Promise<AgentMessage[]> {
  const extra: ChatItem[] = [];
  const upsert = (item: ChatItem) => {
    const i = extra.findIndex((x) => x.id === item.id);
    if (i >= 0) extra[i] = item;
    else extra.push(item);
    onItems([...extra]);
  };
  const push = (item: ChatItem) => {
    extra.push(item);
    onItems([...extra]);
  };

  const userMsg: AgentMessage = { role: "user", content: userText, images: images?.length ? images : undefined };
  const messages: AgentMessage[] = [...history, userMsg];
  const mode = auth.mode ?? "build";

  for (let round = 0; round < MAX_ROUNDS; round++) {
    if (shouldStop?.()) break;
    const fileList = Object.keys(useWorkspace.getState().files).sort().join("\n");
    const files = useWorkspace.getState().files;
    const skills = formatSkillsPrompt(allSkills(files), userText);
    const thinkId = crypto.randomUUID();
    const textId = crypto.randomUUID();
    let thinkText = "";
    let answer = "";

    const result = await streamTurn(
      {
        messages,
        fileList,
        skills,
        provider: auth.provider,
        model: auth.model,
        access: auth.access,
        accountId: auth.accountId,
        mode,
        effort: auth.effort,
      },
      (ev) => {
        if (ev.t === "think") {
          thinkText += ev.c;
          upsert({ id: thinkId, kind: "think", text: thinkText, live: true });
        }
        if (ev.t === "text") {
          if (thinkText) upsert({ id: thinkId, kind: "think", text: thinkText, live: false });
          answer += ev.c;
          upsert({ id: textId, kind: "assistant", text: answer });
        }
      },
      shouldStop,
    );
    if (shouldStop?.()) break;
    if (!result.ok) {
      push({ id: crypto.randomUUID(), kind: "error", text: result.error });
      break;
    }
    const msg = result.message;
    if (thinkText) upsert({ id: thinkId, kind: "think", text: msg.thinking || thinkText, live: false });
    else if ((msg.thinking ?? "").trim()) {
      upsert({ id: thinkId, kind: "think", text: msg.thinking!.trim(), live: false });
    }

    messages.push({
      role: "assistant",
      content: msg.content,
      tool_calls: msg.tool_calls,
    });

    const calls = msg.tool_calls ?? [];
    if (calls.length === 0) {
      const text = (msg.content ?? "").trim() || answer;
      if (text) upsert({ id: textId, kind: "assistant", text });
      break;
    }

    for (const call of calls) {
      if (shouldStop?.()) break;
      const name = call.function.name;
      if (mode !== "build" && (name === "write_file" || name === "str_replace" || name === "run_shell")) {
        const detail = "bloqueado neste modo";
        push({ id: call.id, kind: "tool", name, detail });
        messages.push({ role: "tool", tool_call_id: call.id, content: detail });
        continue;
      }
      const detail = executeTool(name, call.function.arguments);
      if (detail.startsWith("PATCH:")) {
        const patchId = detail.slice(6);
        const patch = usePatches.getState().items.find((p) => p.id === patchId);
        if (patch) {
          push({
            id: call.id,
            kind: "patch",
            patchId: patch.id,
            path: patch.path,
            before: patch.before,
            after: patch.after,
          });
        } else {
          push({ id: call.id, kind: "tool", name, detail: "patch" });
        }
      } else {
        let args: Record<string, unknown> = {};
        try {
          args = JSON.parse(call.function.arguments || "{}") as Record<string, unknown>;
        } catch {
          args = {};
        }
        const path = typeof args.path === "string" ? args.path : "";
        const hint = path || (typeof args.pattern === "string" ? args.pattern : "") || (typeof args.command === "string" ? args.command : "");
        push({
          id: call.id,
          kind: "tool",
          name,
          detail: hint || (detail.split("\n")[0] ?? ""),
        });
      }
      messages.push({
        role: "tool",
        tool_call_id: call.id,
        content: detail,
      });
    }
  }

  return messages;
}