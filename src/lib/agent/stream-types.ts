import type { AgentMessage } from "./server";

export type TokenUse = {
  input: number;
  output: number;
  cache: number;
  reasoning: number;
};

export type StreamEvt =
  | { t: "think"; c: string }
  | { t: "text"; c: string }
  | { t: "tools"; calls: NonNullable<AgentMessage["tool_calls"]> }
  | { t: "usage"; use: TokenUse }
  | { t: "error"; e: string }
  | { t: "done" };

export const emptyUse = (): TokenUse => ({ input: 0, output: 0, cache: 0, reasoning: 0 });

export function fillUse(cur: TokenUse, next: TokenUse): TokenUse {
  return {
    input: next.input || cur.input,
    output: next.output || cur.output,
    cache: next.cache || cur.cache,
    reasoning: next.reasoning || cur.reasoning,
  };
}

export function addUse(a: TokenUse, b: TokenUse): TokenUse {
  return {
    input: a.input + b.input,
    output: a.output + b.output,
    cache: a.cache + b.cache,
    reasoning: a.reasoning + b.reasoning,
  };
}

export function pickUsage(json: Record<string, unknown>): TokenUse | null {
  const u = (json.usage ??
    (json.message && typeof json.message === "object"
      ? (json.message as Record<string, unknown>).usage
      : undefined)) as Record<string, unknown> | undefined;
  if (!u || typeof u !== "object") return null;
  const details = (u.prompt_tokens_details ?? u.input_tokens_details ?? {}) as Record<string, unknown>;
  const out = (u.completion_tokens_details ?? {}) as Record<string, unknown>;
  const input = Number(u.prompt_tokens ?? u.input_tokens ?? 0) || 0;
  const output = Number(u.completion_tokens ?? u.output_tokens ?? 0) || 0;
  const cache =
    Number(details.cached_tokens ?? u.cache_read_input_tokens ?? u.cached_tokens ?? 0) || 0;
  const reasoning = Number(out.reasoning_tokens ?? u.reasoning_tokens ?? 0) || 0;
  if (!input && !output && !cache && !reasoning) return null;
  return { input, output, cache, reasoning };
}