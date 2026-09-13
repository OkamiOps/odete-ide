import { createServerFn } from "@tanstack/react-start";
import { SYSTEM_PROMPT, modePrompt, toolsForMode, type AgentMode, type AgentTool } from "./tools";
import type { AgentId } from "./providers";

export type AgentImage = { mime: string; data: string };

export type AgentMessage = {
  role: "system" | "user" | "assistant" | "tool";
  content?: string | null;
  thinking?: string;
  images?: AgentImage[];
  tool_calls?: Array<{
    id: string;
    type: "function";
    function: { name: string; arguments: string };
  }>;
  tool_call_id?: string;
};

export type AgentTurnResult =
  | { ok: true; message: AgentMessage }
  | { ok: false; error: string };

type TurnInput = {
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
        tool_calls: m.tool_calls.map((c) => ({
          id: c.id,
          type: "function" as const,
          function: {
            name: c.function.name,
            arguments:
              typeof c.function.arguments === "string"
                ? c.function.arguments
                : JSON.stringify(c.function.arguments ?? {}),
          },
        })),
      });
      continue;
    }
    if (role === "system" || role === "user" || role === "assistant") {
      out.push({ role, content });
    }
  }
  return out;
}

function withSystem(messages: AgentMessage[], fileList: string, skills = "", mode: AgentMode = "build") {
  const trimmed = messages.slice(-24).filter((m) => m.role !== "system");
  return [
    {
      role: "system" as const,
      content: `${SYSTEM_PROMPT}\n\n${modePrompt(mode)}\n\nArquivos no workspace:\n${fileList || "(vazio)"}${skills ? `\n\n${skills}` : ""}`,
    },
    ...trimmed,
  ];
}

function pickText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((p) => {
        if (typeof p === "string") return p;
        if (p && typeof p === "object") {
          const rec = p as { text?: unknown; content?: unknown };
          if (typeof rec.text === "string") return rec.text;
          if (typeof rec.content === "string") return rec.content;
        }
        return "";
      })
      .filter(Boolean)
      .join("\n");
  }
  return "";
}

function pickThinking(raw: Record<string, unknown>): string {
  if (typeof raw.reasoning_content === "string") return raw.reasoning_content.trim();
  if (typeof raw.reasoning === "string") return raw.reasoning.trim();
  const r = raw.reasoning;
  if (r && typeof r === "object" && typeof (r as { content?: unknown }).content === "string") {
    return ((r as { content: string }).content || "").trim();
  }
  return "";
}

async function openaiCompatible(opts: {
  url: string;
  headers: Record<string, string>;
  model: string;
  messages: AgentMessage[];
  tools: AgentTool[];
  extra?: Record<string, unknown>;
}): Promise<AgentTurnResult> {
  const payload: Record<string, unknown> = {
    model: opts.model,
    messages: sanitizeOpenAI(opts.messages),
    temperature: 0.3,
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
  const body = (await res.json()) as { choices?: Array<{ message?: Record<string, unknown> }> };
  const raw = body.choices?.[0]?.message;
  if (!raw) return { ok: false, error: "resposta vazia do modelo" };
  const tool_calls = raw.tool_calls as AgentMessage["tool_calls"];
  return {
    ok: true,
    message: {
      role: "assistant",
      content: pickText(raw.content),
      thinking: pickThinking(raw) || undefined,
      tool_calls,
    },
  };
}

type AnthBlock =
  | { type: "text"; text: string }
  | { type: "thinking"; thinking: string }
  | { type: "tool_use"; id: string; name: string; input: unknown }
  | { type: "tool_result"; tool_use_id: string; content: string }
  | { type: "image"; source: { type: "base64"; media_type: string; data: string } };

function toAnthropicMessages(messages: AgentMessage[]) {
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

async function claudeTurn(
  access: string,
  model: string,
  messages: AgentMessage[],
  tools: AgentTool[],
  effort?: string,
): Promise<AgentTurnResult> {
  const system = messages.find((m) => m.role === "system")?.content ?? SYSTEM_PROMPT;
  const bodyJson: Record<string, unknown> = {
    model,
    max_tokens: 1600,
    temperature: 0.3,
    system,
    messages: toAnthropicMessages(messages),
  };
  if (effort) bodyJson.output_config = { effort };
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
  const body = (await res.json()) as { content?: AnthBlock[] };
  const blocks = body.content ?? [];
  const text = blocks
    .filter((b): b is Extract<AnthBlock, { type: "text" }> => b.type === "text")
    .map((b) => b.text)
    .join("\n")
    .trim();
  const thinking = blocks
    .filter((b): b is Extract<AnthBlock, { type: "thinking" }> => b.type === "thinking")
    .map((b) => b.thinking)
    .join("\n")
    .trim();
  const tool_calls = blocks
    .filter((b): b is Extract<AnthBlock, { type: "tool_use" }> => b.type === "tool_use")
    .map((b) => ({
      id: b.id,
      type: "function" as const,
      function: { name: b.name, arguments: JSON.stringify(b.input ?? {}) },
    }));
  return {
    ok: true,
    message: {
      role: "assistant",
      content: text,
      thinking: thinking || undefined,
      tool_calls: tool_calls.length ? tool_calls : undefined,
    },
  };
}

export const agentTurn = createServerFn({ method: "POST" })
  .validator((input: TurnInput) => ({
    messages: input.messages,
    fileList: input.fileList,
    provider: input.provider,
    model: input.model,
    access: typeof input.access === "string" ? input.access : "",
    accountId: typeof input.accountId === "string" ? input.accountId : "",
    skills: typeof input.skills === "string" ? input.skills : "",
    mode: input.mode === "chat" || input.mode === "plan" ? input.mode : "build",
    effort: typeof input.effort === "string" ? input.effort : "",
  }))
  .handler(async ({ data }): Promise<AgentTurnResult> => {
    const mode: AgentMode = data.mode === "chat" || data.mode === "plan" ? data.mode : "build";
    const tools = toolsForMode(mode);
    const messages = withSystem(data.messages ?? [], data.fileList, data.skills, mode);
    const model = (data.model || "").trim();
    const effort = (data.effort || "").trim();

    if (data.provider === "grok") {
      const apiKey = process.env.XAI_API_KEY;
      if (!apiKey) return { ok: false, error: "Grok indisponível neste ambiente." };
      return openaiCompatible({
        url: "https://api.x.ai/v1/chat/completions",
        headers: { Authorization: `Bearer ${apiKey}` },
        model: model || "grok-4.5",
        messages,
        tools,
        extra: {
          max_tokens: 1600,
          ...(effort ? { reasoning_effort: effort } : {}),
        },
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
      return claudeTurn(access, model, messages, tools, effort);
    }

    if (!model) return { ok: false, error: "escolha um modelo ChatGPT na lista da API." };
    const headers: Record<string, unknown> = {
      Authorization: `Bearer ${access}`,
      originator: "codex_cli_rs",
    };
    if (data.accountId) headers["ChatGPT-Account-ID"] = data.accountId;
    return openaiCompatible({
      url: "https://chatgpt.com/backend-api/codex/v1/chat/completions",
      headers: headers as Record<string, string>,
      model,
      messages,
      tools,
      extra: {
        max_completion_tokens: 1600,
        ...(effort ? { reasoning_effort: effort } : {}),
      },
    });
  });
