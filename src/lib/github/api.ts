export type GithubUser = { login: string; name: string | null; avatar: string };
export type GithubOrg = { login: string; avatar: string };
export type GithubRepo = {
  full: string;
  desc: string;
  updated: string;
  pushed: string;
  private: boolean;
  fork: boolean;
  archived: boolean;
  branch: string;
  language: string;
  stars: number;
  issues: number;
};
export type CloneResult = { name: string; branch: string; remote: string; files: Record<string, string> };

const SKIP =
  /\.(png|jpe?g|gif|webp|ico|bmp|woff2?|ttf|eot|otf|mp4|mp3|wav|ogg|zip|gz|tgz|wasm|pdf|exe|dmg|lockb|bin|DS_Store)$/i;
const SKIP_DIR = /(^|\/)(node_modules|\.git|dist|build|\.next|coverage|vendor)(\/|$)/;

export function parseRepo(input: string) {
  const raw = input.trim().replace(/\.git$/, "");
  const tree = raw.match(/github\.com[/:]([^/]+)\/([^/#?]+)(?:\/(?:tree|blob)\/([^/]+))?/i);
  if (tree) return { owner: tree[1]!, repo: tree[2]!, branch: tree[3] || "" };
  const short = raw.match(/^([\w.-]+)\/([\w.-]+)$/);
  if (short) return { owner: short[1]!, repo: short[2]!, branch: "" };
  return null;
}

function headers(token?: string): HeadersInit {
  const h: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
  };
  if (token) h.Authorization = `Bearer ${token}`;
  return h;
}

async function gh<T>(url: string, token?: string): Promise<T> {
  const r = await fetch(url, { headers: headers(token) });
  const text = await r.text();
  if (!r.ok) {
    let msg = `GitHub ${r.status}`;
    try {
      const j = JSON.parse(text) as { message?: string };
      if (j.message) msg = j.message;
    } catch {
      if (text) msg = text.slice(0, 180);
    }
    throw new Error(msg);
  }
  return JSON.parse(text) as T;
}

function decodeB64(content: string) {
  const bin = atob(content.replace(/\n/g, ""));
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
}

export async function githubUser(token: string) {
  const u = await gh<{ login: string; name: string | null; avatar_url: string }>("https://api.github.com/user", token);
  return { login: u.login, name: u.name, avatar: u.avatar_url } satisfies GithubUser;
}

export async function githubOrgs(token: string): Promise<GithubOrg[]> {
  const list = await gh<{ login: string; avatar_url: string }[]>(
    "https://api.github.com/user/orgs?per_page=100",
    token,
  );
  return list.map((o) => ({ login: o.login, avatar: o.avatar_url }));
}

export async function githubRepos(token: string, owner?: string): Promise<GithubRepo[]> {
  const url = owner
    ? `https://api.github.com/orgs/${encodeURIComponent(owner)}/repos?sort=updated&per_page=100&type=all`
    : "https://api.github.com/user/repos?sort=updated&per_page=100&affiliation=owner";
  const list = await gh<
    {
      full_name: string;
      description: string | null;
      updated_at: string;
      pushed_at: string | null;
      private: boolean;
      fork: boolean;
      archived: boolean;
      default_branch: string;
      language: string | null;
      stargazers_count: number;
      open_issues_count: number;
    }[]
  >(url, token);
  return list.map((r) => ({
    full: r.full_name,
    desc: r.description || "",
    updated: r.updated_at,
    pushed: r.pushed_at || r.updated_at,
    private: r.private,
    fork: r.fork,
    archived: r.archived,
    branch: r.default_branch || "main",
    language: r.language || "",
    stars: r.stargazers_count || 0,
    issues: r.open_issues_count || 0,
  }));
}

export async function githubClone(
  input: string,
  token?: string,
  onProgress?: (msg: string) => void,
): Promise<CloneResult> {
  const spec = parseRepo(input);
  if (!spec) throw new Error("repo inválido — usa owner/repo ou URL do GitHub");
  const { owner, repo: slug, branch: wanted } = spec;
  onProgress?.("lendo o repositório…");
  const info = await gh<{ default_branch: string; name: string; full_name: string }>(
    `https://api.github.com/repos/${owner}/${slug}`,
    token,
  );
  const branch = wanted || info.default_branch || "main";
  onProgress?.(`árvore ${branch}…`);
  const tree = await gh<{ tree: { path: string; type: string; size?: number }[] }>(
    `https://api.github.com/repos/${owner}/${slug}/git/trees/${encodeURIComponent(branch)}?recursive=1`,
    token,
  );
  const blobs = tree.tree.filter(
    (t) =>
      t.type === "blob" &&
      t.path &&
      !SKIP.test(t.path) &&
      !SKIP_DIR.test(t.path) &&
      (t.size ?? 0) < 120_000,
  );
  const picked = blobs.slice(0, 100);
  if (!picked.length) throw new Error("nenhum arquivo de texto nesse repo");
  const files: Record<string, string> = {};
  let done = 0;
  const queue = [...picked];
  async function worker() {
    while (queue.length) {
      const item = queue.shift()!;
      const path = item.path;
      try {
        if (token) {
          const body = await gh<{ encoding?: string; content?: string }>(
            `https://api.github.com/repos/${owner}/${slug}/contents/${encodeURIComponent(path).replaceAll("%2F", "/")}?ref=${encodeURIComponent(branch)}`,
            token,
          );
          if (body.encoding === "base64" && body.content) files[path] = decodeB64(body.content);
        } else {
          const raw = await fetch(
            `https://raw.githubusercontent.com/${owner}/${slug}/${encodeURIComponent(branch)}/${path}`,
          );
          if (raw.ok) files[path] = await raw.text();
        }
      } catch {
        /* skip file */
      }
      done += 1;
      if (done % 8 === 0) onProgress?.(`${done}/${picked.length} arquivos`);
    }
  }
  await Promise.all(Array.from({ length: 5 }, () => worker()));
  if (!Object.keys(files).length) throw new Error("não deu pra baixar os arquivos");
  onProgress?.(`${Object.keys(files).length} arquivos`);
  return { name: info.name, branch, remote: info.full_name, files };
}

async function ghWrite<T>(url: string, token: string, method: string, body: unknown): Promise<T> {
  const r = await fetch(url, {
    method,
    headers: { ...headers(token), "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await r.text();
  if (!r.ok) {
    let msg = `GitHub ${r.status}`;
    try {
      const j = JSON.parse(text) as { message?: string };
      if (j.message) msg = j.message;
    } catch {
      if (text) msg = text.slice(0, 180);
    }
    throw new Error(msg);
  }
  return text ? (JSON.parse(text) as T) : ({} as T);
}

function b64(s: string) {
  const bytes = new TextEncoder().encode(s);
  let bin = "";
  bytes.forEach((b) => {
    bin += String.fromCharCode(b);
  });
  return btoa(bin);
}

export async function githubPushTree(
  remote: string,
  branch: string,
  files: Record<string, string>,
  token: string,
  message: string,
  onProgress?: (msg: string) => void,
) {
  const spec = parseRepo(remote);
  if (!spec) throw new Error("remote inválido");
  const { owner, repo } = spec;
  onProgress?.("lendo HEAD…");
  const ref = await gh<{ object: { sha: string } }>(
    `https://api.github.com/repos/${owner}/${repo}/git/ref/heads/${encodeURIComponent(branch)}`,
    token,
  );
  const parent = ref.object.sha;
  const entries = Object.entries(files).slice(0, 80);
  const tree: { path: string; mode: "100644"; type: "blob"; sha: string }[] = [];
  let i = 0;
  for (const [path, content] of entries) {
    const blob = await ghWrite<{ sha: string }>(
      `https://api.github.com/repos/${owner}/${repo}/git/blobs`,
      token,
      "POST",
      { content: b64(content), encoding: "base64" },
    );
    tree.push({ path, mode: "100644", type: "blob", sha: blob.sha });
    i += 1;
    if (i % 6 === 0) onProgress?.(`${i}/${entries.length} blobs`);
  }
  onProgress?.("árvore…");
  const made = await ghWrite<{ sha: string }>(
    `https://api.github.com/repos/${owner}/${repo}/git/trees`,
    token,
    "POST",
    { tree },
  );
  const commit = await ghWrite<{ sha: string }>(
    `https://api.github.com/repos/${owner}/${repo}/git/commits`,
    token,
    "POST",
    { message, tree: made.sha, parents: [parent] },
  );
  await ghWrite(
    `https://api.github.com/repos/${owner}/${repo}/git/refs/heads/${encodeURIComponent(branch)}`,
    token,
    "PATCH",
    { sha: commit.sha },
  );
  return commit.sha.slice(0, 8);
}

export async function githubPullTree(remote: string, branch: string, token?: string) {
  const spec = parseRepo(remote);
  if (!spec) throw new Error("remote inválido");
  const ref = branch || spec.branch || "main";
  return githubClone(`https://github.com/${spec.owner}/${spec.repo}/tree/${encodeURIComponent(ref)}`, token);
}

export async function githubIssues(remote: string, token: string) {
  const spec = parseRepo(remote);
  if (!spec) throw new Error("remote inválido");
  const list = await gh<{ number: number; title: string; html_url: string; user: { login: string }; pull_request?: unknown }[]>(
    `https://api.github.com/repos/${spec.owner}/${spec.repo}/issues?state=open&per_page=20`,
    token,
  );
  return list
    .filter((i) => !i.pull_request)
    .map((i) => ({ number: i.number, title: i.title, url: i.html_url, user: i.user.login }));
}

export async function githubPulls(remote: string, token: string) {
  const spec = parseRepo(remote);
  if (!spec) throw new Error("remote inválido");
  const list = await gh<{ number: number; title: string; html_url: string; head: { ref: string } }[]>(
    `https://api.github.com/repos/${spec.owner}/${spec.repo}/pulls?state=open&per_page=20`,
    token,
  );
  return list.map((p) => ({ number: p.number, title: p.title, url: p.html_url, head: p.head.ref }));
}

export async function githubCreateRepo(token: string, name: string, owner?: string) {
  const slug = name
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80) || "colo-app";
  const url = owner
    ? `https://api.github.com/orgs/${encodeURIComponent(owner)}/repos`
    : "https://api.github.com/user/repos";
  const repo = await ghWrite<{ full_name: string; default_branch: string }>(url, token, "POST", {
    name: slug,
    private: true,
    auto_init: false,
  });
  return { remote: repo.full_name, branch: repo.default_branch || "main", slug };
}

export async function githubCreateIssue(remote: string, token: string, title: string, body: string) {
  const spec = parseRepo(remote);
  if (!spec) throw new Error("remote inválido");
  const issue = await ghWrite<{ html_url: string; number: number }>(
    `https://api.github.com/repos/${spec.owner}/${spec.repo}/issues`,
    token,
    "POST",
    { title, body },
  );
  return issue;
}

export async function githubCreatePr(
  remote: string,
  token: string,
  title: string,
  body: string,
  head: string,
  base: string,
) {
  const spec = parseRepo(remote);
  if (!spec) throw new Error("remote inválido");
  return ghWrite<{ html_url: string; number: number }>(
    `https://api.github.com/repos/${spec.owner}/${spec.repo}/pulls`,
    token,
    "POST",
    { title, body, head, base },
  );
}
