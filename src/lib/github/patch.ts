export type GhFileChange = {
  filename: string;
  status: string;
  patch?: string;
  previous_filename?: string;
  truncated?: boolean;
};

export function reverseApply(tree: Record<string, string>, files: GhFileChange[]): Record<string, string> {
  const next = { ...tree };
  for (const f of files) {
    if (f.status === "added") {
      delete next[f.filename];
      continue;
    }
    if (f.status === "removed" || f.status === "deleted") {
      const old = fileFromPatch(f.patch || "", "old");
      if (old != null) next[f.filename] = old;
      continue;
    }
    if (f.truncated) continue;
    if (f.status === "renamed" && f.previous_filename) {
      const body = next[f.filename];
      delete next[f.filename];
      next[f.previous_filename] = (f.patch ? reverseUnified(body ?? "", f.patch) : body) ?? body ?? "";
      continue;
    }
    const cur = next[f.filename];
    if (!f.patch) continue;
    if (cur === undefined) {
      const old = fileFromPatch(f.patch, "old");
      if (old != null) next[f.filename] = old;
      continue;
    }
    const reversed = reverseUnified(cur, f.patch);
    if (reversed != null) next[f.filename] = reversed;
  }
  return next;
}

function fileFromPatch(patch: string, side: "old" | "new"): string | null {
  if (!patch) return null;
  const out: string[] = [];
  for (const line of patch.split("\n")) {
    if (!line || line.startsWith("@@") || line.startsWith("diff") || line.startsWith("index") || line.startsWith("---") || line.startsWith("+++") || line.startsWith("\\")) {
      continue;
    }
    if (side === "old") {
      if (line.startsWith("+")) continue;
      out.push(line.startsWith("-") || line.startsWith(" ") ? line.slice(1) : line);
    } else {
      if (line.startsWith("-")) continue;
      out.push(line.startsWith("+") || line.startsWith(" ") ? line.slice(1) : line);
    }
  }
  return out.join("\n");
}

function reverseUnified(current: string, patch: string): string | null {
  const hunks: { newStart: number; lines: string[] }[] = [];
  const parts = patch.split(/(?=^@@ )/m);
  for (const part of parts) {
    const m = part.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
    if (!m) continue;
    const newStart = Number(m[1]);
    const body = part.split("\n").slice(1).filter((l) => !l.startsWith("\\"));
    hunks.push({ newStart, lines: body });
  }
  if (!hunks.length) return fileFromPatch(patch, "old");
  let result = current.split("\n");
  try {
    for (const h of hunks.slice().reverse()) {
      let i = Math.max(0, h.newStart - 1);
      const built: string[] = [];
      const start = i;
      for (const line of h.lines) {
        if (line.startsWith("+")) {
          i += 1;
        } else if (line.startsWith("-")) {
          built.push(line.slice(1));
        } else if (line.startsWith(" ") || line === "") {
          built.push(line.startsWith(" ") ? line.slice(1) : line);
          i += 1;
        }
      }
      result.splice(start, Math.max(0, i - start), ...built);
    }
    return result.join("\n");
  } catch {
    return fileFromPatch(patch, "old");
  }
}
