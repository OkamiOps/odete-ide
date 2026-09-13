import type { FileMap } from "./types";

export const APP_NAME = "Odete";

export function rebrandText(text: string): string {
  return text
    .replaceAll("colo-demo", "odete-demo")
    .replaceAll("IDE no colo.", "IDE no dispositivo.")
    .replaceAll("IDE no colo", "IDE no dispositivo")
    .replaceAll("COLO", "ODETE")
    .replaceAll("Colo", "Odete")
    .replace(/(^|[^A-Za-z])colo(?![A-Za-z])/g, "$1odete");
}

export function rebrandPath(path: string): string {
  return path.replace(/(^|\/)\.colo(\/|$)/g, "$1.odete$2");
}

export function rebrandFiles(files: FileMap): FileMap {
  const out: FileMap = {};
  for (const [path, text] of Object.entries(files)) {
    out[rebrandPath(path)] = rebrandText(text);
  }
  return out;
}

export function rebrandName(name: string | undefined | null): string {
  if (!name || /^colo$/i.test(name)) return "odete";
  return rebrandText(name);
}
