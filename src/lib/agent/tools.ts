import { isNoisePath } from "@/lib/workspace/ignore";

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
        "Cria arquivo ou reescreve INTEIRO. No modo plan, grave o plano em .colo/plan.md.",
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
      name: "read_terminal",
      description: "Lê as últimas linhas do terminal (stdout/stderr).",
      parameters: {
        type: "object",
        properties: { n: { type: "number", description: "quantas linhas (default 80)" } },
      },
    },
  },
  {
    type: "function" as const,
    function: {
      name: "run_shell",
      description:
        "Terminal do workspace. ls, cat, mkdir, git, npm i / pnpm i, npm run dev/start/build, node arquivo.js. Quando o app está isolado (tela cheia) o Node é de verdade — Vite, Next, Nest, Astro, Remix sobem no Preview. Sem isolamento, cai no Preview JSX/TS da Odete. Chat só lê. Plan: mkdir/touch só em .colo/.",
      parameters: {
        type: "object",
        properties: { command: { type: "string" } },
        required: ["command"],
      },
    },
  },
];

export type AgentTool = (typeof AGENT_TOOLS)[number];

const CHAT_TOOLS = new Set(["read_file", "list_dir", "grep", "read_terminal", "run_shell"]);
const PLAN_TOOLS = new Set(["read_file", "list_dir", "grep", "read_terminal", "run_shell", "write_file", "str_replace"]);

export function toolsForMode(mode: AgentMode): AgentTool[] {
  if (mode === "build") return [...AGENT_TOOLS];
  if (mode === "plan") return AGENT_TOOLS.filter((t) => PLAN_TOOLS.has(t.function.name));
  return AGENT_TOOLS.filter((t) => CHAT_TOOLS.has(t.function.name));
}

export function formatWorkspace(files: Record<string, string>) {
  const names = Object.keys(files)
    .filter((p) => !isNoisePath(p))
    .sort();
  if (!names.length) return "(vazio)";
  if (names.length <= 400) return names.join("\n");
  return `${names.slice(0, 400).join("\n")}\n… e ${names.length - 400} mais`;
}

export function modePrompt(mode: AgentMode) {
  const read = `Você decide se precisa abrir arquivo, qual, e quando. Use read_file / list_dir / grep / read_terminal só se o conteúdo for necessário. Não invente conteúdo.`;
  if (mode === "chat") {
    return `Modo CHAT: conversa. ${read}
Pode LER o terminal (read_terminal ou run_shell com ls/cat/git status).
Não edite arquivos. Não rode npm i, git push, rm, mkdir.`;
  }
  if (mode === "plan") {
    return `Modo PLAN: investigue e GRAVE o plano em \`.colo/plan.md\` (crie a pasta se precisar).
${read}
Só escreve \`.colo/plan.md\`. mkdir/touch só dentro de \`.colo/\`.
Não rode git push / npm i / rm em massa. Shell de leitura ok.

O arquivo \`.colo/plan.md\` deve ter:

## Objetivo
uma linha

## O que vi
- arquivo — o que importa

## Passos
1. arquivo — mudança

## Riscos
- …

## Fora de escopo
- o que não vamos fazer agora`;
  }
  return `Modo BUILD: pode editar. ${read} Prefira str_replace. write_file só pra arquivo novo ou reescrita total. Depois dos patches, 1–3 linhas do que mudou.`;
}

export const SYSTEM_PROMPT = `Você é o agente da Odete, uma IDE que roda 100% no dispositivo.
O workspace é um filesystem virtual. Lista de paths vem no sistema; o conteúdo só entra se VOCÊ chamar read_file.
Você escolhe quando abrir e qual arquivo. Em todos os modos a leitura está liberada.
Responda em português brasileiro.

Formato (obrigatório, o usuário tem TDAH):
- Nunca um bloco de texto corrido.
- Use ## título curto e listas.
- 1 ideia por bullet.
- No máximo 1 frase solta. O resto vira lista.
- Arquivos sempre em \`backticks\`.`;
