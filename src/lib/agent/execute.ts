import { runShellAsync, isReadShell } from "@/lib/workspace/shell";
import { useWorkspace } from "@/lib/workspace/store";
import { useTerms } from "@/lib/workspace/terms";
import { usePatches } from "./patches";
import type { AgentMode } from "./tools";

function clip(s: string, max = 200_000) {
  if (s.length <= max) return s;
  return s.slice(0, max) + "\n… truncado";
}

export async function executeTool(name: string, rawArgs: string, mode: AgentMode = "build"): Promise<string> {
  let args: Record<string, unknown> = {};
  try {
    args = rawArgs ? (JSON.parse(rawArgs) as Record<string, unknown>) : {};
  } catch {
    return "argumentos JSON inválidos";
  }
  const w = useWorkspace.getState();
  const str = (k: string) => (typeof args[k] === "string" ? (args[k] as string) : "");

  switch (name) {
    case "read_file": {
      const path = str("path").replace(/^\/+/, "");
      const body = w.readFile(path);
      return body === undefined ? `não existe: ${path}` : body;
    }
    case "str_replace": {
      if (mode === "chat") return "chat não edita. mude pra Plan ou Build.";
      const path = str("path").replace(/^\/+/, "");
      const old = str("old");
      const neu = typeof args.new === "string" ? (args.new as string) : str("new");
      if (!path) return "caminho inválido";
      if (!old) return "old vazio";
      const before = w.readFile(path);
      if (before === undefined) return `não existe: ${path}`;
      const hits = before.split(old).length - 1;
      if (hits === 0) return "trecho não encontrado — leia o arquivo de novo";
      if (hits > 1) return `trecho aparece ${hits} vezes — seja mais específico`;
      const after = before.replace(old, neu);
      if (mode === "plan") {
        w.writeFile(path, after);
        return `escrito ${path}`;
      }
      const patch = usePatches.getState().queue(path, before, after);
      return `PATCH:${patch.id}`;
    }
    case "write_file": {
      if (mode === "chat") return "chat não edita. mude pra Plan ou Build.";
      const path = str("path").replace(/^\/+/, "");
      const content = str("content");
      if (!path) return "caminho inválido";
      if (mode === "plan") {
        w.writeFile(path, content);
        return `escrito ${path}`;
      }
      const before = w.readFile(path) ?? "";
      const patch = usePatches.getState().queue(path, before, content);
      return `PATCH:${patch.id}`;
    }
    case "list_dir": {
      const path = str("path").replace(/^\/+/, "");
      const names = w.listDir(path);
      return names.length ? names.join("\n") : "(vazio)";
    }
    case "grep":
      return w.grep(str("pattern"), str("path") || undefined);
    case "read_terminal": {
      const n = typeof args.n === "number" && args.n > 0 ? Math.min(200, args.n) : 80;
      const terms = useTerms.getState();
      const tab = terms.tabs.find((t) => t.id === terms.active) ?? terms.tabs[0];
      if (!tab?.lines.length) return "(terminal vazio)";
      return tab.lines
        .slice(-n)
        .map((l) => `${l.kind === "in" ? "" : l.kind === "err" ? "! " : ""}${l.text}`)
        .join("\n");
    }
    case "run_shell": {
      const command = str("command");
      if (mode === "chat" && !isReadShell(command)) {
        return "chat só lê o terminal. use Plan (escrever plano) ou Build (executar).";
      }
      if (mode === "plan" && !isReadShell(command) && !/^(mkdir|touch)\b/.test(command.trim())) {
        return "plan não roda npm/git que muda remoto. mkdir/touch e leitura ok. Build pra o resto.";
      }
      return clip(await runShellAsync(command));
    }
    default:
      return `tool desconhecida: ${name}`;
  }
}
