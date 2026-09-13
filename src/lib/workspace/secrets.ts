import { idbKv } from "./idb";
import type { TokenBundle } from "@/lib/agent/oauth";
import type { GithubUser } from "@/lib/github/api";

const KEY = "colo-secrets-v1";
const DEAD = ["colo-workspace-v2", "colo-workspace-v1", "colo-workspace"];

export type Secrets = {
  github: { token: string; user: GithubUser } | null;
  claudeAuth: TokenBundle | null;
  openaiAuth: TokenBundle | null;
};

function parse(raw: string | null): Secrets | null {
  if (!raw) return null;
  try {
    const j = JSON.parse(raw) as { state?: Secrets } & Secrets;
    const s = j.state ?? j;
    if (!s || typeof s !== "object") return null;
    return {
      github: s.github ?? null,
      claudeAuth: s.claudeAuth ?? null,
      openaiAuth: s.openaiAuth ?? null,
    };
  } catch {
    return null;
  }
}

export function freeWorkspaceQuota() {
  for (const k of DEAD) {
    try {
      localStorage.removeItem(k);
    } catch {
      /* */
    }
  }
}

export async function writeSecrets(s: Secrets) {
  const raw = JSON.stringify(s);
  await idbKv.setItem(KEY, raw);
  try {
    localStorage.setItem(KEY, raw);
  } catch {
    /* quota — idb já guardou */
  }
}

export async function readSecrets(): Promise<Secrets | null> {
  const a = parse(await idbKv.getItem(KEY));
  if (a && (a.github || a.claudeAuth || a.openaiAuth)) return a;
  try {
    return parse(localStorage.getItem(KEY));
  } catch {
    return a;
  }
}

export async function persistAuth() {
  const { useChrome } = await import("./chrome");
  const { useProjects } = await import("./projects");
  const c = useChrome.getState();
  const p = useProjects.getState();
  await writeSecrets({
    github: p.github,
    claudeAuth: c.claudeAuth,
    openaiAuth: c.openaiAuth,
  });
}

export async function restoreAuth() {
  const s = await readSecrets();
  if (!s) return;
  const { useChrome } = await import("./chrome");
  const { useProjects } = await import("./projects");
  const c = useChrome.getState();
  if (s.claudeAuth && !c.claudeAuth?.access) useChrome.setState({ claudeAuth: s.claudeAuth });
  if (s.openaiAuth && !c.openaiAuth?.access) useChrome.setState({ openaiAuth: s.openaiAuth });
  if (s.github && !useProjects.getState().github) useProjects.setState({ github: s.github });
}
