import { useEffect, useState } from "react";
import { X } from "lucide-react";
import {
  githubActions,
  githubCommentPr,
  githubPrComments,
  githubPrFiles,
  githubPulls,
} from "@/lib/github/api";
import { bindFolder, writeTree } from "@/lib/workspace/folder";
import { useHub } from "@/lib/workspace/hub";
import { useProjects } from "@/lib/workspace/projects";
import { useWorkspace } from "@/lib/workspace/store";
import { fileDiff } from "@/lib/workspace/diff";

export function GhSheet() {
  const view = useHub((s) => s.view);
  if (!view) return null;
  return (
    <div className="cheat-scrim" onClick={() => useHub.getState().setView(null)}>
      <div className="cheat-card gh-sheet" onClick={(e) => e.stopPropagation()} role="dialog">
        {view === "actions" ? <ActionsBody /> : null}
        {view === "prs" ? <PrsBody /> : null}
        {view === "pr" ? <PrBody /> : null}
        {view === "compare" ? <CompareBody /> : null}
        {view === "folder" ? <FolderBody /> : null}
      </div>
    </div>
  );
}

function Hd({ title }: { title: string }) {
  return (
    <div className="project-sheet-hd">
      <b>{title}</b>
      <button type="button" onClick={() => useHub.getState().setView(null)} aria-label="fechar">
        <X size={16} />
      </button>
    </div>
  );
}

function ActionsBody() {
  const remote = useWorkspace((s) => s.remote);
  const token = useProjects((s) => s.github?.token);
  const [rows, setRows] = useState<{ id: number; name: string; status: string; conclusion: string | null; url: string; branch: string; at: string }[]>([]);
  const [err, setErr] = useState("");
  useEffect(() => {
    if (!remote || !token) return;
    void githubActions(remote, token).then(setRows).catch((e) => setErr(e instanceof Error ? e.message : "falhou"));
  }, [remote, token]);
  return (
    <>
      <Hd title="Actions" />
      <div className="gh-sheet-body">
        {err ? <p className="agent-err">{err}</p> : null}
        {!token ? <p className="gh-empty">Conecta o GitHub nos Ajustes pra ver os runs.</p> : null}
        {rows.map((r) => {
          const tone = r.conclusion === "success" ? "ok" : r.conclusion === "failure" ? "bad" : "run";
          return (
            <a key={r.id} className="gh-row" href={r.url} target="_blank" rel="noreferrer">
              <span className={`gh-pill is-${tone}`}>{r.conclusion || r.status}</span>
              <b>{r.name}</b>
              <span>
                {r.branch} · {new Date(r.at).toLocaleString("pt-BR")}
              </span>
            </a>
          );
        })}
        {token && !rows.length && !err ? <p className="gh-empty">Nenhum workflow rodou ainda neste repo.</p> : null}
      </div>
    </>
  );
}

function PrBody() {
  const remote = useWorkspace((s) => s.remote);
  const token = useProjects((s) => s.github?.token);
  const n = useHub((s) => s.pr);
  const [comments, setComments] = useState<{ user: string; body: string; at: string }[]>([]);
  const [files, setFiles] = useState<{ path: string; add: number; del: number; patch: string }[]>([]);
  const [body, setBody] = useState("");
  const [note, setNote] = useState("");
  useEffect(() => {
    if (!remote || !token || !n) return;
    void Promise.all([githubPrComments(remote, token, n), githubPrFiles(remote, token, n)])
      .then(([c, f]) => {
        setComments(c);
        setFiles(f);
      })
      .catch((e) => setNote(e instanceof Error ? e.message : "falhou"));
  }, [remote, token, n]);
  return (
    <>
      <Hd title={`PR #${n}`} />
      <div className="gh-sheet-body">
        {files.map((f) => (
          <details key={f.path}>
            <summary>
              {f.path} <em>+{f.add} −{f.del}</em>
            </summary>
            <pre>{f.patch || "(sem patch)"}</pre>
          </details>
        ))}
        <h3>Comentários</h3>
        {comments.map((c, i) => (
          <article key={i} className="gh-comment">
            <b>{c.user}</b>
            <p>{c.body}</p>
          </article>
        ))}
        <textarea className="field" rows={4} placeholder="comentário da review" value={body} onChange={(e) => setBody(e.target.value)} />
        <button
          type="button"
          className="chip is-on"
          disabled={!body.trim() || !token}
          onClick={() => {
            if (!remote || !token) return;
            void githubCommentPr(remote, token, n, body.trim())
              .then(() => {
                setComments((xs) => [...xs, { user: "você", body: body.trim(), at: new Date().toISOString() }]);
                setBody("");
                setNote("enviado");
              })
              .catch((e) => setNote(e instanceof Error ? e.message : "falhou"));
          }}
        >
          Comentar
        </button>
        {note ? <p className="git-note">{note}</p> : null}
      </div>
    </>
  );
}

function CompareBody() {
  const commits = useWorkspace((s) => s.commits);
  const a = useHub((s) => s.compareA);
  const b = useHub((s) => s.compareB);
  const ca = commits.find((c) => c.id === a);
  const cb = commits.find((c) => c.id === b);
  const keys = [...new Set([...Object.keys(ca?.files ?? {}), ...Object.keys(cb?.files ?? {})])].sort();
  const changed = keys.filter((k) => (ca?.files[k] ?? "") !== (cb?.files[k] ?? ""));
  const [path, setPath] = useState(changed[0] ?? "");
  const rows = path ? fileDiff(path, cb?.files ?? {}, ca?.files) : [];
  return (
    <>
      <Hd title="Comparar commits" />
      <div className="gh-sheet-body">
        <p>
          {ca?.message ?? a} → {cb?.message ?? b}
        </p>
        <div className="chip-row">
          {changed.map((p) => (
            <button key={p} type="button" className={p === path ? "chip is-on" : "chip"} onClick={() => setPath(p)}>
              {p.split("/").pop()}
            </button>
          ))}
        </div>
        {rows.map((r, i) => (
          <pre key={i} className={`diff-line is-${r.kind}`}>
            {r.kind === "add" ? "+" : r.kind === "del" ? "−" : " "}
            {r.text}
          </pre>
        ))}
        {!changed.length ? <p>iguais</p> : null}
      </div>
    </>
  );
}

function PrsBody() {
  const remote = useWorkspace((s) => s.remote);
  const token = useProjects((s) => s.github?.token);
  const [rows, setRows] = useState<{ number: number; title: string; url: string; head: string; draft: boolean; user: string; at: string }[]>([]);
  const [err, setErr] = useState("");
  useEffect(() => {
    if (!remote || !token) return;
    void githubPulls(remote, token)
      .then(setRows)
      .catch((e) => setErr(e instanceof Error ? e.message : "falhou"));
  }, [remote, token]);
  return (
    <>
      <Hd title="Pull requests" />
      <div className="gh-sheet-body">
        {err ? <p className="agent-err">{err}</p> : null}
        {!token ? <p className="gh-empty">Conecta o GitHub nos Ajustes pra listar as PRs.</p> : null}
        {rows.map((p) => (
          <button key={p.number} type="button" className="gh-row" onClick={() => useHub.getState().setPr(p.number)}>
            <span className={`gh-pill ${p.draft ? "is-run" : "is-ok"}`}>{p.draft ? "draft" : `#${p.number}`}</span>
            <b>{p.title}</b>
            <span>
              {p.head}
              {p.user ? ` · ${p.user}` : ""}
              {p.at ? ` · ${new Date(p.at).toLocaleDateString("pt-BR")}` : ""}
            </span>
          </button>
        ))}
        {token && !rows.length && !err ? (
          <p className="gh-empty">Nenhuma PR aberta. Quando abrir uma, ela aparece aqui.</p>
        ) : null}
      </div>
    </>
  );
}

function FolderBody() {
  const name = useHub((s) => s.folder);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [ok, setOk] = useState("");
  const picker = typeof window !== "undefined" && "showDirectoryPicker" in window;
  return (
    <>
      <Hd title="Salvar na pasta" />
      <div className="gh-sheet-body">
        <p>Tu escolhe a pasta no Files. O Colo só grava depois que tu apontar o lugar.</p>
        {name ? <p>pasta atual: <b>{name}</b></p> : <p>nenhuma pasta escolhida ainda</p>}
        {!picker ? (
          <p className="agent-err">
            este browser não deixa gravar pasta. no iPad abre o Files pelo app (Safari / TestFlight), não pelo preview do desktop.
          </p>
        ) : null}
        <button
          type="button"
          className="chip is-on"
          disabled={busy}
          onClick={() => {
            setErr("");
            setOk("");
            setBusy(true);
            void bindFolder()
              .then(async (dir) => {
                useHub.getState().setFolder(dir.name);
                await writeTree(dir, useWorkspace.getState().files);
                setOk(`gravado em ${dir.name}`);
              })
              .catch((e) => {
                if (e instanceof DOMException && e.name === "AbortError") return;
                setErr(e instanceof Error ? e.message : "não deu pra abrir a pasta");
              })
              .finally(() => setBusy(false));
          }}
        >
          {busy ? "abrindo Files…" : "Escolher pasta"}
        </button>
        {ok ? <p>{ok}</p> : null}
        {err ? <p className="agent-err">{err}</p> : null}
      </div>
    </>
  );
}
