import type { FileMap } from "@/lib/workspace/types";

const RULE_FILES = [
  "AGENTS.md",
  "CLAUDE.md",
  ".colo.md",
  ".cursorrules",
  ".colo/rules.md",
];

export function projectRules(files: FileMap) {
  const chunks: string[] = [];
  for (const path of RULE_FILES) {
    const body = files[path];
    if (!body?.trim()) continue;
    chunks.push(`## ${path}\n${body.trim().slice(0, 6000)}`);
  }
  if (!chunks.length) return "";
  return `Regras do projeto (siga):\n${chunks.join("\n\n")}`;
}
