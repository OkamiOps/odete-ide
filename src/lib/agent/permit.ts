export type PermitMode = "ask" | "auto" | "full";

const SAFE = new Set(["read_file", "list_dir", "grep"]);

export function needsPermit(mode: PermitMode, name: string) {
  if (mode === "full") return false;
  if (mode === "auto") return !SAFE.has(name);
  return true;
}

let waiter: ((ok: boolean) => void) | null = null;

export function waitPermit() {
  waiter?.(false);
  return new Promise<boolean>((resolve) => {
    waiter = resolve;
  });
}

export function answerPermit(ok: boolean) {
  const fn = waiter;
  waiter = null;
  fn?.(ok);
}