import { executeTool } from "./execute";
import { agentTurn, type AgentImage, type AgentMessage } from "./server";
import type { StreamEvt } from "./stream-types";
import { emptyUse, fillUse, type TokenUse } from "./stream-types";
import type { AgentId } from "./providers";
import type { AgentMode } from "./tools";
import { useWorkspace } from "@/lib/workspace/store";
import { usePatches } from "./patches";
import { allSkills, formatSkillsPrompt } from "@/lib/workspace/skills";
import { formatWorkspace } from "./tools";
import { projectRules } from "./rules";
import { abortSignal, isAborted, startAbort } from "./abort";
import { needsPermit, waitPermit, type PermitMode } from "./permit";

const MAX_ROUNDS = 8;

export type ChatItem =
  | { id: string; kind: "user"; text: string; images?: string[] }
  | { id: string; kind: "assistant"; text: string }
  | { id: string; kind: "think"; text: string; live?: boolean }
  | { id: string; kind: "tool"; name: string; detail: string }
  | { id: string; kind: "permit"; name: string; detail: string; status: "pending" | "ok" | "no" }
  | { id: string; kind: "error"; text: string }
  | { id: string; kind: "patch"; patchId: string; path: string; before: string; after: string };

export type LoopAuth = {
  provider: AgentId;
  model: string;
  access?: string;
  accountId?: string;
  mode?: AgentMode;
  effort?: string;
  permit?: PermitMode;
  slot?: string;
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
    slot?: string;
  },
  onEvt: (e: StreamEvt) => void,
  shouldStop?: () => boolean,
): Promise<AgentTurnLike> {
  const ac = new AbortController();
  const extra = abortSignal(payload.slot ?? "a");
  const onAbort = () => ac.abort();
  extra?.addEventListener("abort", onAbort);
  if (extra?.aborted) ac.abort();
  const stopped = () => shouldStop?.() || ac.signal.aborted || isAborted(payload.slot ?? "a");
  try {
    const res = await fetch("/api/agent", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: ac.signal,
    });
    if (!res.ok || !res.body) {
      if (stopped()) return { ok: false, error: "parado" };
      return agentTurn({ data: payload });
    }
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    let thinking = "";
    let text = "";
    let tool_calls: AgentMessage["tool_calls"];
    let err = "";
    let use = emptyUse();
    while (true) {
      if (stopped()) {
        try {
          await reader.cancel();
        } catch {
          /* */
        }
        break;
      }
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
        } else if (ev.t === "usage") {
          use = fillUse(use, ev.use);
          onEvt(ev);
        } else if (ev.t === "error") {
          err = ev.e;
        }
      }
    }
    if (stopped()) return { ok: false, error: "parado" };
    if (err) return { ok: false, error: err };
    return {
      ok: true,
      message: {
        role: "assistant",
        content: text,
        thinking: thinking || undefined,
        tool_calls,
      },
      use,
    };
  } catch (e) {
    if (ac.signal.aborted || (e instanceof DOMException && e.name === "AbortError") || stopped()) {
      return { ok: false, error: "parado" };
    }
    return agentTurn({ data: payload });
  } finally {
    extra?.removeEventListener("abort", onAbort);
  }
}

type AgentTurnLike =
  | { ok: true; message: AgentMessage; use?: TokenUse }
  | { ok: false; error: string };

export async function runAgentLoop(
  history: AgentMessage[],
  userText: string,
  onItems: (items: ChatItem[]) => void,
  auth: LoopAuth,
  shouldStop?: () => boolean,
  images?: AgentImage[],
  onUsage?: (use: TokenUse) => void,
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
  const permit = auth.permit ?? "auto";
  const slot = auth.slot ?? "a";
  startAbort(slot);
  const stopped = () => shouldStop?.() || isAborted(slot);
  let hitCap = false;

  for (let round = 0; round < MAX_ROUNDS; round++) {
    if (stopped()) break;
    const files = useWorkspace.getState().files;
    const fileList = formatWorkspace(files);
    const skills = [formatSkillsPrompt(allSkills(files), userText), projectRules(files)]
      .filter(Boolean)
      .join("\n\n");
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
        slot,
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
      stopped,
    );
    if (stopped()) break;
    if (!result.ok) {
      push({ id: crypto.randomUUID(), kind: "error", text: result.error });
      break;
    }
    if (result.use && (result.use.input || result.use.output || result.use.cache)) {
      onUsage?.(result.use);
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
      if (stopped()) break;
      const name = call.function.name;
      if (mode === "chat" && (name === "write_file" || name === "str_replace")) {
        const detail = "chat não edita. mude pra Plan ou Build.";
        push({ id: call.id, kind: "tool", name, detail });
        messages.push({ role: "tool", tool_call_id: call.id, content: detail });
        continue;
      }
      let args: Record<string, unknown> = {};
      try {
        args = JSON.parse(call.function.arguments || "{}") as Record<string, unknown>;
      } catch {
        args = {};
      }
      const path = typeof args.path === "string" ? args.path : "";
      const hint =
        path ||
        (typeof args.pattern === "string" ? args.pattern : "") ||
        (typeof args.command === "string" ? args.command : "") ||
        name;
      if (needsPermit(permit, name)) {
        upsert({ id: call.id, kind: "permit", name, detail: hint, status: "pending" });
        const ok = await waitPermit(slot);
        if (stopped() || !ok) {
          upsert({ id: call.id, kind: "permit", name, detail: hint, status: "no" });
          messages.push({
            role: "tool",
            tool_call_id: call.id,
            content: "usuário recusou esta ação",
          });
          continue;
        }
        upsert({ id: call.id, kind: "permit", name, detail: hint, status: "ok" });
      }
      const detail = await executeTool(name, call.function.arguments, mode, slot === "b" ? "b" : "a");
      if (detail.startsWith("PATCH:")) {
        const patchId = detail.slice(6);
        const patch = usePatches.getState().items.find((p) => p.id === patchId);
        if (patch) {
          push({
            id: crypto.randomUUID(),
            kind: "patch",
            patchId: patch.id,
            path: patch.path,
            before: patch.before,
            after: patch.after,
          });
        }
      } else if (!needsPermit(permit, name)) {
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
    if (round === MAX_ROUNDS - 1) hitCap = true;
  }

  if (hitCap && !stopped()) {
    push({
      id: crypto.randomUUID(),
      kind: "error",
      text: `parei em ${MAX_ROUNDS} rodadas de ferramenta — manda de novo pra continuar`,
    });
  }

  return messages;
}