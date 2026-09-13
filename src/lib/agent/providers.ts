export type AgentId = "grok" | "claude" | "codex";

export type AgentDef = {
  id: AgentId;
  label: string;
  vendor: string;
  blurb: string;
  defaultModel: string;
  auth: "builtin" | "oauth" | "device";
};

export const AGENTS: AgentDef[] = [
  {
    id: "grok",
    label: "Grok",
    vendor: "xAI",
    blurb: "Já incluso neste app. Modelos vêm da xAI.",
    defaultModel: "grok-4-1-fast-reasoning",
    auth: "builtin",
  },
  {
    id: "claude",
    label: "Claude",
    vendor: "Anthropic",
    blurb: "OAuth da sua assinatura Pro/Max — o mesmo login do Claude Code.",
    defaultModel: "claude-sonnet-4-6",
    auth: "oauth",
  },
  {
    id: "codex",
    label: "Codex",
    vendor: "OpenAI",
    blurb: "Device connection da sua conta ChatGPT. Ative o código em Ajustes → Segurança.",
    defaultModel: "",
    auth: "device",
  },
];

export function agentById(id: AgentId) {
  return AGENTS.find((a) => a.id === id) ?? AGENTS[0]!;
}
