import { extOf } from "@/lib/utils";

export type OutlineItem = { line: number; kind: string; name: string };

export function outlineOf(path: string, text: string): OutlineItem[] {
  const ext = extOf(path);
  const out: OutlineItem[] = [];
  const lines = text.split("\n");
  const re =
    ext === "css" || ext === "scss"
      ? /^([.#]?[\w-]+)(?:\s*,\s*[.#]?[\w-]+)*\s*\{/
      : ext === "swift"
        ? /\b(func|struct|class|enum|protocol|var|let)\s+(\w+)/
        : /\b(?:export\s+)?(?:async\s+)?(function|class|const|let|var|type|interface|enum)\s+(\w+)/;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? "";
    if (ext === "css" || ext === "scss") {
      const m = re.exec(line.trim());
      if (m?.[1] && !m[1].startsWith("@")) out.push({ line: i + 1, kind: "sel", name: m[1] });
      continue;
    }
    const m = re.exec(line);
    if (m) out.push({ line: i + 1, kind: m[1] ?? "fn", name: m[2] ?? m[1] ?? "?" });
  }
  return out.slice(0, 80);
}
