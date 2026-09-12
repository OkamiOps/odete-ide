import { createServerFn } from "@tanstack/react-start";
import { CLAUDE_CLIENT_ID, CLAUDE_REDIRECT } from "./pkce";

const OPENAI_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const OPENAI_TOKEN = "https://auth.openai.com/oauth/token";
const OPENAI_USERCODE = "https://auth.openai.com/api/accounts/deviceauth/usercode";
const OPENAI_POLL = "https://auth.openai.com/api/accounts/deviceauth/token";
const OPENAI_DEVICE_REDIRECT = "https://auth.openai.com/deviceauth/callback";
const OPENAI_VERIFY = "https://auth.openai.com/codex/device";
const CLAUDE_TOKEN = "https://platform.claude.com/v1/oauth/token";

export type TokenBundle = {
  access: string;
  refresh: string;
  expiresAt: number;
  accountId?: string;
};

function chatgptAccountId(access: string, idToken?: string) {
  for (const t of [idToken, access]) {
    if (!t) continue;
    const parts = t.split(".");
    if (parts.length < 2) continue;
    try {
      const json = JSON.parse(
        atob(parts[1]!.replace(/-/g, "+").replace(/_/g, "/")),
      ) as Record<string, unknown>;
      const auth = json["https://api.openai.com/auth"] as
        | { chatgpt_account_id?: string }
        | undefined;
      const id =
        auth?.chatgpt_account_id ??
        (typeof json.chatgpt_account_id === "string" ? json.chatgpt_account_id : "");
      if (id) return id;
    } catch {
      /* ignore */
    }
  }
  return "";
}

export const claudeExchange = createServerFn({ method: "POST" })
  .validator((input: { code: string; verifier: string; state: string }) => input)
  .handler(async ({ data }) => {
    const res = await fetch(CLAUDE_TOKEN, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        grant_type: "authorization_code",
        client_id: CLAUDE_CLIENT_ID,
        redirect_uri: CLAUDE_REDIRECT,
        code: data.code,
        code_verifier: data.verifier,
        state: data.state,
      }),
    });
    const t = await res.text();
    if (!res.ok) {
      return { ok: false as const, error: `Claude OAuth ${res.status}: ${t.slice(0, 180)}` };
    }
    const body = JSON.parse(t) as {
      access_token?: string;
      refresh_token?: string;
      expires_in?: number;
    };
    if (!body.access_token) return { ok: false as const, error: "Claude não devolveu access token" };
    return {
      ok: true as const,
      tokens: {
        access: body.access_token,
        refresh: body.refresh_token ?? "",
        expiresAt: Date.now() + (body.expires_in ?? 3600) * 1000,
      },
    };
  });

export const claudeRefresh = createServerFn({ method: "POST" })
  .validator((input: { refresh: string }) => input)
  .handler(async ({ data }) => {
    const res = await fetch(CLAUDE_TOKEN, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        grant_type: "refresh_token",
        client_id: CLAUDE_CLIENT_ID,
        refresh_token: data.refresh,
      }),
    });
    const t = await res.text();
    if (!res.ok) return { ok: false as const, error: `Claude refresh ${res.status}` };
    const body = JSON.parse(t) as {
      access_token?: string;
      refresh_token?: string;
      expires_in?: number;
    };
    if (!body.access_token) return { ok: false as const, error: "refresh sem token" };
    return {
      ok: true as const,
      tokens: {
        access: body.access_token,
        refresh: body.refresh_token || data.refresh,
        expiresAt: Date.now() + (body.expires_in ?? 3600) * 1000,
      },
    };
  });

export const openaiStartDevice = createServerFn({ method: "POST" })
  .validator(() => ({}))
  .handler(async () => {
    const res = await fetch(OPENAI_USERCODE, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ client_id: OPENAI_CLIENT_ID }),
    });
    const t = await res.text();
    if (!res.ok) {
      return {
        ok: false as const,
        error: `device ${res.status}. Ative Device code em ChatGPT → Ajustes → Segurança.`,
      };
    }
    const body = JSON.parse(t) as {
      user_code?: string;
      usercode?: string;
      device_auth_id?: string;
      interval?: number;
    };
    const userCode = body.user_code || body.usercode;
    if (!userCode || !body.device_auth_id) {
      return { ok: false as const, error: "resposta incompleta do device auth" };
    }
    return {
      ok: true as const,
      userCode,
      deviceAuthId: body.device_auth_id,
      interval: Math.max(2, body.interval ?? 5),
      verificationUrl: OPENAI_VERIFY,
    };
  });

export const openaiPollDevice = createServerFn({ method: "POST" })
  .validator((input: { deviceAuthId: string; userCode: string }) => input)
  .handler(async ({ data }) => {
    const poll = await fetch(OPENAI_POLL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        device_auth_id: data.deviceAuthId,
        user_code: data.userCode,
      }),
    });
    if (poll.status === 403 || poll.status === 404) {
      return { ok: true as const, pending: true as const };
    }
    const raw = await poll.text();
    if (!poll.ok) return { ok: false as const, error: `device poll ${poll.status}` };
    const grant = JSON.parse(raw) as {
      authorization_code?: string;
      code_verifier?: string;
    };
    if (!grant.authorization_code || !grant.code_verifier) {
      return { ok: true as const, pending: true as const };
    }
    const tokenRes = await fetch(OPENAI_TOKEN, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        client_id: OPENAI_CLIENT_ID,
        code: grant.authorization_code,
        code_verifier: grant.code_verifier,
        redirect_uri: OPENAI_DEVICE_REDIRECT,
      }).toString(),
    });
    const tt = await tokenRes.text();
    if (!tokenRes.ok) return { ok: false as const, error: `token ${tokenRes.status}` };
    const body = JSON.parse(tt) as {
      access_token?: string;
      refresh_token?: string;
      expires_in?: number;
      id_token?: string;
    };
    if (!body.access_token) return { ok: false as const, error: "ChatGPT não devolveu token" };
    return {
      ok: true as const,
      pending: false as const,
      tokens: {
        access: body.access_token,
        refresh: body.refresh_token ?? "",
        expiresAt: Date.now() + (body.expires_in ?? 3600) * 1000,
        accountId: chatgptAccountId(body.access_token, body.id_token),
      },
    };
  });

export const openaiRefresh = createServerFn({ method: "POST" })
  .validator((input: { refresh: string }) => input)
  .handler(async ({ data }) => {
    const res = await fetch(OPENAI_TOKEN, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "refresh_token",
        refresh_token: data.refresh,
        client_id: OPENAI_CLIENT_ID,
      }).toString(),
    });
    const t = await res.text();
    if (!res.ok) return { ok: false as const, error: `openai refresh ${res.status}` };
    const body = JSON.parse(t) as {
      access_token?: string;
      refresh_token?: string;
      expires_in?: number;
      id_token?: string;
    };
    if (!body.access_token) return { ok: false as const, error: "refresh sem token" };
    return {
      ok: true as const,
      tokens: {
        access: body.access_token,
        refresh: body.refresh_token || data.refresh,
        expiresAt: Date.now() + (body.expires_in ?? 3600) * 1000,
        accountId: chatgptAccountId(body.access_token, body.id_token),
      },
    };
  });
