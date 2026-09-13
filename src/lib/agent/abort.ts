const acs = new Map<string, AbortController>();

export function startAbort(slot: string): AbortSignal {
  acs.get(slot)?.abort();
  const ac = new AbortController();
  acs.set(slot, ac);
  return ac.signal;
}

export function abortFetch(slot: string) {
  acs.get(slot)?.abort();
}

export function fireAbort(slot: string) {
  abortFetch(slot);
  void import("@/lib/workspace/node-runtime").then((m) => m.abortNodeJobs());
}

export function isAborted(slot: string) {
  return !!acs.get(slot)?.signal.aborted;
}

export function abortSignal(slot: string): AbortSignal | undefined {
  return acs.get(slot)?.signal;
}
