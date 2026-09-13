import { useWorkspace } from "./store";
import { fileDiff } from "./diff";
import { npmInstall, npmRunScript } from "./npm";
import { remoteFetch, remotePull, remotePush, remoteSync } from "./git-remote";
import { useChrome } from "./chrome";
import { isNoisePath } from "./ignore";

function unquote(s: string) {
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    return s.slice(1, -1);
  }
  return s;
}

function tokenize(input: string): string[] {
  const out: string[] = [];
  const re = /"([^"]*)"|'([^']*)'|\S+/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(input))) {
    out.push(m[1] ?? m[2] ?? m[0]);
  }
  return out;
}

function resolve(cwd: string, path?: string) {
  if (!path || path === ".") return cwd;
  if (path.startsWith("/")) return path.replace(/^\/+/, "");
  if (!cwd) return path;
  if (path === "..") {
    const i = cwd.lastIndexOf("/");
    return i < 0 ? "" : cwd.slice(0, i);
  }
  return `${cwd}/${path}`.replace(/\/+/g, "/");
}

export function isReadShell(raw: string) {
  const cmd = raw.trim().split(/\s+/)[0] ?? "";
  if (["ls", "cat", "pwd", "echo", "help", "clear", "head", "wc"].includes(cmd)) return true;
  if (cmd !== "git") return false;
  const sub = raw.trim().split(/\s+/)[1] ?? "";
  return ["status", "log", "diff", "blame", "branch"].includes(sub);
}

export function runShell(raw: string): string {
  void runShellAsync(raw);
  return "";
}

export async function runShellAsync(raw: string): Promise<string> {
  const line = raw.trim();
  if (!line) return "";
  const w = useWorkspace.getState();
  w.termPrint("in", `$ ${line}`);

  const argv = tokenize(line);
  const cmd = argv[0] ?? "";
  const args = argv.slice(1).map(unquote);

  let out = "";
  let err = false;

  try {
    switch (cmd) {
      case "help":
        out = [
          "ls  cat  pwd  cd  mkdir  touch  rm  echo",
          "git status | log | diff | add | restore | commit -m | pull | push | fetch | sync | clone",
          "git branch | checkout | stash | stash pop | blame",
          "npm i [pkg] [-D]   pnpm i   npm run [script]   npm ls   node [arquivo]   clear",
          "npm run dev | start | start:dev | build  → Node neste iPad (tela cheia / origem isolada)",
        ].join("\n");
        break;
      case "clear":
        w.termClear();
        return "";
      case "pwd":
        out = "/" + (w.cwd || "");
        break;
      case "cd": {
        const dest = resolve(w.cwd, args[0] ?? "");
        if (dest && w.listDir(dest).length === 0 && !w.readFile(dest)) {
          err = true;
          out = `cd: ${dest}: não encontrado`;
        } else {
          w.setCwd(dest);
          out = dest ? `/${dest}` : "/";
        }
        break;
      }
      case "ls": {
        const dest = resolve(w.cwd, args[0]);
        const names = w.listDir(dest);
        out = names.join("  ") || "(vazio)";
        break;
      }
      case "cat":
      case "head": {
        const p = resolve(w.cwd, args[0]);
        const body = w.readFile(p);
        if (body === undefined) {
          err = true;
          out = `${cmd}: ${p}: não existe`;
        } else out = cmd === "head" ? body.split("\n").slice(0, 20).join("\n") : body;
        break;
      }
      case "echo":
        out = args.join(" ");
        break;
      case "mkdir": {
        const p = resolve(w.cwd, args[0]);
        if (!p) {
          err = true;
          out = "mkdir: caminho?";
        } else out = w.mkdir(p);
        break;
      }
      case "touch": {
        const p = resolve(w.cwd, args[0]);
        if (!p) {
          err = true;
          out = "touch: caminho?";
        } else {
          if (w.readFile(p) === undefined) w.writeFile(p, "");
          out = p;
        }
        break;
      }
      case "rm": {
        const p = resolve(w.cwd, args[0]);
        const e = w.deleteFile(p);
        if (e) {
          err = true;
          out = e;
        } else out = `removido ${p}`;
        break;
      }
      case "git": {
        const sub = args[0];
        if (sub === "status") out = w.gitStatus();
        else if (sub === "log") out = w.gitLog();
        else if (sub === "diff") {
          const head = w.commits[w.commits.length - 1]?.files;
          const target = args[1] ? resolve(w.cwd, args[1]) : "";
          const paths = target
            ? [target]
            : Object.keys({ ...w.files, ...(head ?? {}) }).filter(
                (k) => !isNoisePath(k) && w.files[k] !== head?.[k],
              );
          if (!paths.length) out = "working tree clean";
          else {
            out = paths
              .map((p) => {
                const rows = fileDiff(p, w.files, head);
                const body = rows
                  .filter((r) => r.kind !== "eq")
                  .map((r) => `${r.kind === "add" ? "+" : "-"}${r.text}`)
                  .join("\n");
                return `--- a/${p}\n+++ b/${p}\n${body}`;
              })
              .join("\n\n");
          }
        } else if (sub === "add") {
          if (!args[1] || args[1] === "." || args[1] === "-A") w.gitStageAll();
          else w.gitStage(resolve(w.cwd, args[1]));
          out = "ok";
        } else if (sub === "restore") {
          const p = args.includes("--staged")
            ? args.filter((a) => a !== "--staged" && a !== "restore")[0]
            : args[1];
          if (args.includes("--staged")) {
            if (!p || p === ".") w.gitUnstageAll();
            else w.gitUnstage(resolve(w.cwd, p));
            out = "unstaged";
          } else {
            out = !p || p === "." ? w.gitDiscardAll() : w.gitDiscard(resolve(w.cwd, p));
          }
        } else if (sub === "reset") {
          out = w.gitUndoCommit();
        } else if (sub === "commit") {
          const mi = args.findIndex((a) => a === "-m");
          const msg = mi >= 0 ? args.slice(mi + 1).join(" ") : "";
          const r = w.commit(msg, args.includes("-a") || args.includes("-A"));
          if (r.startsWith("[")) out = r;
          else {
            err = true;
            out = r;
          }
        } else if (sub === "push") out = await remotePush(args.includes("-m") ? args[args.indexOf("-m") + 1] : "colo push", (m) => w.termPrint("out", m));
        else if (sub === "pull") out = await remotePull();
        else if (sub === "fetch") out = await remoteFetch();
        else if (sub === "sync") out = await remoteSync();
        else if (sub === "branch") {
          if (args[1] && args[1] !== "-a") out = w.gitBranchCreate(args[1]);
          else out = w.gitBranchList().map((b) => (b === w.branch ? `* ${b}` : `  ${b}`)).join("\n");
        } else if (sub === "checkout" || sub === "switch") {
          const n = args[1] === "-b" ? args[2] : args[1];
          if (args[1] === "-b" && n) out = w.gitBranchCreate(n);
          else out = w.gitCheckout(n ?? "");
        } else if (sub === "stash") {
          out = args[1] === "pop" || args[1] === "apply" ? w.gitStashPop() : w.gitStash();
        } else if (sub === "blame") {
          const p = resolve(w.cwd, args[1] ?? w.openPath);
          const rows = w.gitBlame(p);
          out = rows.slice(0, 80).map((r) => `${r.id} (${r.message.slice(0, 24)}) ${r.line} ${r.text}`).join("\n");
        } else if (sub === "clone") {
          const target = args[1];
          if (!target) {
            err = true;
            out = "git clone <owner/repo|url>";
          } else {
            out = "clonando…";
            try {
              const { githubClone } = await import("@/lib/github/api");
              const { useProjects } = await import("./projects");
              const token = useProjects.getState().github?.token;
              const r = await githubClone(target, token, (m) => w.termPrint("out", m));
              w.loadProject({
                id: `gh-${r.remote}`,
                name: r.name,
                files: r.files,
                remote: r.remote,
                branch: r.branch,
                message: `clone ${r.remote}`,
                pushed: true,
              });
              out = `ok ${r.remote}  ${Object.keys(r.files).length} arquivos`;
            } catch (e) {
              err = true;
              out = e instanceof Error ? e.message : "clone falhou";
            }
          }
        } else {
          err = true;
          out = "git: comando não suportado neste sandbox";
        }
        break;
      }
      case "wc": {
        const p = resolve(w.cwd, args[0]);
        const body = w.readFile(p);
        if (body === undefined) {
          err = true;
          out = `wc: ${p}: não existe`;
        } else {
          const lines = body.split("\n").length;
          const words = body.trim() ? body.trim().split(/\s+/).length : 0;
          out = `${lines} ${words} ${body.length} ${p}`;
        }
        break;
      }
      case "pnpm":
      case "npm": {
        const sub = args[0];
        const rest = args.slice(1);
        if (sub === "i" || sub === "install" || sub === "add") {
          const { nodeInstall } = await import("./node-runtime");
          const wc = await nodeInstall(rest, (m) => w.termPrint("out", m), cmd);
          if (wc.used) out = wc.out;
          else {
            const { nodeUnsupportedReason } = await import("./node-runtime");
            const why = nodeUnsupportedReason();
            if (why) w.termPrint("out", why);
            out = await npmInstall(rest, (m) => w.termPrint("out", m));
          }
        } else if (sub === "ls") {
          const { nodeSpawn } = await import("./node-runtime");
          const wcLs = await nodeSpawn(cmd === "pnpm" ? "pnpm" : "npm", ["ls", "--depth=0"], (m) => w.termPrint("out", m));
          if (wcLs.used) {
            out = wcLs.out;
            err = wcLs.code !== 0;
            break;
          }
          const { parseLock } = await import("./npm-lock");
          const lock = parseLock(w.readFile("package-lock.colo.json"));
          const keys = Object.keys(lock);
          out = keys.length ? keys.map((k) => `${k}@${lock[k]}`).join("\n") : "(lock vazio — npm i)";
        } else if (sub === "run" || sub === "start" || sub === "dev") {
          const name = sub === "run" ? args[1] : sub;
          if (!name) {
            out = npmRunScript(undefined).out;
            break;
          }
          const { nodeRunScript } = await import("./node-runtime");
          const wc = await nodeRunScript(name, (m) => w.termPrint("out", m), cmd);
          if (wc.used) {
            if (wc.openPreview) {
              useChrome.getState().setCenter("preview");
              useChrome.getState().setMobile("preview");
            }
            out = wc.out;
            break;
          }
          const r = npmRunScript(name);
          if (r.openPreview) {
            useChrome.getState().setCenter("preview");
            useChrome.getState().setMobile("preview");
          }
          if (r.boot === "nest" || r.boot === "next") {
            const { bootProject } = await import("./runtime");
            const b = await bootProject(w.files);
            out = `${r.out}\n${b.out}`;
          } else out = r.out;
        } else out = `${cmd} — use: ${cmd} i [pkg]  |  ${cmd} run [script]  |  ${cmd} ls`;
        break;
      }
      case "npx":
      case "vite": {
        const tool = cmd === "npx" ? args[0] : "vite";
        if (cmd === "npx" && (tool === "tsx" || tool === "ts-node")) {
          const { nodeExecFile } = await import("./node-runtime");
          const wc = await nodeExecFile(resolve(w.cwd, args[1] ?? ""), args.slice(2), (m) => w.termPrint("out", m));
          if (wc.used) {
            out = wc.out;
            err = wc.code !== 0;
            break;
          }
          const { runNode } = await import("./runtime");
          out = await runNode(resolve(w.cwd, args[1] ?? ""), args.slice(2), w.files);
          break;
        }
        const { nodeRunScript } = await import("./node-runtime");
        const wc = await nodeRunScript("dev", (m) => w.termPrint("out", m), cmd);
        if (wc.used) {
          if (wc.openPreview) {
            useChrome.getState().setCenter("preview");
            useChrome.getState().setMobile("preview");
          }
          out = wc.out;
          break;
        }
        if (cmd === "npx" && (tool === "next" || tool === "nest" || tool === "@nestjs/cli")) {
          const r = npmRunScript("dev");
          if (r.openPreview) {
            useChrome.getState().setCenter("preview");
            useChrome.getState().setMobile("preview");
          }
          const { bootProject } = await import("./runtime");
          const b = await bootProject(w.files);
          out = `${r.out}\n${b.out}`;
          break;
        }
        const r = npmRunScript("dev");
        if (r.openPreview) {
          useChrome.getState().setCenter("preview");
          useChrome.getState().setMobile("preview");
        }
        out = r.out;
        break;
      }
      case "node":
      case "tsx":
      case "ts-node": {
        const { nodeExecFile } = await import("./node-runtime");
        const file = resolve(w.cwd, args[0] ?? "index.js");
        const wc = await nodeExecFile(file, args.slice(1), (m) => w.termPrint("out", m));
        if (wc.used) {
          out = wc.out;
          err = wc.code !== 0;
          break;
        }
        const { runNode } = await import("./runtime");
        out = await runNode(file, args.slice(1), w.files);
        break;
      }
      case "reset":
        w.resetWorkspace();
        out = "workspace restaurado";
        break;
      default:
        err = true;
        out = `${cmd}: comando não encontrado. digite help`;
    }
  } catch (e) {
    err = true;
    out = e instanceof Error ? e.message : "falha";
  }

  if (out) w.termPrint(err ? "err" : "out", out);
  return err ? `ERROR\n${out}` : out;
}
