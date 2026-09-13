export type AgentMode = "chat" | "plan" | "build";

export const AGENT_TOOLS = [
  {
    type: "function" as const,
    function: {
      name: "read_file",
      description: "Lê um arquivo do workspace local.",
      parameters: {
        type: "object",
        properties: { path: { type: "string" } },
        required: ["path"],
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "str_replace",
      description:
        "Substitui um trecho EXATO no arquivo. Prefira isto a write_file. old precisa aparecer uma vez.",
      parameters: {
        type: "object",
        properties: {
          path: { type: "string" },
          old: { type: "string" },
          new: { type: "string" },
        },
        required: ["path", "old", "new"],
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "write_file",
      description:
        "Cria arquivo ou reescreve INTEIRO. Só use se str_replace não der. A edição fica pendente até o usuário aceitar.",
      parameters: {
        type: "object",
        properties: {
          path: { type: "string" },
          content: { type: "string" },
        },
        required: ["path", "content"],
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "list_dir",
      description: "Lista arquivos e pastas. path vazio = raiz.",
      parameters: {
        type: "object",
        properties: { path: { type: "string" } },
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "grep",
      description: "Busca regex no workspace.",
      parameters: {
        type: "object",
        properties: {
          pattern: { type: "string" },
          path: { type: "string" },
        },
        required: ["pattern"],
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "run_shell",
      description:
        "Terminal do workspace. ls, cat, git status/log/commit/push, npm i, npx vite, rm, touch.",
      parameters: {
        type: "object",
        properties: { command: { type: "string" } },
        required: ["command"],
      },
    },
  },
];

export type AgentTool = (typeof AGENT_TOOLS)[number];

const READ_TOOLS = new Set(["read_file", "list_dir", "grep"]);

export function toolsForMode(mode: AgentMode): AgentTool[] {
  if (mode === "build") return [...AGENT_TOOLS];
  return AGENT_TOOLS.filter((t) => READ_TOOLS.has(t.function.name));
}

export function modePrompt(mode: AgentMode) {
  if (mode === "chat") {
    return `Modo CHAT: conversa. Use read_file / list_dir / grep se precisar do código. Não edite arquivos. Não rode comandos que mudam estado. Responda com o que leu — não invente conteúdo de arquivo.`;
  }
  if (mode === "plan") {
    return `Modo PLAN: primeiro INVESTIGUE com tools (list_dir, grep, read_file). Só depois escreva o plano. Não edite. Não rode npm/git que altera estado.

Formato obrigatório:

## Objetivo
uma linha

## O que vi
- arquivo — o que importa nele

## Passos
1. arquivo — mudança
2. …

## Riscos
- …

## Fora de escopo
- o que NÃO vamos fazer agora

Se faltar contexto, leia mais arquivos antes de fechar o plano. Sem código completo — só o plano.`;
  }
  return "Modo BUILD: pode editar. Prefira str_replace (trecho). write_file só pra arquivo novo ou reescrita total. Leia o arquivo antes. Depois dos patches, 1–3 linhas do que mudou.";
}

export const SYSTEM_PROMPT = `Você é o agente da Colo, uma IDE que roda 100% no dispositivo.
O workspace é um filesystem virtual. Não invente conteúdo de arquivo — leia antes de editar.
Responda em português brasileiro, curto e direto.
Se o turno trouxer skills aplicadas, siga essas instruções.`;
