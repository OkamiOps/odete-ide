import { useWorkspace } from "./store";
import { fileDiff } from "./diff";

function unquote(s: string) {
  if (
    (s.startsWith('"') && s.endsWith('"')) ||
    (s.startsWith("'") && s.endsWith("'"))
  ) {
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

export function runShell(raw: string): string {
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
          "npm i   npx vite   clear   reset",
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
      case "cat": {
        const p = resolve(w.cwd, args[0]);
        const body = w.readFile(p);
        if (body === undefined) {
          err = true;
          out = `cat: ${p}: não existe`;
        } else out = body;
        break;
      }
      case "echo":
        out = args.join(" ");
        break;
      case "mkdir":
        out = `ok ${resolve(w.cwd, args[0])}/`;
        break;
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
            : Object.keys({ ...w.files, ...(head ?? {}) }).filter((k) => w.files[k] !== head?.[k]);
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
        }
        else if (sub === "add") {
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
          const r = w.commit(msg);
          if (r.startsWith("[")) out = r;
          else {
            err = true;
            out = r;
          }
        } else if (sub === "push") out = w.gitPush();
        else if (sub === "pull") out = w.gitPull();
        else if (sub === "fetch") out = w.gitFetch();
        else if (sub === "sync") out = w.gitSync();
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
            out = "clonando em segundo plano…";
            void (async () => {
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
                });
                w.termPrint("ok", `ok ${r.remote}  ${Object.keys(r.files).length} arquivos`);
              } catch (e) {
                w.termPrint("err", e instanceof Error ? e.message : "clone falhou");
              }
            })();
          }
        } else {
          err = true;
          out = "git: comando não suportado neste sandbox";
        }
        break;
      }
      case "npm": {
        if (args[0] === "i" || args[0] === "install") {
          out = [
            "added 12 packages, and audited 13 packages in 1s",
            "sandbox colo — sem binários nativos (sharp, etc. não entram)",
          ].join("\n");
        } else if (args[0] === "run" && args[1] === "dev") {
          out = "Local:  iframe preview  (abre a aba Preview)";
        } else out = "npm — use: npm i  |  npm run dev";
        break;
      }
      case "npx":
      case "vite":
        out = "VITE v7 ready — abre a aba Preview para ver index.html";
        break;
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
