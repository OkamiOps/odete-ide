import { githubPullTree, githubPushTree } from "@/lib/github/api";
import { useProjects } from "./projects";
import { useWorkspace } from "./store";

export function gitRemoteReady() {
  const remote = useWorkspace.getState().remote;
  const token = useProjects.getState().github?.token;
  return { remote, token, ok: Boolean(remote && token) };
}

export async function remotePush(message = "colo push", onNote?: (s: string) => void) {
  const { remote, token, ok } = gitRemoteReady();
  const w = useWorkspace.getState();
  if (!ok || !remote || !token) return `${w.gitPush()}\n(sem GitHub — só local)`;
  const sha = await githubPushTree(remote, w.branch || "main", w.files, token, message, onNote);
  w.gitPush();
  return `pushed ${sha}  ${remote}`;
}

export async function remotePull() {
  const { remote, token, ok } = gitRemoteReady();
  const w = useWorkspace.getState();
  if (!ok || !remote || !token) return `${w.gitPull()}\n(sem GitHub — só local)`;
  const r = await githubPullTree(remote, w.branch || "main", token);
  return w.mergeRemote(r.files);
}

export async function remoteFetch() {
  const { remote, token, ok } = gitRemoteReady();
  const w = useWorkspace.getState();
  if (!ok || !remote || !token) return `${w.gitFetch()}\n(sem GitHub — só local)`;
  const r = await githubPullTree(remote, w.branch || "main", token);
  return `fetch ${Object.keys(r.files).length} arquivos  ${remote}`;
}

export async function remoteSync(message = "colo sync") {
  const pull = await remotePull();
  if (pull.startsWith("error")) return pull;
  const push = await remotePush(message);
  return `${pull}\n${push}`;
}
