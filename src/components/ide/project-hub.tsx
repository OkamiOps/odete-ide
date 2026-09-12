import { useRef, useState, type ChangeEvent } from "react";
import { Github, Trash2, X } from "lucide-react";
import { githubClone, githubRepos, parseRepo, type GithubRepo } from "@/lib/github/api";
import { setSheet, useProjectUi, useProjects, type ProjectSheet } from "@/lib/workspace/projects";
import { useWorkspace } from "@/lib/workspace/store";
import { downloadZip, importZipFile } from "@/lib/workspace/zip";

export function ProjectHub() {
  const sheet = useProjectUi((s) => s.sheet);
  if (!sheet) return null;
  return (
    <div className="project-scrim" onClick={() => setSheet(false)}>
      <div
        className="project-sheet"
        role="dialog"
        aria-modal="true"
        aria-label="Projeto"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="project-sheet-hd">
          <b>{title(sheet)}</b>
          <button type="button" className="ex-add" aria-label="fechar" onClick={() => setSheet(false)}>
            <X size={18} />
          </button>
        </div>
        {sheet === "hub" ? <ProjectMenu /> : null}
        {sheet === "library" ? <LibraryList /> : null}
        {sheet === "recent" ? <RecentList /> : null}
        {sheet === "open" ? <OpenForm /> : null}
        {sheet === "clone" ? <CloneForm /> : null}
        {sheet === "github" ? <GithubForm /> : null}
        {sheet === "new" ? <NewForm /> : null}
      </div>
    </div>
  );
}

export function ProjectMenu({ onPick }: { onPick?: () => void }) {
  const github = useProjects((s) => s.github);
  const zipRef = useRef<HTMLInputElement>(null);
  function go(next: ProjectSheet) {
    onPick?.();
    setSheet(next);
  }
  return (
    <div className="ex-menu-list">
      <button type="button" onClick={() => go("new")}>Novo projeto</button>
      <button type="button" onClick={() => go("open")}>Abrir projeto</button>
      <button type="button" onClick={() => go("library")}>Projetos neste iPad</button>
      <button type="button" onClick={() => go("recent")}>Abrir recente</button>
      <button type="button" onClick={() => go("clone")}>Clonar do GitHub</button>
      <button type="button" onClick={() => go("github")}>
        {github ? `GitHub · ${github.user.login}` : "Conectar GitHub"}
      </button>
      <button
        type="button"
        onClick={() => {
          onPick?.();
          const s = useWorkspace.getState();
          void downloadZip(s.projectName, s.files);
        }}
      >
        Exportar / compartilhar zip
      </button>
      <button type="button" onClick={() => zipRef.current?.click()}>
        Importar zip
      </button>
      <input
        ref={zipRef}
        type="file"
        accept=".zip,application/zip"
        hidden
        onChange={(e) => {
          const f = e.target.files?.[0];
          e.target.value = "";
          if (!f) return;
          void importZipFile(f).then((files) => {
            if (!Object.keys(files).length) return;
            onPick?.();
            useWorkspace.getState().loadProject({
              id: `zip-${Date.now()}`,
              name: f.name.replace(/\.zip$/i, "") || "zip",
              files,
              remote: null,
              message: "importar zip",
            });
            setSheet(false);
          });
        }}
      />
      <button
        type="button"
        onClick={() => {
          onPick?.();
          exportJson();
        }}
      >
        Exportar JSON
      </button>
      <button
        type="button"
        onClick={() => {
          onPick?.();
          useWorkspace.getState().closeProject();
          setSheet(false);
        }}
      >
        Fechar projeto
      </button>
    </div>
  );
}

function title(sheet: ProjectSheet) {
  if (sheet === "library") return "Projetos neste iPad";
  if (sheet === "recent") return "Abrir recente";
  if (sheet === "open") return "Abrir projeto";
  if (sheet === "clone") return "Clonar repo";
  if (sheet === "github") return "GitHub";
  if (sheet === "new") return "Novo projeto";
  return "Projeto";
}

function LibraryList() {
  const library = useProjects((s) => s.library);
  const recents = useProjects((s) => s.recents);
  const list = library.length ? library : recents;
  const forget = useProjects((s) => s.forget);
  const rename = useProjects((s) => s.rename);
  const duplicate = useProjects((s) => s.duplicate);
  if (!list.length) return <p className="text-sm text-fg-muted">Nenhum projeto salvo neste iPad.</p>;
  return (
    <div className="agent-starts">
      {list.map((r) => (
        <div key={r.id} className="lib-row">
          <button
            type="button"
            onClick={() => {
              useWorkspace.getState().loadProject({
                id: r.id,
                name: r.name,
                files: r.snapshot,
                remote: r.remote,
                branch: r.branch,
              });
              setSheet(false);
            }}
          >
            <b>{r.name}</b>
            <em>
              {r.files} arquivos{r.remote ? ` · ${r.remote}` : " · local"}
            </em>
          </button>
          <input
            className="field"
            defaultValue={r.name}
            aria-label={`renomear ${r.name}`}
            onBlur={(e) => {
              if (e.target.value.trim() && e.target.value !== r.name) rename(r.id, e.target.value);
            }}
          />
          <button
            type="button"
            className="agent-icon"
            aria-label="duplicar"
            onClick={() => duplicate(r.id)}
          >
            +
          </button>
          <button type="button" className="agent-icon" aria-label="apagar" onClick={() => forget(r.id)}>
            <Trash2 size={14} />
          </button>
        </div>
      ))}
    </div>
  );
}

function RecentList() {
  const recents = useProjects((s) => s.recents);
  const forget = useProjects((s) => s.forget);
  if (!recents.length) return <p className="text-sm text-fg-muted">Nenhum recente ainda.</p>;
  return (
    <div className="agent-starts">
      {recents.map((r) => (
        <div key={r.id} className="recent-row">
          <button
            type="button"
            onClick={() => {
              useWorkspace.getState().loadProject({
                id: r.id,
                name: r.name,
                files: r.snapshot,
                remote: r.remote,
                branch: r.branch,
              });
              setSheet(false);
            }}
          >
            <b>{r.name}</b>
            <em>
              {r.files} arquivos{r.remote ? ` · ${r.remote}` : ""} · {new Date(r.at).toLocaleDateString("pt-BR")}
            </em>
          </button>
          <button type="button" className="agent-icon" aria-label="apagar recente" onClick={() => forget(r.id)}>
            <Trash2 size={14} />
          </button>
        </div>
      ))}
    </div>
  );
}

function NewForm() {
  const [name, setName] = useState("");
  return (
    <form
      className="space-y-3"
      onSubmit={(e) => {
        e.preventDefault();
        useWorkspace.getState().newProject(name || "sem título");
        setSheet(false);
      }}
    >
      <input className="field" placeholder="nome do projeto" value={name} onChange={(e) => setName(e.target.value)} autoFocus />
      <button type="submit" className="chip is-on">
        Criar
      </button>
    </form>
  );
}

function OpenForm() {
  const fileRef = useRef<HTMLInputElement>(null);
  const dirRef = useRef<HTMLInputElement>(null);
  const jsonRef = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState("");
  const [err, setErr] = useState("");

  async function fromDirectoryApi() {
    setErr("");
    const picker = (window as Window & { showDirectoryPicker?: () => Promise<FileSystemDirectoryHandle> })
      .showDirectoryPicker;
    if (!picker) {
      dirRef.current?.click();
      return;
    }
    setBusy("lendo pasta…");
    try {
      const root = await picker();
      const files = await readDirectoryHandle(root);
      if (!Object.keys(files).length) {
        setErr("pasta vazia ou só binários");
        return;
      }
      useWorkspace.getState().loadProject({
        id: `local-${Date.now()}`,
        name: root.name || "projeto",
        files,
        remote: null,
        message: `abrir ${root.name}`,
      });
      setSheet(false);
    } catch (e) {
      if (e instanceof DOMException && e.name === "AbortError") return;
      setErr(e instanceof Error ? e.message : "não deu pra abrir");
    } finally {
      setBusy("");
    }
  }

  return (
    <div className="open-form">
      <p className="text-xs leading-relaxed text-fg-muted">
        Pasta local neste iPad, sem Git e sem recente. Abre pelo Files e vira o workspace.
      </p>
      <div className="agent-starts">
        <button type="button" onPointerDown={() => void fromDirectoryApi()} disabled={!!busy}>
          {busy || "Pasta do iPad"}
        </button>
        <button type="button" onPointerDown={() => jsonRef.current?.click()}>
          Arquivo JSON do Colo
        </button>
        <button type="button" onPointerDown={() => fileRef.current?.click()}>
          Vários arquivos
        </button>
      </div>
      {err ? <p className="agent-err">{err}</p> : null}
      <input
        ref={dirRef}
        type="file"
        multiple
        hidden
        {...{ webkitdirectory: "", directory: "" }}
        onChange={(e) => void importPicked(e, true)}
      />
      <input ref={fileRef} type="file" multiple hidden onChange={(e) => void importPicked(e)} />
      <input ref={jsonRef} type="file" accept="application/json,.json" hidden onChange={(e) => void openJson(e).catch((er) => setErr(er instanceof Error ? er.message : "JSON inválido"))} />
    </div>
  );
}

function CloneForm() {
  const github = useProjects((s) => s.github);
  const [url, setUrl] = useState("");
  const [busy, setBusy] = useState("");
  const [err, setErr] = useState("");
  const [repos, setRepos] = useState<GithubRepo[]>([]);

  async function run(target: string) {
    setErr("");
    setBusy("clonando…");
    try {
      const r = await githubClone(target, github?.token, setBusy);
      useWorkspace.getState().loadProject({
        id: `gh-${r.remote}`,
        name: r.name,
        files: r.files,
        remote: r.remote,
        branch: r.branch,
        message: `clone ${r.remote}`,
      });
      setSheet(false);
    } catch (e) {
      setErr(e instanceof Error ? e.message : "falha no clone");
    } finally {
      setBusy("");
    }
  }

  return (
    <div className="space-y-3">
      <p className="text-xs text-fg-muted">Público sem token. Privado precisa conectar o GitHub.</p>
      <form
        className="flex gap-2"
        onSubmit={(e) => {
          e.preventDefault();
          if (url.trim()) void run(url.trim());
        }}
      >
        <input
          className="field"
          placeholder="owner/repo ou URL"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          autoCapitalize="off"
          autoCorrect="off"
          spellCheck={false}
        />
        <button type="submit" className="chip is-on shrink-0" disabled={!!busy}>
          {busy ? "…" : "clonar"}
        </button>
      </form>
      {busy ? <p className="text-xs text-fg-muted">{busy}</p> : null}
      {err ? <p className="agent-err">{err}</p> : null}
      {github ? (
        <button
          type="button"
          className="chip"
          onClick={async () => {
            try {
              setRepos(await githubRepos(github.token));
            } catch (e) {
              setErr(e instanceof Error ? e.message : "não listou os repos");
            }
          }}
        >
          listar meus repos
        </button>
      ) : (
        <button type="button" className="chip" onClick={() => setSheet("github")}>
          conectar GitHub
        </button>
      )}
      {repos.length ? (
        <div className="agent-starts">
          {repos.map((r) => (
            <button key={r.full} type="button" onClick={() => void run(r.full)} disabled={!!busy}>
              <b>{r.full}</b>
              <em>{r.private ? "privado" : "público"}</em>
            </button>
          ))}
        </div>
      ) : null}
      {url && parseRepo(url) ? null : null}
    </div>
  );
}

function GithubForm() {
  const github = useProjects((s) => s.github);
  const connect = useProjects((s) => s.connect);
  const disconnect = useProjects((s) => s.disconnect);
  const [token, setToken] = useState("");
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  if (github) {
    return (
      <div className="space-y-3">
        <p className="project-now">
          <Github size={16} />
          <span>
            <b>{github.user.login}</b>
            <em>{github.user.name || "conectado"}</em>
          </span>
        </p>
        <button type="button" className="chip" onClick={disconnect}>
          desconectar
        </button>
        <button type="button" className="chip is-on" onClick={() => setSheet("clone")}>
          clonar um repo
        </button>
      </div>
    );
  }
  return (
    <form
      className="space-y-3"
      onSubmit={async (e) => {
        e.preventDefault();
        setErr("");
        setBusy(true);
        try {
          await connect(token);
        } catch (er) {
          setErr(er instanceof Error ? er.message : "token inválido");
        } finally {
          setBusy(false);
        }
      }}
    >
      <p className="text-xs leading-relaxed text-fg-muted">
        Cria um token em github.com/settings/tokens (scope <code>repo</code>) e cola aqui. Fica só neste iPad.
      </p>
      <input
        className="field"
        placeholder="ghp_…"
        value={token}
        onChange={(e) => setToken(e.target.value)}
        autoCapitalize="off"
        autoCorrect="off"
        spellCheck={false}
      />
      <button type="submit" className="chip is-on" disabled={busy || !token.trim()}>
        {busy ? "…" : "conectar"}
      </button>
      {err ? <p className="agent-err">{err}</p> : null}
    </form>
  );
}

async function importPicked(e: ChangeEvent<HTMLInputElement>, folder = false) {
  const list = e.target.files;
  if (!list?.length) return;
  const files: Record<string, string> = {};
  for (const f of [...list]) {
    if (f.size > 400_000) continue;
    const rel =
      folder && f.webkitRelativePath
        ? f.webkitRelativePath.split("/").slice(1).join("/") || f.name
        : f.name;
    if (!rel || /\.(png|jpe?g|gif|webp|woff2?|zip|pdf)$/i.test(rel)) continue;
    try {
      files[rel] = await f.text();
    } catch {
      /* skip */
    }
  }
  if (Object.keys(files).length) {
    const name =
      folder && list[0]?.webkitRelativePath ? list[0].webkitRelativePath.split("/")[0]! : "local";
    useWorkspace.getState().loadProject({
      id: `local-${Date.now()}`,
      name,
      files,
      remote: null,
      message: "abrir projeto local",
    });
  }
  e.target.value = "";
  setSheet(false);
}

async function openJson(e: ChangeEvent<HTMLInputElement>) {
  const f = e.target.files?.[0];
  e.target.value = "";
  if (!f) return;
  const data = JSON.parse(await f.text()) as {
    name?: string;
    files?: Record<string, string>;
    remote?: string | null;
  };
  if (!data.files || typeof data.files !== "object" || !Object.keys(data.files).length) {
    throw new Error("JSON sem arquivos");
  }
  useWorkspace.getState().loadProject({
    id: `json-${Date.now()}`,
    name: data.name || f.name.replace(/\.json$/i, ""),
    files: data.files,
    remote: data.remote ?? null,
    message: "abrir json",
  });
  setSheet(false);
}

async function readDirectoryHandle(
  root: FileSystemDirectoryHandle,
  prefix = "",
): Promise<Record<string, string>> {
  const files: Record<string, string> = {};
  const skip = new Set(["node_modules", ".git", "dist", "build", ".next"]);
  const dir = root as FileSystemDirectoryHandle & {
    entries: () => AsyncIterableIterator<[string, FileSystemHandle]>;
  };
  for await (const [name, handle] of dir.entries()) {
    const path = prefix ? `${prefix}/${name}` : name;
    if (handle.kind === "directory") {
      if (skip.has(name)) continue;
      Object.assign(files, await readDirectoryHandle(handle as FileSystemDirectoryHandle, path));
    } else {
      if (/\.(png|jpe?g|gif|webp|woff2?|zip|pdf|ico)$/i.test(name)) continue;
      const file = await (handle as FileSystemFileHandle).getFile();
      if (file.size > 400_000) continue;
      files[path] = await file.text();
    }
  }
  return files;
}

function exportJson() {
  const s = useWorkspace.getState();
  const blob = new Blob(
    [JSON.stringify({ name: s.projectName, remote: s.remote, files: s.files }, null, 2)],
    { type: "application/json" },
  );
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `${s.projectName || "colo"}.json`;
  a.click();
  URL.revokeObjectURL(a.href);
}
