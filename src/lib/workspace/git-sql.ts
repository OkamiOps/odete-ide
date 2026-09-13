import { initSql, kvGet, kvSet, sqlQuery, useSql } from "./sql";
import { isNoisePath } from "./ignore";
import type { Commit, FileMap } from "./types";

function slimFiles(files: FileMap): FileMap {
  const out: FileMap = {};
  for (const [k, v] of Object.entries(files)) {
    if (k.startsWith("node_modules/") || k.includes("/node_modules/") || isNoisePath(k)) continue;
    out[k] = v;
  }
  return out;
}

function parseCommit(row: Record<string, unknown>): Commit | null {
  const id = String(row.id ?? "");
  if (!id) return null;
  let files: FileMap = {};
  if (typeof row.files === "string" && row.files) {
    try {
      files = JSON.parse(row.files) as FileMap;
    } catch {
      files = {};
    }
  } else if (row.files && typeof row.files === "object") {
    files = row.files as FileMap;
  }
  return {
    id,
    sha: typeof row.sha === "string" && row.sha ? row.sha : undefined,
    message: String(row.message ?? ""),
    at: Number(row.at) || Date.now(),
    files,
  };
}

export async function saveGit(projectId: string, commits: Commit[], origin: Commit | null) {
  await initSql();
  const slim = commits.slice(-12).map((c) => ({
    ...c,
    files: slimFiles(c.files),
  }));
  const originSlim = origin ? { ...origin, files: slimFiles(origin.files) } : null;
  if (useSql.getState().backend === "memory") {
    await kvSet(`git:${projectId}`, JSON.stringify({ commits: slim, origin: originSlim }));
    return;
  }
  await sqlQuery("DELETE FROM git_commits WHERE project_id = ?", [projectId]);
  for (const c of slim) {
    const keepFiles = slim.indexOf(c) >= slim.length - 4;
    await sqlQuery(
      "INSERT INTO git_commits(project_id, id, sha, message, at, files) VALUES(?, ?, ?, ?, ?, ?)",
      [projectId, c.id, c.sha ?? "", c.message, c.at, keepFiles ? JSON.stringify(c.files) : "{}"],
    );
  }
  await kvSet(`git-origin:${projectId}`, originSlim ? JSON.stringify(originSlim) : "");
}

export async function loadGit(projectId: string): Promise<{ commits: Commit[]; origin: Commit | null }> {
  await initSql();
  if (useSql.getState().backend === "memory") {
    const raw = await kvGet(`git:${projectId}`);
    if (!raw) return { commits: [], origin: null };
    try {
      const j = JSON.parse(raw) as { commits?: Commit[]; origin?: Commit | null };
      return { commits: j.commits ?? [], origin: j.origin ?? null };
    } catch {
      return { commits: [], origin: null };
    }
  }
  const originRaw = await kvGet(`git-origin:${projectId}`);
  let origin: Commit | null = null;
  if (originRaw) {
    try {
      origin = parseCommit(JSON.parse(originRaw) as Record<string, unknown>);
    } catch {
      origin = null;
    }
  }
  const rows = await sqlQuery(
    "SELECT id, sha, message, at, files FROM git_commits WHERE project_id = ? ORDER BY at ASC",
    [projectId],
  );
  const commits: Commit[] = [];
  for (const row of rows) {
    const c = parseCommit(row);
    if (!c || c.id === "__origin__") continue;
    commits.push(c);
  }
  return { commits, origin };
}
