import { useEffect, useRef, useState, type ChangeEvent } from "react";
import { Archive, Copy, FileJson, Files, FolderOpen, Github, Lock, Tablet, Trash2, X } from "lucide-react";
import { githubClone, githubCreateRepo, githubOrgs, githubRepos, type GithubOrg, type GithubRepo } from "@/lib/github/api";
import { setSheet, useProjectUi, useProjects, type ProjectSheet } from "@/lib/workspace/projects";
import { useWorkspace } from "@/lib/workspace/store";
import { downloadZip, importZipFile, saveBlob, safeName, type SaveOffer } from "@/lib/workspace/zip";

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
  const [offer, setOffer] = useState<SaveOffer | null>(null);
  const [copied, setCopied] = useState(false);
  function go(next: ProjectSheet) {
    onPick?.();
    setSheet(next);
  }
  async function offerFile(next: Promise<SaveOffer | null>) {
    const prev = offer;
    const got = await next;
    if (prev) URL.revokeObjectURL(prev.href);
    setOffer(got);
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
          const s = useWorkspace.getState();
          void offerFile(downloadZip(s.projectName, s.files));
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
      <button type="button" onClick={() => void offerFile(exportJson())}>
        Exportar JSON
      </button>
      <button
        type="button"
        onClick={async () => {
          const s = useWorkspace.getState();
          const text = JSON.stringify({ name: s.projectName, remote: s.remote, files: s.files }, null, 2);
          try {
            await navigator.clipboard.writeText(text);
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1500);
          } catch {
            setCopied(false);
          }
        }}
      >
        {copied ? "JSON copiado" : "Copiar JSON"}
      </button>
      {offer ? (
        <a className="save-offer" href={offer.href} download={offer.name} rel="noopener">
          Toque para salvar {offer.name}
        </a>
      ) : null}
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
  return <ProjectBrowser />;
}

function RecentList() {
  return <ProjectBrowser />;
}

function ProjectBrowser() {
  const library = useProjects((s) => s.library);
  const recents = useProjects((s) => s.recents);
  const forget = useProjects((s) => s.forget);
  const rename = useProjects((s) => s.rename);
  const duplicate = useProjects((s) => s.duplicate);
  const [q, setQ] = useState("");
  const [edit, setEdit] = useState<string | null>(null);

  const map = new Map<string, (typeof recents)[number]>();
  for (const r of [...library, ...recents]) {
    const prev = map.get(r.id);
    if (!prev || r.at > prev.at) map.set(r.id, r);
  }
  const all = [...map.values()].sort((a, b) => b.at - a.at);
  const needle = q.trim().toLowerCase();
  const list = needle
    ? all.filter((r) => `${r.name} ${r.remote ?? ""}`.toLowerCase().includes(needle))
    : all;

  function open(r: (typeof recents)[number]) {
    useWorkspace.getState().loadProject({
      id: r.id,
      name: r.name,
      files: r.snapshot,
      remote: r.remote,
      branch: r.branch,
    });
    setSheet(false);
  }

  if (!all.length) {
    return (
      <div className="proj-empty">
        <p>Nada salvo neste iPad ainda.</p>
        <button type="button" onClick={() => setSheet("new")}>
          Novo projeto
        </button>
        <button type="button" onClick={() => setSheet("clone")}>
          Clonar do GitHub
        </button>
        <button type="button" onClick={() => setSheet("open")}>
          Abrir pasta ou zip
        </button>
      </div>
    );
  }

  return (
    <div className="proj-browser">
      <input
        className="field"
        placeholder="buscar projeto"
        value={q}
        onChange={(e) => setQ(e.target.value)}
      />
      <div className="proj-list">
        {list.length ? (
          list.map((r) => (
            <div key={r.id} className="proj-card">
              <button type="button" className="proj-main" onClick={() => open(r)}>
                <strong>{r.name}</strong>
                <span>
                  {r.files} arquivos · {r.remote || "neste iPad"} ·{" "}
                  {new Date(r.at).toLocaleString("pt-BR", { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" })}
                </span>
              </button>
              {edit === r.id ? (
                <input
                  className="field"
                  defaultValue={r.name}
                  autoFocus
                  aria-label="renomear"
                  onBlur={(e) => {
                    if (e.target.value.trim() && e.target.value !== r.name) rename(r.id, e.target.value);
                    setEdit(null);
                  }}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") (e.target as HTMLInputElement).blur();
                    if (e.key === "Escape") setEdit(null);
                  }}
                />
              ) : null}
              <div className="proj-ops">
                <button type="button" aria-label="renomear" title="Renomear" onClick={() => setEdit(r.id)}>
                  Aa
                </button>
                <button
                  type="button"
                  aria-label="duplicar"
                  title="Duplicar"
                  onClick={() => {
                    const id = duplicate(r.id);
                    if (id) {
                      const copy = useProjects.getState().library.find((x) => x.id === id);
                      if (copy) open(copy);
                    }
                  }}
                >
                  <Copy size={15} />
                </button>
                <button
                  type="button"
                  aria-label="exportar zip"
                  title="Exportar zip"
                  onClick={() => void downloadZip(r.name, r.snapshot)}
                >
                  <Archive size={15} />
                </button>
                <button type="button" aria-label="apagar" title="Apagar" onClick={() => forget(r.id)}>
                  <Trash2 size={15} />
                </button>
              </div>
            </div>
          ))
        ) : (
          <p className="clone-status">nenhum projeto com esse nome</p>
        )}
      </div>
    </div>
  );
}

function NewForm() {
  const github = useProjects((s) => s.github);
  const [name, setName] = useState("");
  const [dest, setDest] = useState<"ipad" | "files" | "github">("ipad");
  const [kind, setKind] = useState<"empty" | "html" | "swift" | "vite">("empty");
  const [org, setOrg] = useState("");
  const [orgs, setOrgs] = useState<GithubOrg[]>([]);
  const [busy, setBusy] = useState("");
  const [err, setErr] = useState("");

  useEffect(() => {
    if (!github) return;
    let live = true;
    void githubOrgs(github.token)
      .then((list) => {
        if (live) setOrgs(list);
      })
      .catch(() => {});
    return () => {
      live = false;
    };
  }, [github]);

  async function create() {
    const title = name.trim() || "sem título";
    setErr("");
    setBusy("criando…");
    try {
      const files = starterFiles(kind, title);
      let remote: string | null = null;
      if (dest === "github") {
        if (!github) throw new Error("conecta o GitHub antes");
        const made = await githubCreateRepo(github.token, title, org || undefined);
        remote = made.remote;
      }
      if (dest === "files") {
        const picker = (window as Window & { showDirectoryPicker?: () => Promise<FileSystemDirectoryHandle> })
          .showDirectoryPicker;
        if (picker) {
          const root = await picker();
          await writeDir(root, files);
        } else {
          await downloadZip(title, files);
        }
      }
      useWorkspace.getState().loadProject({
        id: uidLocal(),
        name: title,
        files,
        remote,
        branch: "main",
        message: "chore: projeto novo",
      });
      useWorkspace.getState().rememberNow();
      setSheet(false);
    } catch (e) {
      if (e instanceof DOMException && e.name === "AbortError") return;
      setErr(e instanceof Error ? e.message : "não criou");
    } finally {
      setBusy("");
    }
  }

  return (
    <form
      className="new-pane"
      onSubmit={(e) => {
        e.preventDefault();
        void create();
      }}
    >
      <label className="new-label">
        Nome
        <input
          className="field"
          placeholder="meu app"
          value={name}
          onChange={(e) => setName(e.target.value)}
          autoFocus
        />
      </label>

      <p className="new-label">Onde guardar</p>
      <div className="new-dests">
        <button type="button" className={dest === "ipad" ? "is-on" : undefined} onClick={() => setDest("ipad")}>
          <Tablet size={18} />
          <b>Neste iPad</b>
          <span>biblioteca do Colo, offline</span>
        </button>
        <button type="button" className={dest === "files" ? "is-on" : undefined} onClick={() => setDest("files")}>
          <FolderOpen size={18} />
          <b>Pasta Files</b>
          <span>escolhe a pasta, ou baixa zip</span>
        </button>
        <button
          type="button"
          className={dest === "github" ? "is-on" : undefined}
          onClick={() => setDest("github")}
          disabled={!github}
        >
          <Github size={18} />
          <b>GitHub</b>
          <span>{github ? `repo novo em @${github.user.login}` : "conecta o GitHub primeiro"}</span>
        </button>
      </div>

      {dest === "github" && github ? (
        <div className="clone-orgs">
          <button type="button" className={!org ? "is-on" : undefined} onClick={() => setOrg("")}>
            @{github.user.login}
          </button>
          {orgs.map((o) => (
            <button
              key={o.login}
              type="button"
              className={org === o.login ? "is-on" : undefined}
              onClick={() => setOrg(o.login)}
            >
              @{o.login}
            </button>
          ))}
        </div>
      ) : null}

      <p className="new-label">Modelo</p>
      <div className="new-kinds">
        {(
          [
            ["empty", "Vazio"],
            ["html", "HTML"],
            ["swift", "SwiftUI"],
            ["vite", "Vite"],
          ] as const
        ).map(([id, label]) => (
          <button
            key={id}
            type="button"
            className={kind === id ? "is-on" : undefined}
            onClick={() => setKind(id)}
          >
            {label}
          </button>
        ))}
      </div>

      {err ? <p className="agent-err">{err}</p> : null}
      <button type="submit" className="new-go" disabled={!!busy}>
        {busy || "Criar projeto"}
      </button>
    </form>
  );
}

function uidLocal() {
  return `p-${Date.now().toString(36)}`;
}

function starterFiles(kind: "empty" | "html" | "swift" | "vite", name: string): Record<string, string> {
  if (kind === "html") {
    return {
      "index.html": `<!doctype html>\n<html lang="pt-BR">\n<head>\n  <meta charset="utf-8" />\n  <meta name="viewport" content="width=device-width, initial-scale=1" />\n  <title>${name}</title>\n  <link rel="stylesheet" href="style.css" />\n</head>\n<body>\n  <main>\n    <h1>${name}</h1>\n    <p>Pronto no iPad.</p>\n  </main>\n  <script src="app.js"></script>\n</body>\n</html>\n`,
      "style.css": `:root { color-scheme: dark; font-family: ui-sans-serif, system-ui; }\nbody { margin: 0; min-height: 100dvh; display: grid; place-items: center; background: #111; color: #f4f4f5; }\nh1 { margin: 0 0 8px; font-size: 28px; }\n`,
      "app.js": `console.log("${name}");\n`,
    };
  }
  if (kind === "swift") {
    return {
      "App.swift": `import SwiftUI\n\n@main\nstruct ${safeIdent(name)}App: App {\n    var body: some Scene {\n        WindowGroup {\n            ContentView()\n        }\n    }\n}\n`,
      "ContentView.swift": `import SwiftUI\n\nstruct ContentView: View {\n    var body: some View {\n        VStack(spacing: 12) {\n            Text("${name}")\n                .font(.largeTitle.bold())\n            Text("Swift no iPad")\n                .foregroundStyle(.secondary)\n        }\n        .padding()\n    }\n}\n\n#Preview { ContentView() }\n`,
    };
  }
  if (kind === "vite") {
    return {
      "package.json": `{\n  "name": "${name.toLowerCase().replace(/\s+/g, "-") || "app"}",\n  "private": true,\n  "type": "module",\n  "scripts": {\n    "dev": "vite",\n    "build": "vite build"\n  },\n  "dependencies": {\n    "vite": "^6.0.0"\n  }\n}\n`,
      "index.html": `<!doctype html>\n<html lang="pt-BR">\n  <head>\n    <meta charset="utf-8" />\n    <meta name="viewport" content="width=device-width, initial-scale=1" />\n    <title>${name}</title>\n  </head>\n  <body>\n    <div id="app"></div>\n    <script type="module" src="/src/main.js"></script>\n  </body>\n</html>\n`,
      "src/main.js": `document.getElementById("app").textContent = "${name}";\n`,
      "src/style.css": `body { margin: 0; font-family: ui-sans-serif, system-ui; }\n`,
      "README.md": `# ${name}\n\nnpm i && npm run dev\n`,
    };
  }
  return { "README.md": `# ${name}\n\nProjeto novo no Colo.\n` };
}

function safeIdent(name: string) {
  const s = name.replace(/[^A-Za-z0-9]/g, "") || "App";
  return s[0]!.toUpperCase() + s.slice(1);
}

async function writeDir(root: FileSystemDirectoryHandle, files: Record<string, string>) {
  for (const [path, text] of Object.entries(files)) {
    const parts = path.split("/").filter(Boolean);
    let dir = root;
    for (const p of parts.slice(0, -1)) {
      dir = await dir.getDirectoryHandle(p, { create: true });
    }
    const file = await dir.getFileHandle(parts.at(-1)!, { create: true });
    const w = await file.createWritable();
    await w.write(text);
    await w.close();
  }
}

function OpenForm() {
  const fileRef = useRef<HTMLInputElement>(null);
  const dirRef = useRef<HTMLInputElement>(null);
  const jsonRef = useRef<HTMLInputElement>(null);
  const zipRef = useRef<HTMLInputElement>(null);
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
    <div className="open-pane">
      <div className="new-dests">
        <button type="button" onClick={() => void fromDirectoryApi()} disabled={!!busy}>
          <FolderOpen size={18} />
          <b>Pasta Files</b>
          <span>{busy || "abre uma pasta do iPad"}</span>
        </button>
        <button type="button" onClick={() => zipRef.current?.click()}>
          <Archive size={18} />
          <b>Arquivo zip</b>
          <span>projeto compactado</span>
        </button>
        <button type="button" onClick={() => jsonRef.current?.click()}>
          <FileJson size={18} />
          <b>JSON do Colo</b>
          <span>backup exportado do app</span>
        </button>
        <button type="button" onClick={() => fileRef.current?.click()}>
          <Files size={18} />
          <b>Vários arquivos</b>
          <span>escolhe um por um</span>
        </button>
        <button type="button" onClick={() => setSheet("recent")}>
          <Tablet size={18} />
          <b>Neste iPad</b>
          <span>biblioteca e recentes</span>
        </button>
        <button type="button" onClick={() => setSheet("clone")}>
          <Github size={18} />
          <b>GitHub</b>
          <span>clonar repo ou org</span>
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
      <input
        ref={jsonRef}
        type="file"
        accept="application/json,.json"
        hidden
        onChange={(e) => void openJson(e).catch((er) => setErr(er instanceof Error ? er.message : "JSON inválido"))}
      />
      <input
        ref={zipRef}
        type="file"
        accept=".zip,application/zip"
        hidden
        onChange={(e) => {
          const f = e.target.files?.[0];
          e.target.value = "";
          if (!f) return;
          setBusy("lendo zip…");
          void importZipFile(f)
            .then((files) => {
              if (!Object.keys(files).length) {
                setErr("zip vazio");
                return;
              }
              useWorkspace.getState().loadProject({
                id: `zip-${Date.now()}`,
                name: f.name.replace(/\.zip$/i, "") || "zip",
                files,
                remote: null,
                message: "importar zip",
              });
              setSheet(false);
            })
            .catch((er) => setErr(er instanceof Error ? er.message : "zip inválido"))
            .finally(() => setBusy(""));
        }}
      />
    </div>
  );
}

function CloneForm() {
  const github = useProjects((s) => s.github);
  const [url, setUrl] = useState("");
  const [busy, setBusy] = useState("");
  const [err, setErr] = useState("");
  const [orgs, setOrgs] = useState<GithubOrg[]>([]);
  const [owner, setOwner] = useState("");
  const [repos, setRepos] = useState<GithubRepo[]>([]);
  const [filter, setFilter] = useState("");
  const [loading, setLoading] = useState(false);

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

  useEffect(() => {
    if (!github) return;
    let live = true;
    void (async () => {
      try {
        const list = await githubOrgs(github.token);
        if (live) setOrgs(list);
      } catch (e) {
        if (live) setErr(e instanceof Error ? e.message : "não listou as orgs");
      }
    })();
    return () => {
      live = false;
    };
  }, [github]);

  useEffect(() => {
    if (!github) return;
    let live = true;
    setLoading(true);
    void (async () => {
      try {
        const list = await githubRepos(github.token, owner || undefined);
        if (live) setRepos(list);
      } catch (e) {
        if (live) setErr(e instanceof Error ? e.message : "não listou os repos");
      } finally {
        if (live) setLoading(false);
      }
    })();
    return () => {
      live = false;
    };
  }, [github, owner]);

  const q = filter.trim().toLowerCase();
  const shown = q
    ? repos.filter((r) => `${r.full} ${r.desc}`.toLowerCase().includes(q))
    : repos;

  return (
    <div className="clone-pane">
      <form
        className="clone-url"
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
        <button type="submit" className="chip is-on" disabled={!!busy}>
          {busy ? "…" : "Clonar"}
        </button>
      </form>
      {busy ? <p className="clone-status">{busy}</p> : null}
      {err ? <p className="agent-err">{err}</p> : null}

      {github ? (
        <>
          <div className="clone-orgs" role="tablist" aria-label="conta ou org">
            <button type="button" className={!owner ? "is-on" : undefined} onClick={() => setOwner("")}>
              @{github.user.login}
            </button>
            {orgs.map((o) => (
              <button
                key={o.login}
                type="button"
                className={owner === o.login ? "is-on" : undefined}
                onClick={() => setOwner(o.login)}
              >
                @{o.login}
              </button>
            ))}
          </div>
          <input
            className="field"
            placeholder="filtrar repositório"
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
          />
          <div className="clone-list">
            {loading ? <p className="clone-status">carregando repos…</p> : null}
            {!loading && !shown.length ? <p className="clone-status">nenhum repo nesta conta</p> : null}
            {shown.map((r) => {
              const name = r.full.split("/")[1] ?? r.full;
              return (
                <button
                  key={r.full}
                  type="button"
                  className="clone-repo"
                  disabled={!!busy}
                  onClick={() => void run(r.full)}
                >
                  <span className="clone-repo-top">
                    <strong>{name}</strong>
                    {r.private ? (
                      <em className="is-priv">
                        <Lock size={11} /> privado
                      </em>
                    ) : (
                      <em>público</em>
                    )}
                  </span>
                  {r.desc ? <span className="clone-desc">{r.desc}</span> : null}
                </button>
              );
            })}
          </div>
        </>
      ) : (
        <button type="button" className="chip" onClick={() => setSheet("github")}>
          conectar GitHub
        </button>
      )}
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
        Cria um token em github.com/settings/tokens (scopes <code>repo</code> e <code>read:org</code>) e cola aqui. Fica só neste iPad.
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

async function exportJson() {
  const s = useWorkspace.getState();
  const blob = new Blob(
    [JSON.stringify({ name: s.projectName, remote: s.remote, files: s.files }, null, 2)],
    { type: "application/octet-stream" },
  );
  return saveBlob(blob, safeName(s.projectName || "colo", "json"));
}
