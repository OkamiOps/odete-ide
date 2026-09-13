import { runShell } from "@/lib/workspace/shell";
import { useWorkspace } from "@/lib/workspace/store";
import { usePatches } from "./patches";

function clip(s: string, max = 200_000) {
  if (s.length <= max) return s;
  return s.slice(0, max) + "\n… truncado";
}

export function executeTool(name: string, rawArgs: string): string {
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
      const patch = usePatches.getState().queue(path, before, after);
      return `PATCH:${patch.id}`;
    }
    case "write_file": {
      const path = str("path").replace(/^\/+/, "");
      const content = str("content");
      if (!path) return "caminho inválido";
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
    case "run_shell":
      return clip(runShell(str("command")));
    default:
      return `tool desconhecida: ${name}`;
  }
}
