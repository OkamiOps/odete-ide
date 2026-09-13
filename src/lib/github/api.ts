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

const SKIP_HEAVY =
  /\.(mp4|mp3|wav|ogg|zip|gz|tgz|7z|rar|exe|dmg|iso|lockb|DS_Store)$/i;
const SKIP_DIR = /(^|\/)(node_modules|\.git|dist|build|\.next|coverage|vendor)(\/|$)/;
const MAX_FILE = 1_200_000;
const MAX_FILES = 4000;

export const BIN_PREFIX = "bin:";

export function isBinFile(s: string) {
  return s.startsWith(BIN_PREFIX);
}

function mimeOf(path: string) {
  const ext = (path.split(".").pop() ?? "").toLowerCase();
  const map: Record<string, string> = {
    png: "image/png",
    jpg: "image/jpeg",
    jpeg: "image/jpeg",
    gif: "image/gif",
    webp: "image/webp",
    ico: "image/x-icon",
    bmp: "image/bmp",
    woff: "font/woff",
    woff2: "font/woff2",
    ttf: "font/ttf",
    otf: "font/otf",
    pdf: "application/pdf",
    wasm: "application/wasm",
    bin: "application/octet-stream",
  };
  return map[ext] || "application/octet-stream";
}

function packBin(path: string, b64: string) {
  return `${BIN_PREFIX}${mimeOf(path)};${b64}`;
}

export function unpackBin(s: string): { mime: string; b64: string } | null {
  if (!isBinFile(s)) return null;
  const rest = s.slice(BIN_PREFIX.length);
  const i = rest.indexOf(";");
  if (i < 0) return { mime: "application/octet-stream", b64: rest };
  return { mime: rest.slice(0, i), b64: rest.slice(i + 1) };
}

export function parseRepo(input: string) {
  const raw = input.trim().replace(/\.git$/, "");
  const tree = raw.match(/github\.com[/:]([^/]+)\/([^/#?]+)(?:\/(?:tree|blob)\/([^?#]+))?/i);
  if (tree) {
    const branch = (tree[3] || "").replace(/\/$/, "").replace(/^blob\/|tree\//, "");
    return { owner: tree[1]!, repo: tree[2]!.replace(/\.git$/, ""), branch };
  }
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

async function ghPages<T>(url: string, token?: string): Promise<T[]> {
  const out: T[] = [];
  let next: string | null = url;
  let n = 0;
  while (next && n < 12) {
    const r = await fetch(next, { headers: headers(token) });
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
    const chunk = JSON.parse(text) as T[];
    out.push(...chunk);
    const link = r.headers.get("link") || "";
    const m = /<([^>]+)>;\s*rel="next"/.exec(link);
    next = m?.[1] ?? null;
    n += 1;
    if (chunk.length < 100) break;
  }
  return out;
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
  type Raw = {
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
  };
  const url = owner
    ? `https://api.github.com/orgs/${encodeURIComponent(owner)}/repos?sort=updated&per_page=100&type=all`
    : "https://api.github.com/user/repos?sort=updated&per_page=100&affiliation=owner,collaborator,organization_member";
  const list = await ghPages<Raw>(url, token);
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

function bytesFromB64(content: string) {
  const bin = atob(content.replace(/\n/g, ""));
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function isTextBytes(bytes: Uint8Array) {
  const n = Math.min(bytes.length, 800);
  for (let i = 0; i < n; i++) if (bytes[i] === 0) return false;
  return true;
}

function parseLfsPointer(text: string) {
  if (!text.startsWith("version https://git-lfs.github.com/spec/v1")) return null;
  const oid = /oid sha256:([a-f0-9]{64})/.exec(text)?.[1];
  const size = Number(/size (\d+)/.exec(text)?.[1] || 0);
  if (!oid || !size) return null;
  return { oid, size };
}

async function lfsDownload(owner: string, repo: string, token: string, oid: string, size: number) {
  const r = await fetch(`https://github.com/${owner}/${repo}.git/info/lfs/objects/batch`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.git-lfs+json",
      "Content-Type": "application/vnd.git-lfs+json",
    },
    body: JSON.stringify({ operation: "download", transfers: ["basic"], objects: [{ oid, size }] }),
  });
  if (!r.ok) throw new Error(`LFS ${r.status}`);
  const j = (await r.json()) as {
    objects?: Array<{ actions?: { download?: { href?: string; header?: Record<string, string> } } }>;
  };
  const dl = j.objects?.[0]?.actions?.download;
  if (!dl?.href) throw new Error("LFS sem download");
  const got = await fetch(dl.href, { headers: dl.header || {} });
  if (!got.ok) throw new Error(`LFS blob ${got.status}`);
  const buf = new Uint8Array(await got.arrayBuffer());
  let bin = "";
  buf.forEach((b) => {
    bin += String.fromCharCode(b);
  });
  return btoa(bin);
}

function fileToBytes(content: string) {
  const bin = unpackBin(content);
  if (bin) return bytesFromB64(bin.b64);
  return new TextEncoder().encode(content);
}

function fileToB64(content: string) {
  const bin = unpackBin(content);
  if (bin) return bin.b64;
  return b64(content);
}

async function gitBlobSha(bytes: Uint8Array) {
  const header = new TextEncoder().encode(`blob ${bytes.length}\0`);
  const buf = new Uint8Array(header.length + bytes.length);
  buf.set(header);
  buf.set(bytes, header.length);
  const hash = await crypto.subtle.digest("SHA-1", buf);
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0")).join("");
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
  const zipped = await cloneViaZip(owner, slug, branch, token, onProgress);
  if (zipped && Object.keys(zipped).length) {
    onProgress?.(`${Object.keys(zipped).length} arquivos`);
    return { name: info.name, branch, remote: info.full_name, files: zipped };
  }
  return cloneViaTree(owner, slug, branch, info, token, onProgress);
}

async function cloneViaZip(
  owner: string,
  slug: string,
  branch: string,
  token: string | undefined,
  onProgress?: (msg: string) => void,
): Promise<Record<string, string> | null> {
  try {
    onProgress?.("baixando zip do GitHub…");
    const url = token
      ? `https://api.github.com/repos/${owner}/${slug}/zipball/${encodeURIComponent(branch)}`
      : `https://codeload.github.com/${owner}/${slug}/zip/refs/heads/${encodeURIComponent(branch)}`;
    const r = await fetch(url, token ? { headers: headers(token) } : undefined);
    if (!r.ok) return null;
    const buf = await r.arrayBuffer();
    if (buf.byteLength > 70_000_000) return null;
    const { unzipRaw } = await import("@/lib/workspace/zip");
    const raw = await unzipRaw(buf);
    const files: Record<string, string> = {};
    const keys = Object.keys(raw);
    if (keys.length > MAX_FILES) onProgress?.(`${keys.length} arquivos — puxando ${MAX_FILES}`);
    for (const [full, bytes] of Object.entries(raw)) {
      const parts = full.split("/").filter(Boolean);
      if (parts.length < 2) continue;
      const path = parts.slice(1).join("/");
      if (!path || SKIP_DIR.test(path) || SKIP_HEAVY.test(path)) continue;
      if (bytes.length > MAX_FILE) continue;
      if (Object.keys(files).length >= MAX_FILES) break;
      if (isTextBytes(bytes)) files[path] = new TextDecoder("utf-8", { fatal: false }).decode(bytes);
      else {
        let bin = "";
        bytes.forEach((b) => {
          bin += String.fromCharCode(b);
        });
        files[path] = packBin(path, btoa(bin));
      }
    }
    return Object.keys(files).length ? files : null;
  } catch {
    return null;
  }
}

async function cloneViaTree(
  owner: string,
  slug: string,
  branch: string,
  info: { name: string; full_name: string },
  token: string | undefined,
  onProgress?: (msg: string) => void,
): Promise<CloneResult> {
  onProgress?.(`árvore ${branch}…`);
  const tree = await gh<{ tree: { path: string; type: string; size?: number }[] }>(
    `https://api.github.com/repos/${owner}/${slug}/git/trees/${encodeURIComponent(branch)}?recursive=1`,
    token,
  );
  const blobs = tree.tree.filter(
    (t) =>
      t.type === "blob" &&
      t.path &&
      !SKIP_HEAVY.test(t.path) &&
      !SKIP_DIR.test(t.path) &&
      (t.size ?? 0) < MAX_FILE,
  );
  const picked = blobs.slice(0, MAX_FILES);
  if (blobs.length > MAX_FILES) onProgress?.(`${blobs.length} blobs — puxando ${MAX_FILES}`);
  if (!picked.length) throw new Error("nenhum arquivo nesse repo");
  const files: Record<string, string> = {};
  let done = 0;
  const queue = [...picked];
  async function worker() {
    while (queue.length) {
      const item = queue.shift()!;
      const path = item.path;
      try {
        let b64content = "";
        if (token) {
          const body = await gh<{ encoding?: string; content?: string }>(
            `https://api.github.com/repos/${owner}/${slug}/contents/${encodeURIComponent(path).replaceAll("%2F", "/")}?ref=${encodeURIComponent(branch)}`,
            token,
          );
          if (body.encoding === "base64" && body.content) b64content = body.content.replace(/\n/g, "");
        } else {
          const raw = await fetch(
            `https://raw.githubusercontent.com/${owner}/${slug}/${encodeURIComponent(branch)}/${path}`,
          );
          if (!raw.ok) continue;
          const buf = new Uint8Array(await raw.arrayBuffer());
          let bin = "";
          buf.forEach((b) => {
            bin += String.fromCharCode(b);
          });
          b64content = btoa(bin);
        }
        if (!b64content) continue;
        const bytes = bytesFromB64(b64content);
        if (isTextBytes(bytes)) {
          const text = new TextDecoder("utf-8", { fatal: false }).decode(bytes);
          const lfs = token ? parseLfsPointer(text) : null;
          if (lfs && lfs.size < MAX_FILE) {
            try {
              const raw = await lfsDownload(owner, slug, token!, lfs.oid, lfs.size);
              const lb = bytesFromB64(raw);
              files[path] = isTextBytes(lb)
                ? new TextDecoder("utf-8", { fatal: false }).decode(lb)
                : packBin(path, raw);
            } catch {
              files[path] = text;
            }
          } else {
            files[path] = text;
          }
        } else {
          files[path] = packBin(path, b64content);
        }
      } catch {
        /* skip */
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
  deleted: string[] = [],
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
  const commit = await gh<{ tree: { sha: string } }>(
    `https://api.github.com/repos/${owner}/${repo}/git/commits/${parent}`,
    token,
  );
  const baseTree = commit.tree.sha;
  const remoteTree = await gh<{ tree: { path: string; type: string; sha: string; mode: string }[] }>(
    `https://api.github.com/repos/${owner}/${repo}/git/trees/${baseTree}?recursive=1`,
    token,
  );
  const remoteBlobs = new Map(
    remoteTree.tree.filter((t) => t.type === "blob").map((t) => [t.path, t.sha]),
  );

  const tree: Array<{ path: string; mode: "100644"; type: "blob"; sha: string | null }> = [];
  const entries = Object.entries(files).filter(([p]) => !SKIP_DIR.test(p) && !SKIP_HEAVY.test(p));
  let i = 0;
  for (const [path, content] of entries) {
    const bytes = fileToBytes(content);
    const sha = await gitBlobSha(bytes);
    if (remoteBlobs.get(path) === sha) continue;
    const blob = await ghWrite<{ sha: string }>(
      `https://api.github.com/repos/${owner}/${repo}/git/blobs`,
      token,
      "POST",
      { content: fileToB64(content), encoding: "base64" },
    );
    tree.push({ path, mode: "100644", type: "blob", sha: blob.sha });
    i += 1;
    if (i % 6 === 0) onProgress?.(`${i} blobs`);
  }
  for (const path of deleted) {
    if (!path || SKIP_DIR.test(path) || SKIP_HEAVY.test(path)) continue;
    if (!remoteBlobs.has(path)) continue;
    if (files[path] !== undefined) continue;
    tree.push({ path, mode: "100644", type: "blob", sha: null });
  }
  if (!tree.length) {
    onProgress?.("nada pra enviar");
    return parent.slice(0, 8);
  }
  onProgress?.("árvore…");
  const made = await ghWrite<{ sha: string }>(
    `https://api.github.com/repos/${owner}/${repo}/git/trees`,
    token,
    "POST",
    { base_tree: baseTree, tree },
  );
  const madeCommit = await ghWrite<{ sha: string }>(
    `https://api.github.com/repos/${owner}/${repo}/git/commits`,
    token,
    "POST",
    { message, tree: made.sha, parents: [parent] },
  );
  await ghWrite(
    `https://api.github.com/repos/${owner}/${repo}/git/refs/heads/${encodeURIComponent(branch)}`,
    token,
    "PATCH",
    { sha: madeCommit.sha },
  );
  return madeCommit.sha.slice(0, 8);
}

export async function githubPullTree(remote: string, branch: string, token?: string) {
  const spec = parseRepo(remote);
  if (!spec) throw new Error("remote inválido");
  const ref = branch || spec.branch || "main";
  return githubClone(`https://github.com/${spec.owner}/${spec.repo}/tree/${ref}`, token);
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
  const list = await gh<
    {
      number: number;
      title: string;
      html_url: string;
      draft: boolean;
      updated_at: string;
      user: { login: string };
      head: { ref: string };
    }[]
  >(`https://api.github.com/repos/${spec.owner}/${spec.repo}/pulls?state=open&per_page=20`, token);
  return list.map((p) => ({
    number: p.number,
    title: p.title,
    url: p.html_url,
    head: p.head.ref,
    draft: p.draft,
    user: p.user?.login ?? "",
    at: p.updated_at,
  }));
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

export async function githubMergePr(
  remote: string,
  token: string,
  number: number,
  method: "merge" | "squash" | "rebase" = "squash",
) {
  const spec = parseRepo(remote);
  if (!spec) throw new Error("remote inválido");
  return ghWrite<{ merged: boolean; sha: string; message: string }>(
    `https://api.github.com/repos/${spec.owner}/${spec.repo}/pulls/${number}/merge`,
    token,
    "PUT",
    { merge_method: method },
  );
}

export async function githubReviewPr(
  remote: string,
  token: string,
  number: number,
  event: "APPROVE" | "REQUEST_CHANGES" | "COMMENT" = "APPROVE",
  body = "ok pelo Colo",
) {
  const spec = parseRepo(remote);
  if (!spec) throw new Error("remote inválido");
  return ghWrite<{ id: number; html_url: string }>(
    `https://api.github.com/repos/${spec.owner}/${spec.repo}/pulls/${number}/reviews`,
    token,
    "POST",
    { event, body },
  );
}

export async function githubPrFiles(remote: string, token: string, number: number) {
  const spec = parseRepo(remote);
  if (!spec) throw new Error("remote inválido");
  const list = await gh<
    { filename: string; status: string; additions: number; deletions: number; patch?: string }[]
  >(`https://api.github.com/repos/${spec.owner}/${spec.repo}/pulls/${number}/files?per_page=100`, token);
  return list.map((f) => ({
    path: f.filename,
    status: f.status,
    add: f.additions,
    del: f.deletions,
    patch: f.patch ?? "",
  }));
}

export async function githubActions(remote: string, token: string) {
  const spec = parseRepo(remote);
  if (!spec) throw new Error("remote inválido");
  const data = await gh<{
    workflow_runs: {
      id: number;
      name: string;
      status: string;
      conclusion: string | null;
      html_url: string;
      head_branch: string;
      display_title: string;
      updated_at: string;
    }[];
  }>(`https://api.github.com/repos/${spec.owner}/${spec.repo}/actions/runs?per_page=15`, token);
  return data.workflow_runs.map((r) => ({
    id: r.id,
    name: r.name || r.display_title,
    status: r.status,
    conclusion: r.conclusion,
    url: r.html_url,
    branch: r.head_branch,
    at: r.updated_at,
  }));
}

export async function githubPrComments(remote: string, token: string, number: number) {
  const spec = parseRepo(remote);
  if (!spec) throw new Error("remote inválido");
  const list = await gh<{ user: { login: string }; body: string; created_at: string; path?: string }[]>(
    `https://api.github.com/repos/${spec.owner}/${spec.repo}/issues/${number}/comments?per_page=40`,
    token,
  );
  return list.map((c) => ({ user: c.user.login, body: c.body, at: c.created_at, path: c.path ?? "" }));
}

export async function githubCommentPr(remote: string, token: string, number: number, body: string) {
  const spec = parseRepo(remote);
  if (!spec) throw new Error("remote inválido");
  return ghWrite<{ html_url: string }>(
    `https://api.github.com/repos/${spec.owner}/${spec.repo}/issues/${number}/comments`,
    token,
    "POST",
    { body },
  );
}

export async function githubFork(remote: string, token: string) {
  const spec = parseRepo(remote);
  if (!spec) throw new Error("remote inválido");
  return ghWrite<{ full_name: string; html_url: string; default_branch: string }>(
    `https://api.github.com/repos/${spec.owner}/${spec.repo}/forks`,
    token,
    "POST",
    {},
  );
}
