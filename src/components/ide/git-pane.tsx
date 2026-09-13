import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import {
  Archive,
  Check,
  Download,
  EllipsisVertical,
  Eye,
  GitBranch,
  GitCommit,
  Layers,
  LoaderCircle,
  Minus,
  Plus,
  RefreshCw,
  RotateCcw,
  Sparkles,
  Trash2,
  Upload,
} from "lucide-react";
import { githubCreateIssue, githubCreatePr, githubFork, githubIssues, githubMergePr, githubPrFiles, githubPulls, githubPullTree, githubReviewPr, type CloneResult } from "@/lib/github/api";
import { remoteFetch, remotePull, remotePush, remoteSync } from "@/lib/workspace/git-remote";
import { PickList } from "@/components/ide/pick-list";
import { diffStats, fileStatus } from "@/lib/workspace/diff";
import { hunksOf } from "@/lib/workspace/hunks";
import { suggestCommit } from "@/lib/workspace/commit-ai";
import { useChrome } from "@/lib/workspace/chrome";
import { useNav } from "@/lib/workspace/nav";
import { useProjects } from "@/lib/workspace/projects";
import { useHub } from "@/lib/workspace/hub";
import { useWorkspace } from "@/lib/workspace/store";
import { isNoisePath } from "@/lib/workspace/ignore";

export function GitPane() {
  const files = useWorkspace((s) => s.files);
  const commits = useWorkspace((s) => s.commits);
  const staged = useWorkspace((s) => s.staged);
  const branch = useWorkspace((s) => s.branch);
  const origin = useWorkspace((s) => s.origin);
  const lastPushedId = useWorkspace((s) => s.lastPushedId);
  const stash = useWorkspace((s) => s.stash);
  const conflicts = useWorkspace((s) => s.conflicts);
  const remote = useWorkspace((s) => s.remote);
  const [msg, setMsg] = useState("");
  const [note, setNote] = useState("");
  const [branchName, setBranchName] = useState("");
  const [busy, setBusy] = useState(false);
  const [more, setMore] = useState(false);
  const [suggesting, setSuggesting] = useState(false);
  const msgRef = useRef<HTMLTextAreaElement>(null);
  const token = useProjects((s) => s.github?.token);
  const compareA = useHub((s) => s.compareA);
  const compareB = useHub((s) => s.compareB);
  const snaps = useWorkspace((s) => s.branchSnaps);
  const branches = useMemo(
    () => [...new Set([branch, ...Object.keys(snaps ?? {})])].sort(),
    [branch, snaps],
  );

  useEffect(() => {
    const el = msgRef.current;
    if (!el) return;
    el.style.height = "0px";
    el.style.height = `${Math.min(180, Math.max(56, el.scrollHeight))}px`;
  }, [msg]);

  const head = commits[commits.length - 1];
  const changed = useMemo(() => {
    if (!head) return Object.keys(files).filter((k) => !isNoisePath(k)).sort();
    const keys = new Set([...Object.keys(files), ...Object.keys(head.files)]);
    return [...keys].filter((k) => !isNoisePath(k) && files[k] !== head.files[k]).sort();
  }, [files, head]);

  const stagedSet = new Set(staged);
  const stagedFiles = changed.filter((p) => stagedSet.has(p));
  const unstaged = changed.filter((p) => !stagedSet.has(p));
  const ahead = (() => {
    if (!lastPushedId) return commits.length;
    const i = commits.findIndex((c) => c.id === lastPushedId);
    if (i < 0) return commits.length;
    return Math.max(0, commits.length - 1 - i);
  })();
  const behind = origin && !commits.some((c) => c.id === origin.id) ? 1 : 0;
  const w = () => useWorkspace.getState();
  const clean = changed.length === 0 && !conflicts.length;

  function run(fn: () => string) {
    setNote(fn());
  }

  async function gitHubOrLocal(kind: "fetch" | "pull" | "push" | "sync") {
    if (!remote || !token) {
      if (kind === "fetch") run(() => w().gitFetch());
      else if (kind === "pull") run(() => w().gitPull());
      else if (kind === "push") run(() => w().gitPush());
      else run(() => w().gitSync());
      if (!remote) setNote((n) => `${n}\n(sem remote — só local)`);
      else setNote((n) => `${n}\n(conecta o GitHub pra ir pra rede)`);
      return;
    }
    setBusy(true);
    try {
      if (kind === "fetch") setNote(await remoteFetch());
      else if (kind === "pull") setNote(await remotePull());
      else if (kind === "push") setNote(await remotePush(msg.trim() || "colo push", setNote));
      else setNote(await remoteSync(msg.trim() || "colo sync"));
    } catch (e) {
      setNote(e instanceof Error ? e.message : "git falhou");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="git">
      <div className="pane-hd">
        <span className="label">Git</span>
        {clean ? <em className="git-clean">limpo</em> : <em className="git-dirty">{changed.length} mudou</em>}
      </div>

      <div className="git-hero git-card">
        <div className="git-hero-row">
          <GitBranch size={16} />
          <PickList
            value={branch}
            options={branches.map((b) => ({ id: b, label: b }))}
            onChange={(id) => run(() => w().gitCheckout(id))}
            fill
            ariaLabel="branch"
          />
        </div>
        <div className="git-badges">
          <span className={ahead ? "is-on" : undefined} title="à frente">
            ↑{ahead}
          </span>
          <span className={behind ? "is-on" : undefined} title="atrás">
            ↓{behind}
          </span>
          {stash.length ? <span className="is-on">stash {stash.length}</span> : null}
          {remote ? <em title={remote}>{remote.replace(/^https?:\/\//, "").slice(0, 28)}</em> : <em>local</em>}
        </div>
        <div className="git-sync">
          <button type="button" disabled={busy} onClick={() => void gitHubOrLocal("fetch")}>
            <RefreshCw size={16} />
            fetch
          </button>
          <button type="button" className="is-accent" disabled={busy} onClick={() => void gitHubOrLocal("sync")}>
            <RefreshCw size={16} />
            sync
          </button>
          <button type="button" disabled={busy} onClick={() => void gitHubOrLocal("pull")}>
            <Download size={16} />
            pull
          </button>
          <button type="button" disabled={busy} onClick={() => void gitHubOrLocal("push")}>
            <Upload size={16} />
            push
          </button>
        </div>
      </div>

      <div className="git-commit git-card">
        <div className="git-msg-wrap">
          <textarea
            ref={msgRef}
            className="git-msg"
            rows={1}
            placeholder="Mensagem do commit"
            value={msg}
            onChange={(e) => setMsg(e.target.value)}
          />
          <button
            type="button"
            className="git-ai"
            title="Gerar mensagem com o agente"
            aria-label="Gerar mensagem com o agente"
            disabled={clean || suggesting}
            onClick={() => {
              setSuggesting(true);
              void suggestCommit(changed)
                .then((t) => {
                  if (t) setMsg(t);
                })
                .finally(() => setSuggesting(false));
            }}
          >
            {suggesting ? <LoaderCircle size={15} className="animate-spin" /> : <Sparkles size={15} />}
          </button>
        </div>
        <div className="git-commit-row">
          <button
            type="button"
            className="git-primary"
            disabled={!msg.trim() || !stagedFiles.length}
            onClick={() => {
              const r = w().commit(msg, false);
              setNote(r);
              if (r.startsWith("[")) setMsg("");
            }}
          >
            <Check size={14} />
            Commit
          </button>
          <button
            type="button"
            className="git-ghost"
            disabled={!msg.trim() || !stagedFiles.length || busy}
            onClick={() => {
              const r = w().commit(msg, false);
              if (r.startsWith("[")) {
                setMsg("");
                void gitHubOrLocal("push");
              } else setNote(r);
            }}
          >
            Push
          </button>
        </div>
        {note ? <p className="git-note">{note}</p> : null}
      </div>

      {conflicts.length ? (
        <div className="git-conflicts">
          <h3>Conflitos</h3>
          {conflicts.map((c) => (
            <div key={c.path} className="git-conflict">
              <b>{c.path}</b>
              <button type="button" onClick={() => w().resolveConflict(c.path, "ours")}>
                nosso
              </button>
              <button type="button" onClick={() => w().resolveConflict(c.path, "theirs")}>
                deles
              </button>
            </div>
          ))}
        </div>
      ) : null}

      <div className="git-body">
        {stagedFiles.length ? (
          <GitGroup
            title="Staged"
            count={stagedFiles.length}
            extra={
              <button type="button" title="Unstage all" onClick={() => w().gitUnstageAll()}>
                <Minus size={14} />
              </button>
            }
          >
            {stagedFiles.map((p) => (
              <GitFile
                key={`s:${p}`}
                path={p}
                letter={fileStatus(head?.files[p], files[p])}
                stats={diffStats(head?.files[p], files[p])}
                staged
              />
            ))}
          </GitGroup>
        ) : null}

        <GitGroup
          title="Alterações"
          count={unstaged.length}
          extra={
            unstaged.length ? (
              <>
                <button type="button" title="Stage all" onClick={() => w().gitStageAll()}>
                  <Plus size={14} />
                </button>
                <button type="button" title="Discard all" onClick={() => run(() => w().gitDiscardAll())}>
                  <Trash2 size={14} />
                </button>
              </>
            ) : null
          }
        >
          {unstaged.length === 0 ? (
            <p className="git-empty">{clean ? "Working tree limpa" : "Nada unstaged"}</p>
          ) : (
            unstaged.map((p) => (
              <GitFile
                key={`u:${p}`}
                path={p}
                letter={fileStatus(head?.files[p], files[p])}
                stats={diffStats(head?.files[p], files[p])}
              />
            ))
          )}
        </GitGroup>

        <div className="git-more git-card">
          <button type="button" className="git-more-toggle" onClick={() => setMore((v) => !v)}>
            {more ? "Branch, stash e GitHub ▾" : "Branch, stash e GitHub ▸"}
          </button>
          {more || stash.length ? (
            <div className="git-more-body">
            <div className="git-branch-row">
              <input
                className="field"
                placeholder="novo branch"
                value={branchName}
                onChange={(e) => setBranchName(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && branchName.trim()) {
                    setNote(w().gitBranchCreate(branchName));
                    setBranchName("");
                  }
                }}
              />
              <button
                type="button"
                className="chip"
                disabled={!branchName.trim()}
                onClick={() => {
                  setNote(w().gitBranchCreate(branchName));
                  setBranchName("");
                }}
              >
                criar
              </button>
            </div>
            {commits.length >= 2 ? (
            <div className="git-compare">
              <PickList
                label="Commit A"
                value={compareA || commits[commits.length - 2]!.id}
                options={commits.map((c) => ({ id: c.id, label: c.message.slice(0, 40) }))}
                onChange={(id) => useHub.setState({ compareA: id })}
                fill
                ariaLabel="commit A"
              />
              <PickList
                label="Commit B"
                value={compareB || commits[commits.length - 1]!.id}
                options={commits.map((c) => ({ id: c.id, label: c.message.slice(0, 40) }))}
                onChange={(id) => useHub.setState({ compareB: id })}
                fill
                ariaLabel="commit B"
              />
              <button
                type="button"
                className="chip git-compare-go"
                onClick={() => {
                  const a = useHub.getState().compareA || commits[Math.max(0, commits.length - 2)]?.id;
                  const b = useHub.getState().compareB || commits[commits.length - 1]?.id;
                  if (a && b) useHub.getState().setCompare(a, b);
                }}
              >
                comparar
              </button>
            </div>
            ) : null}
            <div className="git-stash-row">
              <button type="button" className="chip" onClick={() => run(() => w().gitStash())}>
                <Archive size={14} />
                Stash
              </button>
              <button type="button" className="chip" disabled={!stash.length} onClick={() => run(() => w().gitStashPop())}>
                Pop{stash.length ? ` ${stash.length}` : ""}
              </button>
            </div>
            {remote ? (
              <p className="git-remote">
                {remote}
                {token ? "" : " · conecta o GitHub nos Ajustes"}
              </p>
            ) : null}
            {remote && token ? (
              <div className="git-stash-row">
                <button
                  type="button"
                  className="chip"
                  disabled={busy}
                  onClick={() => {
                    setBusy(true);
                    void remotePush(msg.trim() || "colo push", setNote)
                      .then((sha) => setNote(sha))
                      .catch((e) => setNote(e instanceof Error ? e.message : "push falhou"))
                      .finally(() => setBusy(false));
                  }}
                >
                  Push GitHub
                </button>
                <button
                  type="button"
                  className="chip"
                  disabled={busy}
                  onClick={() => {
                    setBusy(true);
                    void githubPullTree(remote, branch, token)
                      .then((r: CloneResult) => setNote(w().mergeRemote(r.files)))
                      .catch((e: unknown) => setNote(e instanceof Error ? e.message : "pull falhou"))
                      .finally(() => setBusy(false));
                  }}
                >
                  Pull GitHub
                </button>
              </div>
            ) : null}
          </div>
          ) : null}
        </div>

        <GitGroup
          title="Histórico"
          count={commits.length}
          extra={
            commits.length > 1 ? (
              <button type="button" title="Undo último commit" onClick={() => run(() => w().gitUndoCommit())}>
                undo
              </button>
            ) : null
          }
        >
          {[...commits].reverse().map((c) => (
            <article key={c.id} className="git-log">
              <i className="git-dot" />
              <button
                type="button"
                className="git-log-main"
                onClick={() => useHub.getState().setCompare(c.id, head?.id ?? c.id)}
                title="comparar com HEAD"
              >
                <b>{c.message}</b>
                <span>
                  <code>{c.id}</code>
                  {c.id === lastPushedId ? <em className="git-origin">origin</em> : null}
                </span>
              </button>
              <span className="git-log-ops">
              <button
                type="button"
                className="git-ghost"
                title="cherry-pick"
                onClick={() => run(() => w().gitCherryPick(c.id))}
              >
                <Layers size={14} />
              </button>
              <button
                type="button"
                className="git-ghost"
                title="restaurar"
                onClick={() => {
                  if (!window.confirm(`restaurar arquivos do commit ${c.id}?`)) return;
                  run(() => w().gitRestoreCommit(c.id));
                }}
              >
                <RotateCcw size={14} />
              </button>
              </span>
            </article>
          ))}
        </GitGroup>
      </div>
      {remote && token ? <GithubBox remote={remote} branch={branch} token={token} /> : null}
    </div>
  );
}

function GitGroup({
  title,
  count,
  extra,
  children,
}: {
  title: string;
  count: number;
  extra?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section className="git-group git-card">
      <header>
        <span>
          {title}
          <em>{count}</em>
        </span>
        <span className="git-group-ops">{extra}</span>
      </header>
      {children}
    </section>
  );
}

function GitFile({
  path,
  letter,
  stats,
  staged,
}: {
  path: string;
  letter: "A" | "D" | "M";
  stats: { add: number; del: number };
  staged?: boolean;
}) {
  const w = () => useWorkspace.getState();
  const name = path.split("/").pop() ?? path;
  const dir = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";
  const [blame, setBlame] = useState(false);
  const [openHunks, setOpenHunks] = useState(false);
  const [more, setMore] = useState(false);
  const headBody = useWorkspace((s) => s.commits.at(-1)?.files[path]);
  const body = useWorkspace((s) => s.files[path]);
  const rows = blame ? w().gitBlame(path).slice(0, 40) : [];
  const hunks = openHunks ? hunksOf(headBody ?? "", body ?? "") : [];
  function openDiff() {
    w().openFile(path);
    useChrome.getState().setCenter("diff");
  }
  return (
    <div className="git-file-wrap">
      <div className="git-file">
        <b className={`git-letter is-${letter}`}>{letter}</b>
        <button type="button" className="git-name" title={path} onClick={openDiff}>
          <strong>{name}</strong>
          {dir ? <span>{dir}</span> : null}
        </button>
        <span className="git-stat">
          {stats.add ? <em className="is-add">+{stats.add}</em> : null}
          {stats.del ? <em className="is-del">−{stats.del}</em> : null}
        </span>
        <span className="git-ops">
          {staged ? (
            <button type="button" title="Unstage" onClick={() => w().gitUnstage(path)}>
              <Minus size={16} />
            </button>
          ) : (
            <>
              <button type="button" title="Stage" onClick={() => w().gitStage(path)}>
                <Plus size={16} />
              </button>
              <button type="button" title="Discard" onClick={() => w().gitDiscard(path)}>
                <Trash2 size={16} />
              </button>
            </>
          )}
          <button
            type="button"
            title="mais"
            className={more ? "is-on" : undefined}
            onClick={() => setMore((v) => !v)}
          >
            <EllipsisVertical size={16} />
          </button>
        </span>
      </div>
      {more ? (
        <div className="git-file-more">
          <button type="button" onClick={openDiff}>
            <Eye size={14} />
            diff
          </button>
          <button type="button" onClick={() => setOpenHunks((v) => !v)}>
            <Layers size={14} />
            hunks
          </button>
          <button
            type="button"
            onClick={() => {
              w().openFile(path);
              useChrome.getState().setCenter("code");
              useNav.getState().setBlame(true);
              setBlame((v) => !v);
            }}
          >
            <GitCommit size={14} />
            blame
          </button>
        </div>
      ) : null}
      {openHunks ? (
        <div className="git-hunks">
          {hunks.length === 0 ? (
            <p>sem hunks</p>
          ) : (
            hunks.map((h, i) => (
              <div key={h.id} className="git-hunk">
                <header>
                  hunk {i + 1}
                  <span>
                    +{h.adds.length} −{h.dels.length}
                  </span>
                </header>
                <pre>
                  {h.dels.map((l) => `− ${l}`).join("\n")}
                  {h.dels.length && h.adds.length ? "\n" : ""}
                  {h.adds.map((l) => `+ ${l}`).join("\n")}
                </pre>
                {!staged ? (
                  <div className="git-hunk-ops">
                    <button type="button" onClick={() => w().gitApplyHunk(path, i, true)}>
                      só este
                    </button>
                    <button type="button" onClick={() => w().gitApplyHunk(path, i, false)}>
                      descartar
                    </button>
                  </div>
                ) : null}
              </div>
            ))
          )}
        </div>
      ) : null}
      {blame ? (
        <pre className="git-blame">
          {rows.map((r) => `${r.id}  ${String(r.line).padStart(3, " ")}  ${r.text}`).join("\n")}
        </pre>
      ) : null}
    </div>
  );
}

function GithubBox({ remote, branch, token }: { remote: string; branch: string; token: string }) {
  const [issues, setIssues] = useState<{ number: number; title: string; url: string }[]>([]);
  const [prs, setPrs] = useState<{ number: number; title: string; url: string }[]>([]);
  const [prFiles, setPrFiles] = useState<{ path: string; status: string; add: number; del: number; patch: string }[] | null>(null);
  const [prOpen, setPrOpen] = useState<number | null>(null);
  const [title, setTitle] = useState("");
  const [base, setBase] = useState("main");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  function load() {
    setBusy(true);
    void Promise.all([githubIssues(remote, token), githubPulls(remote, token)])
      .then(([i, p]) => {
        setIssues(i);
        setPrs(p);
      })
      .catch((e: unknown) => setNote(e instanceof Error ? e.message : "falhou"))
      .finally(() => setBusy(false));
  }
  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [remote, token]);
  return (
    <section className="git-group git-gh">
      <header>
        <span>
          GitHub
          <em>{remote}</em>
        </span>
        <button type="button" onClick={load} disabled={busy}>
          {busy ? "…" : "atualizar"}
        </button>
        <button type="button" onClick={() => useHub.getState().setView("actions")}>
          Actions
        </button>
      </header>
      <p className="git-remote">
        <a href={`https://github.com/${remote}`} target="_blank" rel="noreferrer">
          abrir no GitHub
        </a>
      </p>
      {prs.slice(0, 8).map((p) => (
        <div key={p.number} className="git-pr">
          <button
            type="button"
            className="hit"
            onClick={() => {
              if (prOpen === p.number) {
                setPrOpen(null);
                setPrFiles(null);
                return;
              }
              setPrOpen(p.number);
              setBusy(true);
              void githubPrFiles(remote, token, p.number)
                .then((f) => setPrFiles(f))
                .catch((e) => setNote(e instanceof Error ? e.message : "diff falhou"))
                .finally(() => setBusy(false));
            }}
          >
            <b>PR #{p.number}</b>
            <span>{p.title}</span>
          </button>
          <div className="git-pr-ops">
            <button
              type="button"
              className="chip"
              onClick={() => useHub.getState().setPr(p.number)}
            >
              comentários
            </button>
            <button
              type="button"
              className="chip"
              disabled={busy}
              onClick={() => {
                setBusy(true);
                void githubReviewPr(remote, token, p.number, "APPROVE", "ok pelo Colo")
                  .then(() => setNote(`review #${p.number} aprovada`))
                  .catch((e) => setNote(e instanceof Error ? e.message : "review falhou"))
                  .finally(() => setBusy(false));
              }}
            >
              aprovar
            </button>
            <button
              type="button"
              className="chip is-on"
              disabled={busy}
              onClick={() => {
                if (!window.confirm(`merge squash PR #${p.number}?`)) return;
                setBusy(true);
                void githubMergePr(remote, token, p.number, "squash")
                  .then((r) => {
                    setNote(r.merged ? `merge #${p.number}` : r.message);
                    load();
                  })
                  .catch((e) => setNote(e instanceof Error ? e.message : "merge falhou"))
                  .finally(() => setBusy(false));
              }}
            >
              merge
            </button>
          </div>
          {prOpen === p.number && prFiles ? (
            <div className="git-pr-diff">
              {prFiles.slice(0, 20).map((f) => (
                <details key={f.path}>
                  <summary>
                    {f.path} <em>+{f.add} −{f.del}</em>
                  </summary>
                  <pre>{f.patch || "(sem patch)"}</pre>
                </details>
              ))}
            </div>
          ) : null}
        </div>
      ))}
      {issues.slice(0, 5).map((i) => (
        <a key={i.number} className="hit" href={i.url} target="_blank" rel="noreferrer">
          <b>#{i.number}</b>
          <span>{i.title}</span>
        </a>
      ))}
      <div className="git-issue-form">
        <input className="field" placeholder="título da issue / PR" value={title} onChange={(e) => setTitle(e.target.value)} />
        <input className="field" placeholder="base da PR" value={base} onChange={(e) => setBase(e.target.value)} />
        <div className="git-issue-form-ops">
        <button
          type="button"
          className="chip"
          disabled={!title.trim() || busy}
          onClick={() => {
            setBusy(true);
            void githubCreateIssue(remote, token, title.trim(), "")
              .then((r) => {
                setNote(`issue #${r.number}`);
                setTitle("");
                load();
              })
              .catch((e) => setNote(e instanceof Error ? e.message : "falhou"))
              .finally(() => setBusy(false));
          }}
        >
          issue
        </button>
        <button
          type="button"
          className="chip is-on"
          disabled={!title.trim() || busy}
          onClick={() => {
            const head = branch || "main";
            const into = base.trim() || "main";
            if (head === into) {
              setNote("PR: o head e o base são iguais. muda o branch ou o base.");
              return;
            }
            setBusy(true);
            void githubCreatePr(remote, token, title.trim(), "", head, into)
              .then((r) => {
                setNote(`PR #${r.number}`);
                setTitle("");
                load();
              })
              .catch((e) => setNote(e instanceof Error ? e.message : "falhou"))
              .finally(() => setBusy(false));
          }}
        >
          PR
        </button>
        <button
          type="button"
          className="chip"
          disabled={busy}
          onClick={() => {
            setBusy(true);
            void githubFork(remote, token)
              .then((r) => setNote(`fork ${r.full_name}`))
              .catch((e) => setNote(e instanceof Error ? e.message : "fork falhou"))
              .finally(() => setBusy(false));
          }}
        >
          fork
        </button>
        </div>
      </div>
      {note ? <p className="git-note">{note}</p> : null}
    </section>
  );
}
