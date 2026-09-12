import type { AgentId } from "./providers";

export type EffortId = "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";

export const EFFORT_ORDER: EffortId[] = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];

export const EFFORT_LABEL: Record<EffortId, string> = {
  none: "None",
  minimal: "Min",
  low: "Low",
  medium: "Mid",
  high: "High",
  xhigh: "Extra",
  max: "Max",
};

export const EFFORT_HINT: Record<EffortId, string> = {
  none: "off",
  minimal: "leve",
  low: "rápido",
  medium: "médio",
  high: "fundo",
  xhigh: "longo",
  max: "máx",
};

const cache = new Map<string, EffortId[]>();

export function effortKey(provider: AgentId, model: string) {
  return `${provider}:${model}`;
}

export function rememberEfforts(provider: AgentId, model: string, efforts: EffortId[]) {
  if (efforts.length) cache.set(effortKey(provider, model), efforts);
}

export function parseEffortList(raw: unknown): EffortId[] {
  const found = new Set<EffortId>();
  const walk = (v: unknown) => {
    if (!v) return;
    if (typeof v === "string") {
      const id = v.toLowerCase().trim() as EffortId;
      if (EFFORT_ORDER.includes(id)) found.add(id);
      return;
    }
    if (Array.isArray(v)) {
      v.forEach(walk);
      return;
    }
    if (typeof v === "object") {
      const rec = v as Record<string, unknown>;
      walk(rec.supported_reasoning_efforts);
      walk(rec.supported_reasoning_effort);
      walk(rec.reasoning_efforts);
      walk(rec.reasoning_effort);
      walk(rec.effort);
      walk(rec.efforts);
      walk(rec.levels);
      walk(rec.supported);
      if (rec.capabilities) walk(rec.capabilities);
      if (rec.output_config) walk(rec.output_config);
    }
  };
  walk(raw);
  return EFFORT_ORDER.filter((id) => found.has(id));
}

function guess(provider: AgentId, model: string): EffortId[] {
  const id = model.toLowerCase();
  if (!id) return [];

  if (provider === "grok") {
    if (/non[-_]?reasoning/.test(id) || /imagine|image|tts|video/.test(id)) return [];
    if (/4\.6|4-6|4\.20|4-20|multi-agent/.test(id)) return ["low", "medium", "high", "xhigh"];
    if (/4\.5|4-5/.test(id)) return ["low", "medium", "high"];
    if (/4\.3|4-3/.test(id)) return ["none", "low", "medium", "high"];
    if (/reasoning/.test(id)) return ["low", "high"];
    if (/grok-4|grok-3-mini|grok-code|grok-build/.test(id)) return ["low", "medium", "high"];
    return [];
  }

  if (provider === "claude") {
    if (/haiku|instant/.test(id)) return [];
    if (/opus-5|fable|mythos|sonnet-5|opus-4\.[678]|sonnet-4\.6|opus-4-[678]|sonnet-4-6|claude-sonnet-4-6|claude-opus-4/.test(id)) {
      return ["low", "medium", "high", "xhigh", "max"];
    }
    if (/sonnet-4|opus-4|claude-4/.test(id)) return ["low", "medium", "high"];
    return [];
  }

  if (/chat-latest/.test(id) && !/codex/.test(id)) return [];
  if (/gpt-5\.2-pro|gpt-5-pro/.test(id)) return /5\.2/.test(id) ? ["medium", "high", "xhigh"] : ["high"];
  if (/gpt-5\.2|gpt-5\.6|gpt-6|gpt-5\.5|gpt-5\.4/.test(id)) {
    return /codex/.test(id) ? ["low", "medium", "high", "xhigh"] : ["none", "low", "medium", "high", "xhigh"];
  }
  if (/gpt-5\.1/.test(id)) {
    if (/codex-max/.test(id)) return ["low", "medium", "high", "xhigh"];
    if (/codex/.test(id)) return ["low", "medium", "high"];
    return ["none", "low", "medium", "high"];
  }
  if (/gpt-5/.test(id)) {
    return /codex/.test(id) ? ["low", "medium", "high"] : ["minimal", "low", "medium", "high"];
  }
  if (/(^|[^a-z])o[1-4]([^0-9]|$)/.test(id)) return ["low", "medium", "high"];
  return [];
}

export function effortsForModel(provider: AgentId, model: string, fromApi?: EffortId[]): EffortId[] {
  if (fromApi?.length) return fromApi;
  const cached = cache.get(effortKey(provider, model));
  if (cached?.length) return cached;
  return guess(provider, model);
}

export function defaultEffort(options: EffortId[]): EffortId | "" {
  if (!options.length) return "";
  if (options.includes("medium")) return "medium";
  if (options.includes("high")) return "high";
  return options[Math.floor((options.length - 1) / 2)] ?? options[0]!;
}
