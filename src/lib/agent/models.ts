import { createServerFn } from "@tanstack/react-start";
import type { AgentId } from "./providers";
import { parseEffortList, type EffortId } from "./effort";

export type ModelInfo = { id: string; label: string; efforts?: EffortId[] };

function push(out: ModelInfo[], seen: Set<string>, id: string, label?: string) {
  const slug = id.trim();
  if (!slug || seen.has(slug)) return;
  seen.add(slug);
  out.push({ id: slug, label: (label || slug).trim() });
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
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push(efforts.length ? { id, label: (label || id).trim(), efforts } : { id, label: (label || id).trim() });
  }
  return out.sort((a, b) => a.label.localeCompare(b.label, "pt"));
}

function slugsFromMarkdown(md: string): ModelInfo[] {
  const seen = new Set<string>();
  const out: ModelInfo[] = [];
  const re = /`(gpt-[\w.-]+)`/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(md))) {
    push(out, seen, m[1]!);
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

async function chatgptCatalog(): Promise<ModelInfo[]> {
  const urls = [
    "https://developers.openai.com/codex/models.md",
    "https://learn.chatgpt.com/docs/models.md",
  ];
  for (const url of urls) {
    try {
      const r = await fetch(url, { headers: { Accept: "text/markdown, text/plain, */*" } });
      if (!r.ok) continue;
      const list = slugsFromMarkdown(await r.text());
      if (list.length) return list;
    } catch {
      /* next */
    }
  }
  return [];
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
      };
      if (data.accountId) {
        headers["ChatGPT-Account-ID"] = data.accountId;
        headers["chatgpt-account-id"] = data.accountId;
      }
      const urls = [
        `https://chatgpt.com/backend-api/codex/models?client_version=${encodeURIComponent(version)}`,
        "https://chatgpt.com/backend-api/codex/models",
        "https://chatgpt.com/backend-api/models",
      ];
      for (const url of urls) {
        const r = await getJson(url, headers);
        if (!r.ok) continue;
        const models = asList(r.json);
        if (models.length) return { ok: true as const, models };
      }
    }

    const catalog = await chatgptCatalog();
    if (catalog.length) {
      return {
        ok: true as const,
        models: catalog,
      };
    }
    return {
      ok: false as const,
      error: access
        ? "não deu pra listar modelos do ChatGPT"
        : "conecte o ChatGPT para listar os modelos da conta",
      models: [],
    };
  });
