import type { FileMap } from "./types";
import { isNoisePath } from "./ignore";

export function wordAt(text: string, pos: number) {
  const re = /[A-Za-z_$][\w$]*/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text))) {
    if (pos >= m.index && pos <= m.index + m[0].length) return m[0];
  }
  return "";
}

export function findDef(name: string, files: FileMap, fromPath: string) {
  if (!name || name.length < 2) return null;
  const pats = [
    new RegExp(`\\b(?:function|class|const|let|var|type|interface|enum)\\s+${name}\\b`),
    new RegExp(`\\b(?:func|struct|enum|protocol|extension)\\s+${name}\\b`),
    new RegExp(`\\b${name}\\s*=\\s*(?:function|\\()`),
    new RegExp(`\\b(?:export\\s+)?(?:async\\s+)?function\\s+${name}\\b`),
  ];
  const order = [fromPath, ...Object.keys(files).filter((p) => p !== fromPath && !isNoisePath(p))];
  for (const path of order) {
    const body = files[path] ?? "";
    const lines = body.split("\n");
    for (let i = 0; i < lines.length; i++) {
      if (pats.some((re) => re.test(lines[i] ?? ""))) return { path, line: i + 1 };
    }
  }
  return null;
}
