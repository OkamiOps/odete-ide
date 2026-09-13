const pending = new Map<string, string[]>();
const listeners = new Set<() => void>();

function emit() {
  for (const fn of [...listeners]) fn();
}

export function pushSteer(slot: string, text: string) {
  const t = text.trim();
  if (!t) return;
  const q = pending.get(slot) ?? [];
  q.push(t);
  pending.set(slot, q);
  emit();
}

export function takeSteer(slot: string): string | null {
  const q = pending.get(slot);
  if (!q?.length) return null;
  const t = q.shift()!;
  if (q.length) pending.set(slot, q);
  else pending.delete(slot);
  return t;
}

export function takeAllSteer(slot: string): string {
  const parts: string[] = [];
  let t: string | null;
  while ((t = takeSteer(slot))) parts.push(t);
  return parts.join("\n\n");
}

export function hasSteer(slot: string) {
  return (pending.get(slot)?.length ?? 0) > 0;
}

export function clearSteer(slot: string) {
  pending.delete(slot);
}

export function subscribeSteer(fn: () => void) {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}
