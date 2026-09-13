import { hasSteer, subscribeSteer } from "./steer";

export type PermitMode = "ask" | "auto" | "full";

const SAFE = new Set(["read_file", "list_dir", "grep", "read_terminal"]);

export function needsPermit(mode: PermitMode, name: string) {
  if (mode === "full") return false;
  if (mode === "auto") return !SAFE.has(name);
  return true;
}

const waiters = new Map<string, (ok: boolean) => void>();

export function waitPermit(slot = "a") {
  waiters.get(slot)?.(false);
  return new Promise<boolean>((resolve) => {
    const unsub = subscribeSteer(() => {
      if (hasSteer(slot)) finish(false);
    });
    function finish(ok: boolean) {
      unsub();
      waiters.delete(slot);
      resolve(ok);
    }
    waiters.set(slot, finish);
  });
}

export function answerPermit(ok: boolean, slot = "a") {
  const fn = waiters.get(slot);
  waiters.delete(slot);
  fn?.(ok);
}