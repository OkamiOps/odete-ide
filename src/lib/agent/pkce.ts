function b64url(bytes: Uint8Array) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

export async function makePkce() {
  const raw = crypto.getRandomValues(new Uint8Array(32));
  const verifier = b64url(raw);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  const challenge = b64url(new Uint8Array(digest));
  const state = b64url(crypto.getRandomValues(new Uint8Array(32)));
  return { verifier, challenge, state };
}

export const CLAUDE_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
export const CLAUDE_REDIRECT = "https://platform.claude.com/oauth/code/callback";
export const CLAUDE_SCOPE = [
  "user:profile",
  "user:inference",
  "user:sessions:claude_code",
  "user:mcp_servers",
  "user:file_upload",
].join(" ");

export function claudeAuthorizeUrl(challenge: string, state: string) {
  const u = new URL("https://claude.com/cai/oauth/authorize");
  u.searchParams.set("client_id", CLAUDE_CLIENT_ID);
  u.searchParams.set("response_type", "code");
  u.searchParams.set("redirect_uri", CLAUDE_REDIRECT);
  u.searchParams.set("scope", CLAUDE_SCOPE);
  u.searchParams.set("code_challenge", challenge);
  u.searchParams.set("code_challenge_method", "S256");
  u.searchParams.set("state", state);
  return u.toString();
}

export function parseClaudeCode(raw: string) {
  const t = raw.trim().replace(/^https?:\/\/[^\s#]+(?:[?&]code=)/i, "");
  const hash = t.includes("#") ? t : t.replace(/[?&]state=/, "#");
  const [code, state] = hash.split("#");
  return { code: (code ?? "").trim(), state: (state ?? "").trim() };
}
