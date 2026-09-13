import { createServerFn } from "@tanstack/react-start";
import type { AgentId } from "./providers";
import { parseEffortList, type EffortId } from "./effort";

export type ModelInfo = { id: string; label: string; efforts?: EffortId[]; ctx?: number };

function push(out: ModelInfo[], seen: Set<string>, id: string, label?: string) {
  const slug = id.trim();
  if (!slug || seen.has(slug)) return;
  seen.add(slug);
  out.push({ id: slug, label: (label || slug).trim() });
}

function pickCtx(m: Record<string, unknown>): number | undefined {
  const cap = m.capabilities && typeof m.capabilities === "object" ? (m.capabilities as Record<string, unknown>) : {};
  const n = Number(
    m.context_window ??
      m.context_length ??
      m.max_input_tokens ??
      m.input_token_limit ??
      m.context_tokens ??
      cap.context_window ??
      cap.context_length ??
      0,
  );
  return Number.isFinite(n) && n > 1000 ? Math.round(n) : undefined;
}

function asList(json: unknown): ModelInfo[] {
  if (!json || typeof json !== "object") return [];
  const rec = json as Record<string, unknown>;
  let raw: unknown = rec.data ?? rec.models ?? rec.items ?? rec.model_slugs;
  if (raw && !Array.isArray(raw) && typeof raw === "object") {
    raw = Object.entries(raw as Record<string, unknown>).map(([k, v]) =>
      v && typeof v === "object" ? { slug: k, ...(v as object) } : { slug: k },
    );
  }
  const arr = Array.isArray(raw) ? raw : [];
  const out: ModelInfo[] = [];
  const seen = new Set<string>();
  for (const item of arr) {
    if (typeof item === "string") {
      push(out, seen, item);
      continue;
    }
    if (!item || typeof item !== "object") continue;
    const m = item as Record<string, unknown>;
    const vis = String(m.visibility ?? m.hidden ?? "");
    if (vis === "hidden" || vis === "true") continue;
    const id = String(m.slug ?? m.id ?? m.model ?? m.name ?? "").trim();
    const label = String(m.display_name ?? m.displayName ?? m.title ?? m.name ?? id);
    const efforts = parseEffortList(m);
    const ctx = pickCtx(m);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    const info: ModelInfo = { id, label: (label || id).trim() };
    if (efforts.length) info.efforts = efforts;
    if (ctx) info.ctx = ctx;
    out.push(info);
  }
  return out.sort((a, b) => a.label.localeCompare(b.label, "pt"));
}

async function getJson(url: string, headers: Record<string, string>) {
  const res = await fetch(url, { headers });
  const text = await res.text();
  if (!res.ok) return { ok: false as const, status: res.status, text };
  try {
    return { ok: true as const, json: JSON.parse(text) as unknown };
  } catch {
    return { ok: false as const, status: res.status, text };
  }
}

async function codexClientVersion() {
  try {
    const r = await fetch("https://registry.npmjs.org/@openai/codex/latest");
    if (!r.ok) return "0.145.0";
    const j = (await r.json()) as { version?: string };
    return j.version || "0.145.0";
  } catch {
    return "0.145.0";
  }
}

export const listProviderModels = createServerFn({ method: "POST" })
  .validator((input: { provider: AgentId; access?: string; accountId?: string }) => input)
  .handler(async ({ data }) => {
    if (data.provider === "grok") {
      const key = process.env.XAI_API_KEY;
      if (!key) return { ok: false as const, error: "Grok indisponível", models: [] as ModelInfo[] };
      const r = await getJson("https://api.x.ai/v1/models", {
        Authorization: `Bearer ${key}`,
      });
      if (!r.ok) return { ok: false as const, error: `xAI models ${r.status}`, models: [] };
      return { ok: true as const, models: asList(r.json) };
    }

    const access = (data.access || "").trim();

    if (data.provider === "claude") {
      if (!access) {
        return { ok: false as const, error: "conecte o Claude para listar os modelos", models: [] };
      }
      const r = await getJson("https://api.anthropic.com/v1/models", {
        Authorization: `Bearer ${access}`,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "oauth-2025-04-20,claude-code-20250219",
      });
      if (!r.ok) return { ok: false as const, error: `anthropic models ${r.status}`, models: [] };
      return { ok: true as const, models: asList(r.json) };
    }

    if (access) {
      const version = await codexClientVersion();
      const headers: Record<string, string> = {
        Authorization: `Bearer ${access}`,
        originator: "codex_cli_rs",
        version,
        "OpenAI-Beta": "responses=v1",
        Accept: "application/json",
      };
      if (data.accountId) {
        headers["ChatGPT-Account-ID"] = data.accountId;
        headers["chatgpt-account-id"] = data.accountId;
      }
      const urls = [
        `https://chatgpt.com/backend-api/codex/models?client_version=${encodeURIComponent(version)}`,
        "https://chatgpt.com/backend-api/codex/models",
        "https://chatgpt.com/backend-api/models",
        "https://api.openai.com/v1/models",
      ];
      let last = 0;
      for (const url of urls) {
        const h = url.includes("api.openai.com")
          ? { Authorization: `Bearer ${access}`, Accept: "application/json" }
          : headers;
        const r = await getJson(url, h);
        last = r.ok ? 200 : r.status;
        if (!r.ok) continue;
        const models = asList(r.json);
        if (models.length) return { ok: true as const, models };
      }
      return {
        ok: false as const,
        error: `ChatGPT não devolveu modelos (HTTP ${last}). Reconecta o Codex.`,
        models: [],
      };
    }
    return {
      ok: false as const,
      error: "conecte o ChatGPT para listar os modelos da conta",
      models: [],
    };
  });
