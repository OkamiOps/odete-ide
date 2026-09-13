import type { FileMap } from "./types";

export type Skill = {
  id: string;
  name: string;
  description: string;
  when: string[];
  body: string;
  path?: string;
};

export const BUILTIN_SKILLS: Skill[] = [
  {
    id: "commit",
    name: "Commit",
    description: "Mensagens curtas no padrão convencional, em PT-BR.",
    when: ["commit", "git", "mensagem", "changelog"],
    body: `Mensagens: tipo(escopo): o que mudou
Tipos: feat, fix, chore, docs, refactor, style, test.
Uma linha, sem ponto final, verbo no infinitivo. Ex: feat(editor): destacar seleção pelo tema.`,
  },
  {
    id: "swiftui",
    name: "SwiftUI",
    description: "Estilo SwiftUI simples para o playground do iPad.",
    when: ["swift", "swiftui", "view", "vstack", "playground"],
    body: `Swift neste workspace é um subset: VStack, HStack, Text, Button, padding.
Prefira views pequenas, nomes claros, sem Combine/async. Preview usa o interpretador da Odete.`,
  },
  {
    id: "review",
    name: "Review",
    description: "Revisão curta: risco, bug, o que está ok.",
    when: ["review", "revisa", "revisão", "olha esse", "código"],
    body: `Revise em 3 blocos: (1) o que está ok, (2) bugs/risco, (3) patch sugerido.
Não reescreva arquivo inteiro se um hunk resolve. Cite path:linha.`,
  },
  {
    id: "html",
    name: "HTML",
    description: "index.html e CSS do preview, sem framework.",
    when: ["html", "css", "preview", "página", "index"],
    body: `index.html é a página do Preview. CSS em src/style.css. JS em src/main.js.
Sem build step além do Vite. Acessível, contraste ok, sem dependência nova.`,
  },
];

function parseFront(text: string) {
  const m = /^---\n([\s\S]*?)\n---\n?([\s\S]*)$/.exec(text);
  if (!m) return { meta: {} as Record<string, string>, body: text.trim() };
  const meta: Record<string, string> = {};
  for (const line of m[1]!.split("\n")) {
    const i = line.indexOf(":");
    if (i < 0) continue;
    meta[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/^["']|["']$/g, "");
  }
  return { meta, body: m[2]!.trim() };
}

export function parseSkill(path: string, text: string): Skill | null {
  const { meta, body } = parseFront(text);
  const id = (
    meta.id ||
    meta.name ||
    path
      .split("/")
      .pop()
      ?.replace(/\.md$/i, "") ||
    "skill"
  )
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/^-|-$/g, "");
  if (!body) return null;
  const when = (meta.when || meta.triggers || "")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  return {
    id,
    name: meta.name || id,
    description: meta.description || body.split("\n")[0]!.slice(0, 80),
    when,
    body,
    path,
  };
}

export function skillsFromFiles(files: FileMap): Skill[] {
  const out: Skill[] = [];
  for (const [path, text] of Object.entries(files)) {
    if (!/(^|\/)\.colo\/skills\/.+\.md$/i.test(path) && !/(^|\/)SKILL\.md$/i.test(path)) continue;
    const s = parseSkill(path, text);
    if (s) out.push(s);
  }
  return out;
}

export function allSkills(files: FileMap): Skill[] {
  const fromFiles = skillsFromFiles(files);
  const ids = new Set(fromFiles.map((s) => s.id));
  return [...fromFiles, ...BUILTIN_SKILLS.filter((s) => !ids.has(s.id))];
}

export function slashesIn(prompt: string) {
  return [...prompt.matchAll(/(^|[\s])\/([a-zA-Z][\w-]*)/g)].map((m) => m[2]!.toLowerCase());
}

export function pickSkills(all: Skill[], prompt: string) {
  const ids = new Set(slashesIn(prompt));
  if (!ids.size) return [];
  return all.filter((s) => ids.has(s.id) || ids.has(s.name.toLowerCase().replace(/\s+/g, "")));
}

export function formatSkillsPrompt(all: Skill[], prompt: string) {
  const active = pickSkills(all, prompt);
  if (!active.length) {
    const names = all.map((s) => `/${s.id}`).join(", ");
    return names ? `Skills via /nome no chat: ${names}` : "";
  }
  return `Skills aplicadas neste turno (o usuário chamou com /nome):\n${active
    .map((s) => `### /${s.id} — ${s.name}\n${s.body}`)
    .join("\n\n")}`;
}

export const SKILL_TEMPLATE = `---
name: Minha skill
description: Quando usar /id no chat do agente.
---

Instruções objetivas. O agente lê isto só quando o usuário escreve /id.
`;
