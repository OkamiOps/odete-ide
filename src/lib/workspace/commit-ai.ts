import { agentTurn } from "@/lib/agent/server";
import { authForTurn } from "@/lib/agent/session";
import { agentConnected, currentAgentModel, useChrome } from "@/lib/workspace/chrome";
import { fileStatus } from "@/lib/workspace/diff";
import { useWorkspace } from "@/lib/workspace/store";

function localMessage(changed: string[]) {
  const name = changed[0]?.split("/").pop() ?? "arquivos";
  const extra = changed.length > 1 ? ` e mais ${changed.length - 1}` : "";
  return `chore: atualiza ${name}${extra}`;
}

export async function suggestCommit(changed: string[]) {
  if (!changed.length) return "";
  const fallback = localMessage(changed);
  const chrome = useChrome.getState();
  if (!agentConnected(chrome)) return fallback;
  const w = useWorkspace.getState();
  const head = w.commits.at(-1);
  const summary = changed
    .slice(0, 12)
    .map((p) => `${fileStatus(head?.files[p], w.files[p])} ${p}`)
    .join("\n");
  try {
    const tokens = await authForTurn(chrome.agentId);
    const result = await agentTurn({
      data: {
        messages: [
          {
            role: "user",
            content: `Escreva UMA linha de commit (conventional: feat|fix|chore|docs|refactor|style|test). Sem aspas, sem ponto final, PT-BR, no máximo 72 caracteres.\nArquivos:\n${summary}\nResponda só a mensagem.`,
          },
        ],
        fileList: changed.join("\n"),
        provider: chrome.agentId,
        model: currentAgentModel(chrome),
        access: tokens.access,
        accountId: tokens.accountId,
      },
    });
    if (!result.ok) return fallback;
    const line = (result.message.content ?? "")
      .trim()
      .split("\n")
      .map((s) => s.trim())
      .find((s) => s && !s.startsWith("```"));
    if (!line) return fallback;
    return line.replace(/^["'`]+|["'`]+$/g, "").slice(0, 72);
  } catch {
    return fallback;
  }
}
