import { SYSTEM_PROMPT, modePrompt, toolsForMode, type AgentMode, type AgentTool } from "./tools";
import type { AgentId } from "./providers";
import type { AgentMessage, AgentTurnResult } from "./server";
import type { StreamEvt } from "./stream-types";

export type { StreamEvt };

type TurnBody = {
  messages: AgentMessage[];
  fileList: string;
  provider: AgentId;
  model: string;
  access?: string;
  accountId?: string;
  skills?: string;
  mode?: AgentMode;
  effort?: string;
};

function withSystem(messages: AgentMessage[], fileList: string, skills = "", mode: AgentMode = "build"): AgentMessage[] {
  const trimmed = messages.slice(-24).filter((m) => m.role !== "system");
  return [
    {
      role: "system",
      content: `${SYSTEM_PROMPT}\n\n${modePrompt(mode)}\n\nArquivos no workspace:\n${fileList || "(vazio)"}${skills ? `\n\n${skills}` : ""}`,
    },
    ...trimmed,
  ];
}

function openaiContent(m: AgentMessage) {
  const text = typeof m.content === "string" ? m.content : (m.content ?? "");
  if (!m.images?.length || m.role !== "user") return text;
  return [
    { type: "text", text: text || " " },
    ...m.images.map((img) => ({
      type: "image_url",
      image_url: { url: `data:${img.mime};base64,${img.data}` },
    })),
  ];
}

function sanitizeOpenAI(messages: AgentMessage[]) {
  const out: Record<string, unknown>[] = [];
  for (const m of messages) {
    const role = m.role;
    const content = openaiContent(m);
    if (role === "tool") {
      out.push({ role: "tool", tool_call_id: m.tool_call_id ?? "", content: m.content ?? "" });
      continue;
    }
    if (role === "assistant" && m.tool_calls?.length) {
      out.push({
        role: "assistant",
        content: typeof content === "string" ? content : "",
        tool_calls: m.tool_calls,
      });
      continue;
    }
    if (role === "system" || role === "user" || role === "assistant") {
      out.push({ role, content });
    }
  }
  return out;
}

async function readSse(
  res: Response,
  onLine: (line: string) => void,
) {
  if (!res.body) throw new Error("sem corpo");
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    const parts = buf.split("\n");
    buf = parts.pop() ?? "";
    for (const raw of parts) {
      const line = raw.trim();
      if (!line || line.startsWith(":")) continue;
      if (line.startsWith("data:")) onLine(line.slice(5).trim());
    }
  }
  if (buf.trim().startsWith("data:")) onLine(buf.trim().slice(5).trim());
}

type ToolAcc = { id: string; name: string; args: string };

function emitTools(acc: Map<number, ToolAcc>): AgentMessage["tool_calls"] {
  const calls = [...acc.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([, v]) => ({
      id: v.id || crypto.randomUUID(),
      type: "function" as const,
      function: { name: v.name, arguments: v.args || "{}" },
    }));
  return calls.length ? calls : undefined;
}

async function streamOpenAI(opts: {
  url: string;
  headers: Record<string, string>;
  model: string;
  messages: AgentMessage[];
  tools: AgentTool[];
  extra?: Record<string, unknown>;
  emit: (e: StreamEvt) => void;
}): Promise<AgentTurnResult> {
  const payload: Record<string, unknown> = {
    model: opts.model,
    messages: sanitizeOpenAI(opts.messages),
    temperature: 0.3,
    stream: true,
    ...opts.extra,
  };
  if (opts.tools.length) {
    payload.tools = opts.tools;
    payload.tool_choice = "auto";
  }
  const res = await fetch(opts.url, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...opts.headers },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const t = await res.text().catch(() => "");
    const host = new URL(opts.url).host;
    return { ok: false, error: `${host} ${res.status}${t ? `: ${t.slice(0, 240)}` : ""}` };
  }
  const acc = new Map<number, ToolAcc>();
  let thinking = "";
  let text = "";
  await readSse(res, (line) => {
    if (!line || line === "[DONE]") return;
    let json: Record<string, unknown>;
    try {
      json = JSON.parse(line) as Record<string, unknown>;
    } catch {
      return;
    }
    const choices = json.choices as Array<{ delta?: Record<string, unknown> }> | undefined;
    const delta = choices?.[0]?.delta;
    if (!delta) return;
    const rc = delta.reasoning_content;
    if (typeof rc === "string" && rc) {
      thinking += rc;
      opts.emit({ t: "think", c: rc });
    }
    const content = delta.content;
    if (typeof content === "string" && content) {
      text += content;
      opts.emit({ t: "text", c: content });
    }
    const tcs = delta.tool_calls as Array<{
      index?: number;
      id?: string;
      function?: { name?: string; arguments?: string };
    }> | undefined;
    if (tcs) {
      for (const tc of tcs) {
        const i = tc.index ?? 0;
        const cur = acc.get(i) ?? { id: "", name: "", args: "" };
        if (tc.id) cur.id = tc.id;
        if (tc.function?.name) cur.name += tc.function.name;
        if (tc.function?.arguments) cur.args += tc.function.arguments;
        acc.set(i, cur);
      }
    }
  });
  const tool_calls = emitTools(acc);
  if (tool_calls) opts.emit({ t: "tools", calls: tool_calls });
  return {
    ok: true,
    message: {
      role: "assistant",
      content: text,
      thinking: thinking || undefined,
      tool_calls,
    },
  };
}

async function streamClaude(
  access: string,
  model: string,
  messages: AgentMessage[],
  tools: AgentTool[],
  effort: string,
  emit: (e: StreamEvt) => void,
): Promise<AgentTurnResult> {
  const system = messages.find((m) => m.role === "system")?.content ?? SYSTEM_PROMPT;
  const bodyJson: Record<string, unknown> = {
    model,
    max_tokens: effort ? 8000 : 1600,
    stream: true,
    system,
    messages: toAnth(messages),
  };
  if (effort) {
    bodyJson.thinking = { type: "enabled", budget_tokens: 4000 };
  } else {
    bodyJson.temperature = 0.3;
  }
  if (tools.length) {
    bodyJson.tools = tools.map((t) => ({
      name: t.function.name,
      description: t.function.description,
      input_schema: t.function.parameters,
    }));
  }
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${access}`,
      "anthropic-version": "2023-06-01",
      "anthropic-beta": "oauth-2025-04-20,claude-code-20250219",
    },
    body: JSON.stringify(bodyJson),
  });
  if (!res.ok) {
    const t = await res.text().catch(() => "");
    return { ok: false, error: `anthropic ${res.status}${t ? `: ${t.slice(0, 240)}` : ""}` };
  }
  let thinking = "";
  let text = "";
  const acc = new Map<number, ToolAcc>();
  let blockType = "";
  let blockIndex = -1;
  await readSse(res, (line) => {
    if (!line) return;
    let json: Record<string, unknown>;
    try {
      json = JSON.parse(line) as Record<string, unknown>;
    } catch {
      return;
    }
    const type = String(json.type || "");
    if (type === "content_block_start") {
      const block = json.content_block as { type?: string; id?: string; name?: string } | undefined;
      blockType = block?.type ?? "";
      blockIndex += 1;
      if (blockType === "tool_use") {
        acc.set(blockIndex, { id: block?.id ?? "", name: block?.name ?? "", args: "" });
      }
    }
    if (type === "content_block_delta") {
      const delta = json.delta as { type?: string; thinking?: string; text?: string; partial_json?: string } | undefined;
      if (!delta) return;
      if (delta.type === "thinking_delta" && delta.thinking) {
        thinking += delta.thinking;
        emit({ t: "think", c: delta.thinking });
      }
      if (delta.type === "text_delta" && delta.text) {
        text += delta.text;
        emit({ t: "text", c: delta.text });
      }
      if (delta.type === "input_json_delta" && delta.partial_json) {
        const cur = acc.get(blockIndex);
        if (cur) {
          cur.args += delta.partial_json;
          acc.set(blockIndex, cur);
        }
      }
    }
  });
  const tool_calls = emitTools(acc);
  if (tool_calls) emit({ t: "tools", calls: tool_calls });
  return {
    ok: true,
    message: {
      role: "assistant",
      content: text,
      thinking: thinking || undefined,
      tool_calls,
    },
  };
}

type AnthBlock =
  | { type: "text"; text: string }
  | { type: "image"; source: { type: "base64"; media_type: string; data: string } }
  | { type: "tool_use"; id: string; name: string; input: unknown }
  | { type: "tool_result"; tool_use_id: string; content: string };

function toAnth(messages: AgentMessage[]) {
  const out: { role: "user" | "assistant"; content: string | AnthBlock[] }[] = [];
  for (const m of messages) {
    if (m.role === "system") continue;
    if (m.role === "user") {
      if (m.images?.length) {
        const content: AnthBlock[] = m.images.map((img) => ({
          type: "image",
          source: { type: "base64", media_type: img.mime, data: img.data },
        }));
        content.push({ type: "text", text: m.content || " " });
        out.push({ role: "user", content });
      } else {
        out.push({ role: "user", content: m.content ?? "" });
      }
      continue;
    }
    if (m.role === "assistant") {
      if (m.tool_calls?.length) {
        const content: AnthBlock[] = [];
        if (m.content) content.push({ type: "text", text: m.content });
        for (const c of m.tool_calls) {
          let input: unknown = {};
          try {
            input = JSON.parse(c.function.arguments || "{}");
          } catch {
            input = {};
          }
          content.push({ type: "tool_use", id: c.id, name: c.function.name, input });
        }
        out.push({ role: "assistant", content });
      } else {
        out.push({ role: "assistant", content: m.content ?? "" });
      }
      continue;
    }
    if (m.role === "tool") {
      const block: AnthBlock = {
        type: "tool_result",
        tool_use_id: m.tool_call_id ?? "",
        content: m.content ?? "",
      };
      const last = out[out.length - 1];
      if (last && last.role === "user" && Array.isArray(last.content)) {
        last.content.push(block);
      } else {
        out.push({ role: "user", content: [block] });
      }
    }
  }
  return out;
}

export async function streamProviderTurn(data: TurnBody, emit: (e: StreamEvt) => void): Promise<AgentTurnResult> {
  const mode: AgentMode = data.mode === "chat" || data.mode === "plan" ? data.mode : "build";
  const tools = toolsForMode(mode);
  const messages = withSystem(data.messages ?? [], data.fileList, data.skills, mode);
  const model = (data.model || "").trim();
  const effort = (data.effort || "").trim();

  if (data.provider === "grok") {
    const apiKey = process.env.XAI_API_KEY;
    if (!apiKey) return { ok: false, error: "Grok indisponível neste ambiente." };
    return streamOpenAI({
      url: "https://api.x.ai/v1/chat/completions",
      headers: { Authorization: `Bearer ${apiKey}` },
      model: model || "grok-4.5",
      messages,
      tools,
      extra: {
        max_tokens: 1600,
        ...(effort ? { reasoning_effort: effort } : {}),
      },
      emit,
    });
  }

  const access = (data.access || "").trim();
  if (!access) {
    return {
      ok: false,
      error:
        data.provider === "claude"
          ? "Entre com a sua conta Claude em Ajustes (OAuth)."
          : "Conecte o ChatGPT em Ajustes (device code).",
    };
  }

  if (data.provider === "claude") {
    if (!model) return { ok: false, error: "escolha um modelo Claude na lista da API." };
    return streamClaude(access, model, messages, tools, effort, emit);
  }

  if (!model) return { ok: false, error: "escolha um modelo ChatGPT na lista da API." };
  const headers: Record<string, string> = {
    Authorization: `Bearer ${access}`,
    originator: "codex_cli_rs",
  };
  if (data.accountId) headers["ChatGPT-Account-ID"] = data.accountId;
  return streamOpenAI({
    url: "https://chatgpt.com/backend-api/codex/v1/chat/completions",
    headers,
    model,
    messages,
    tools,
    extra: {
      max_completion_tokens: 1600,
      ...(effort ? { reasoning_effort: effort } : {}),
    },
    emit,
  });
}