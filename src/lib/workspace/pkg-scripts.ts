import type { FileMap } from "./types";

export function pkgScripts(files: FileMap): string[] {
  const raw = files["package.json"];
  if (!raw) return [];
  try {
    const json = JSON.parse(raw) as { scripts?: Record<string, string> };
    return Object.keys(json.scripts ?? {});
  } catch {
    return [];
  }
}
