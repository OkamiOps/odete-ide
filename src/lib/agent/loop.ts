import { executeTool } from "./execute";
import { agentTurn, type AgentImage, type AgentMessage } from "./server";
import type { AgentId } from "./providers";
import type { AgentMode } from "./tools";
import { useWorkspace } from "@/lib/workspace/store";
import { usePatches } from "./patches";
import { allSkills, formatSkillsPrompt } from "@/lib/workspace/skills";

const MAX_ROUNDS = 8;

export type ChatItem =
  | { id: string; kind: "user"; text: string; images?: string[] }
  | { id: string; kind: "assistant"; text: string }
  | { id: string; kind: "think"; text: string }
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

export async function runAgentLoop(
  history: AgentMessage[],
  userText: string,
  onItems: (items: ChatItem[]) => void,
  auth: LoopAuth,
  shouldStop?: () => boolean,
  images?: AgentImage[],
): Promise<AgentMessage[]> {
  const extra: ChatItem[] = [];
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
    const result = await agentTurn({
      data: {
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
    });
    if (shouldStop?.()) break;
    if (!result.ok) {
      push({ id: crypto.randomUUID(), kind: "error", text: result.error });
      break;
    }
    const msg = result.message;
    const thinking = (msg.thinking ?? "").trim();
    if (thinking) push({ id: crypto.randomUUID(), kind: "think", text: thinking });
    messages.push({
      role: "assistant",
      content: msg.content,
      tool_calls: msg.tool_calls,
    });

    const calls = msg.tool_calls ?? [];
    if (calls.length === 0) {
      const text = (msg.content ?? "").trim();
      if (text) push({ id: crypto.randomUUID(), kind: "assistant", text });
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
        push({
          id: call.id,
          kind: "tool",
          name,
          detail: detail.split("\n")[0] ?? "",
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
