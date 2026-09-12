import { claudeRefresh, openaiRefresh, type TokenBundle } from "./oauth";
import { useChrome } from "@/lib/workspace/chrome";
import type { AgentId } from "./providers";

async function refreshIfNeeded(
  tokens: TokenBundle | null,
  kind: "claude" | "openai",
): Promise<TokenBundle | null> {
  if (!tokens?.access) return null;
  if (tokens.expiresAt - Date.now() > 60_000) return tokens;
  if (!tokens.refresh) return tokens;
  const r =
    kind === "claude"
      ? await claudeRefresh({ data: { refresh: tokens.refresh } })
      : await openaiRefresh({ data: { refresh: tokens.refresh } });
  if (!r.ok) return tokens;
  if (kind === "claude") useChrome.getState().setClaudeAuth(r.tokens);
  else useChrome.getState().setOpenaiAuth(r.tokens);
  return r.tokens;
}

export async function authForTurn(provider: AgentId): Promise<{
  access?: string;
  accountId?: string;
}> {
  const s = useChrome.getState();
  if (provider === "grok") return {};
  if (provider === "claude") {
    const t = await refreshIfNeeded(s.claudeAuth, "claude");
    return { access: t?.access };
  }
  const t = await refreshIfNeeded(s.openaiAuth, "openai");
  return { access: t?.access, accountId: t?.accountId };
}
