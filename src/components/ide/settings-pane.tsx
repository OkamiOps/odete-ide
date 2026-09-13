import { useEffect, useRef, useState } from "react";
import { Bot, Code2, FolderOpen, Github, History, Palette, Plus, RotateCcw, FolderInput } from "lucide-react";
import { Button } from "@/components/ui/button";
import { FileGlyph } from "@/components/ide/file-glyph";
import { ModelSelect } from "@/components/ide/model-select";
import { AGENTS, type AgentId } from "@/lib/agent/providers";
import { claudeExchange, openaiPollDevice, openaiStartDevice } from "@/lib/agent/oauth";
import { claudeAuthorizeUrl, makePkce, parseClaudeCode } from "@/lib/agent/pkce";
import { useChrome } from "@/lib/workspace/chrome";
import { setSheet } from "@/lib/workspace/projects";
import { useWorkspace } from "@/lib/workspace/store";
import { formatFile, PLUGINS, type PluginId } from "@/lib/workspace/plugins";
import { allSkills, SKILL_TEMPLATE } from "@/lib/workspace/skills";
import {
  installCatalog,
  installFromUrl,
  installMarket,
  installedIds,
  listMarket,
  SKILL_CATALOG,
  skillPath,
  uninstallSkill,
  type MarketItem,
} from "@/lib/workspace/skill-catalog";
import { THEMES, SYN_FIELDS, type ThemeId, type SynKey } from "@/lib/workspace/themes";
import { ICON_PACKS } from "@/lib/workspace/icons";
import { PickList } from "@/components/ide/pick-list";

const PKCE_KEY = "colo-claude-pkce";

const TABS: { id: "look" | "edit" | "agent" | "ws"; label: string; icon: typeof Palette }[] = [
  { id: "look", label: "Tema", icon: Palette },
  { id: "edit", label: "Editor", icon: Code2 },
  { id: "agent", label: "Agente", icon: Bot },
  { id: "ws", label: "Projeto", icon: FolderOpen },
];

const PLUGIN_GROUPS: { title: string; ids: PluginId[] }[] = [
  { title: "Tela", ids: ["wrap", "lineNo", "fold", "breadcrumbs", "whitespace", "indent", "ruler"] },
  { title: "Código", ids: ["linter", "todos", "todoMark", "rainbow", "emmet", "sticky", "gitGutter", "colorHint", "formatOnSave", "comment", "urls"] },
];

export function SettingsPane() {
  const reset = useWorkspace((s) => s.resetWorkspace);
  const projectName = useWorkspace((s) => s.projectName);
  const remote = useWorkspace((s) => s.remote);
  const [tab, setTab] = useState<"look" | "edit" | "agent" | "ws">("look");
  return (
    <div className="set-pane">
      <div className="pane-hd">
        <span className="label">Ajustes</span>
      </div>
      <div className="set-tabs" role="tablist" aria-label="Ajustes">
        {TABS.map((t) => {
          const Icon = t.icon;
          return (
            <button
              key={t.id}
              type="button"
              role="tab"
              aria-selected={tab === t.id}
              className={tab === t.id ? "is-on" : undefined}
              onClick={() => setTab(t.id)}
            >
              <Icon size={18} strokeWidth={1.7} />
              {t.label}
            </button>
          );
        })}
      </div>
      <div className="set-body">
        {tab === "look" ? (
          <>
            <ThemeSection />
            <IconPackSection />
          </>
        ) : null}
        {tab === "edit" ? (
          <>
            <MinimapSection />
            <SynSection />
            <PluginSection />
          </>
        ) : null}
        {tab === "agent" ? (
          <>
            <AgentConnect />
            <SkillsSection />
          </>
        ) : null}
        {tab === "ws" ? (
          <>
            <section className="set-card">
              <h2>Projeto</h2>
              <p>
                <b>{projectName}</b>
                {remote ? ` · ${remote}` : " · neste iPad"}
              </p>
              <div className="set-actions">
                <button type="button" onClick={() => setSheet("open")}>
                  <FolderInput size={16} /> Abrir pasta
                </button>
                <button type="button" onClick={() => setSheet("new")}>
                  <Plus size={16} /> Novo projeto
                </button>
                <button type="button" onClick={() => setSheet("recent")}>
                  <History size={16} /> Recentes
                </button>
                <button type="button" onClick={() => setSheet("clone")}>
                  <Github size={16} /> Clonar repo
                </button>
                <button type="button" onClick={() => setSheet("github")}>
                  <Github size={16} /> GitHub
                </button>
              </div>
            </section>
            <section className="set-card">
              <h2>Atalhos</h2>
              <ul className="set-keys">
                <li><kbd>⌘ K</kbd> paleta</li>
                <li><kbd>⌘ F</kbd> buscar no arquivo</li>
                <li><kbd>⌘ J</kbd> terminal</li>
                <li><kbd>⌘ B</kbd> esconder explorer</li>
                <li><kbd>⌘ S</kbd> formatar</li>
              </ul>
            </section>
            <section className="set-card">
              <h2>Workspace</h2>
              <p>Arquivos, git e terminal neste dispositivo.</p>
              <button type="button" className="set-danger" onClick={() => reset()}>
                <RotateCcw size={14} /> Restaurar exemplo
              </button>
            </section>
          </>
        ) : null}
      </div>
    </div>
  );
}

export function AgentConnect({ embedded = false }: { embedded?: boolean }) {
  const agentId = useChrome((s) => s.agentId);
  const body = (
    <>
      {agentId === "grok" ? <GrokInfo /> : null}
      {agentId === "claude" ? <ClaudeAuth /> : null}
      {agentId === "codex" ? <CodexAuth /> : null}
    </>
  );
  if (embedded) return <div className="space-y-3">{body}</div>;
  return (
    <section className="set-card">
      <h2>Agente</h2>
      <p>Escolhe o provider, o modelo e o login da assinatura.</p>
      <AgentPicker fill />
      <div className="set-agent-body">{body}</div>
    </section>
  );
}

function GrokInfo() {
  return (
    <div className="space-y-3">
      <p>
        Grok já está ligado neste preview. Sem login extra. Modelos vêm da xAI.
      </p>
      <ModelSelect provider="grok" />
    </div>
  );
}

function ClaudeAuth() {
  const auth = useChrome((s) => s.claudeAuth);
  const setAuth = useChrome((s) => s.setClaudeAuth);
  const claude = AGENTS.find((a) => a.id === "claude")!;
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [url, setUrl] = useState("");

  async function start() {
    setErr("");
    const pkce = await makePkce();
    sessionStorage.setItem(PKCE_KEY, JSON.stringify({ verifier: pkce.verifier, state: pkce.state }));
    const href = claudeAuthorizeUrl(pkce.challenge, pkce.state);
    setUrl(href);
  }

  async function finish() {
    let p: { verifier: string; state: string } | null = null;
    try {
      p = JSON.parse(sessionStorage.getItem(PKCE_KEY) || "null");
    } catch {
      p = null;
    }
    if (!p?.verifier) {
      setErr("Comece pelo botão Entrar com Claude.");
      return;
    }
    const parsed = parseClaudeCode(code);
    if (!parsed.code) {
      setErr("Cole o código da página de callback.");
      return;
    }
    setBusy(true);
    setErr("");
    try {
      const r = await claudeExchange({
        data: { code: parsed.code, verifier: p.verifier, state: parsed.state || p.state },
      });
      if (!r.ok) setErr(r.error);
      else {
        setAuth(r.tokens);
        setCode("");
        setUrl("");
        sessionStorage.removeItem(PKCE_KEY);
      }
    } catch (e) {
      setErr(e instanceof Error ? e.message : "falha no OAuth");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-3">
      <p className="text-xs leading-relaxed text-fg-muted">{claude.blurb}</p>
      {auth?.access ? <ModelSelect provider="claude" /> : null}
      {auth?.access ? (
        <div className="flex flex-wrap items-center gap-2">
          <p className="text-xs text-ok">Conectado com a assinatura Claude.</p>
          <Button size="sm" variant="ghost" onClick={() => setAuth(null)}>
            Sair
          </Button>
        </div>
      ) : (
        <>
          {url ? (
            <a
              className="inline-flex h-9 items-center rounded-md bg-accent px-3 text-sm font-medium text-accent-fg"
              href={url}
              target="_blank"
              rel="noopener noreferrer"
            >
              Abrir login Claude
            </a>
          ) : (
            <Button size="sm" variant="primary" onClick={() => void start()}>
              Entrar com Claude
            </Button>
          )}
          {url ? (
            <p className="text-xs text-fg-muted">
              Autorize no Safari. A página devolve um código no formato{" "}
              <span className="font-mono">code#state</span>. Cole abaixo.
            </p>
          ) : null}
          <input
            className="field"
            placeholder="cole o código aqui"
            value={code}
            onChange={(e) => setCode(e.target.value)}
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck={false}
          />
          <Button size="sm" variant="outline" disabled={busy || !code.trim()} onClick={() => void finish()}>
            Concluir OAuth
          </Button>
        </>
      )}
      {err ? <p className="text-xs text-danger">{err}</p> : null}
    </div>
  );
}

function CodexAuth() {
  const auth = useChrome((s) => s.openaiAuth);
  const setAuth = useChrome((s) => s.setOpenaiAuth);
  const def = AGENTS.find((a) => a.id === "codex")!;
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [userCode, setUserCode] = useState("");
  const [verify, setVerify] = useState("");
  const stop = useRef(false);

  useEffect(
    () => () => {
      stop.current = true;
    },
    [],
  );

  async function start() {
    setErr("");
    setBusy(true);
    stop.current = false;
    try {
      const r = await openaiStartDevice({ data: {} });
      if (!r.ok) {
        setErr(r.error);
        setBusy(false);
        return;
      }
      setUserCode(r.userCode);
      setVerify(r.verificationUrl);
      const interval = r.interval * 1000;
      while (!stop.current) {
        await new Promise((res) => setTimeout(res, interval));
        if (stop.current) break;
        const p = await openaiPollDevice({
          data: { deviceAuthId: r.deviceAuthId, userCode: r.userCode },
        });
        if (!p.ok) {
          setErr(p.error);
          break;
        }
        if (!p.pending) {
          setAuth(p.tokens);
          setUserCode("");
          setVerify("");
          break;
        }
      }
    } catch (e) {
      setErr(e instanceof Error ? e.message : "falha no device");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="space-y-3">
      <p className="text-xs leading-relaxed text-fg-muted">{def.blurb}</p>
      <p className="text-xs text-fg-subtle">
        ChatGPT → Ajustes → Segurança → ative Device code authorization.
      </p>
      {auth?.access ? <ModelSelect provider="codex" /> : null}
      {auth?.access ? (
        <div className="flex flex-wrap items-center gap-2">
          <p className="text-xs text-ok">ChatGPT conectado.</p>
          <Button size="sm" variant="ghost" onClick={() => setAuth(null)}>
            Sair
          </Button>
        </div>
      ) : userCode ? (
        <div className="space-y-2">
          <p className="text-xs text-fg-muted">
            Abra{" "}
            <a className="underline" href={verify} target="_blank" rel="noreferrer">
              {verify.replace("https://", "")}
            </a>{" "}
            e digite:
          </p>
          <p className="auth-code">{userCode}</p>
          <p className="text-xs text-fg-subtle">Aguardando autorização…</p>
          <Button
            size="sm"
            variant="ghost"
            onClick={() => {
              stop.current = true;
              setUserCode("");
              setBusy(false);
            }}
          >
            Cancelar
          </Button>
        </div>
      ) : (
        <Button size="sm" variant="primary" disabled={busy} onClick={() => void start()}>
          Conectar ChatGPT
        </Button>
      )}
      {err ? <p className="text-xs text-danger">{err}</p> : null}
    </div>
  );
}

export function AgentPicker({
  compact,
  fill,
  slot,
}: {
  compact?: boolean;
  fill?: boolean;
  slot?: "a" | "b";
}) {
  const agentId = useChrome((s) => (slot ? s.slotAgent?.[slot] ?? s.agentId : s.agentId));
  return (
    <PickList
      compact={compact}
      fill={fill}
      label="Provider"
      ariaLabel="Providers"
      value={agentId}
      options={AGENTS.map((a) => ({ id: a.id, label: a.label }))}
      onChange={(id) => {
        if (slot) useChrome.getState().setSlotAgent(slot, id as AgentId);
        else useChrome.getState().setAgentId(id as AgentId);
      }}
    />
  );
}

function ThemeSection() {
  const theme = useChrome((s) => s.theme);
  const setTheme = useChrome((s) => s.setTheme);
  return (
    <section className="set-card">
      <h2>Tema</h2>
      <p>Toque num cartão pra aplicar no editor e no chrome.</p>
      <div className="theme-grid">
        {THEMES.map((t) => (
          <button
            key={t.id}
            type="button"
            className={theme === t.id ? "theme-card is-on" : "theme-card"}
            onClick={() => setTheme(t.id)}
          >
            <span
              className="theme-swatch"
              style={{
                background: `linear-gradient(135deg, ${t.swatch[0]} 0 38%, ${t.swatch[1]} 38% 62%, ${t.swatch[2]} 62% 100%)`,
              }}
            />
            <span className="theme-meta">
              <b>{t.label}</b>
              <em>{t.blurb}</em>
            </span>
          </button>
        ))}
      </div>
    </section>
  );
}

function IconPackSection() {
  const pack = useChrome((s) => s.iconPack);
  const setIconPack = useChrome((s) => s.setIconPack);
  return (
    <section className="set-card">
      <h2>Ícones</h2>
      <p>Forma do arquivo no explorer e nas abas.</p>
      <div className="icon-pack-grid">
        {ICON_PACKS.map((p) => (
          <button
            key={p.id}
            type="button"
            className={pack === p.id ? "icon-pack is-on" : "icon-pack"}
            onClick={() => setIconPack(p.id)}
          >
            <span className="icon-pack-preview">
              <FileGlyph path="src/main.js" pack={p.id} />
              <FileGlyph path="src/style.css" pack={p.id} />
              <FileGlyph path="index.html" pack={p.id} />
            </span>
            <b>{p.label}</b>
            <em>{p.blurb}</em>
          </button>
        ))}
      </div>
    </section>
  );
}

function SynSection() {
  const syn = useChrome((s) => s.synCustom);
  const setSynColor = useChrome((s) => s.setSynColor);
  const resetSyn = useChrome((s) => s.resetSyn);
  const theme = useChrome((s) => s.theme);
  const live: Record<SynKey, string> = {
    keyword: syn.keyword ?? "",
    string: syn.string ?? "",
    comment: syn.comment ?? "",
    number: syn.number ?? "",
    func: syn.func ?? "",
    type: syn.type ?? "",
  };
  if (typeof document !== "undefined") {
    const cs = getComputedStyle(document.documentElement);
    for (const f of SYN_FIELDS) {
      if (!live[f.id]) live[f.id] = toHex(cs.getPropertyValue(`--syn-${f.id}`).trim()) || "#888888";
    }
  }
  return (
    <section className="set-card">
      <h2>Cores do código</h2>
      <p>Sobrescreve o tema atual. Reset volta ao {THEMES.find((t) => t.id === theme)?.label}.</p>
      <div className="syn-grid">
        {SYN_FIELDS.map((f) => (
          <label key={f.id} className="syn-row">
            <input
              type="color"
              value={live[f.id]}
              aria-label={f.label}
              onChange={(e) => setSynColor(f.id, e.target.value)}
            />
            <span>
              <b>{f.label}</b>
              <code>{live[f.id]}</code>
            </span>
          </label>
        ))}
      </div>
      <button type="button" className="chip mt-3" onClick={resetSyn}>
        Resetar cores
      </button>
    </section>
  );
}

function toHex(value: string) {
  const v = value.trim();
  if (/^#([0-9a-f]{3}|[0-9a-f]{6})$/i.test(v)) {
    if (v.length === 4) {
      const r = v[1]!;
      const g = v[2]!;
      const b = v[3]!;
      return `#${r}${r}${g}${g}${b}${b}`.toLowerCase();
    }
    return v.toLowerCase();
  }
  const m = v.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/i);
  if (!m) return "";
  const hex = (n: string) => Number(n).toString(16).padStart(2, "0");
  return `#${hex(m[1]!)}${hex(m[2]!)}${hex(m[3]!)}`;
}

function MinimapSection() {
  const minimap = useChrome((s) => s.minimap);
  const setMinimap = useChrome((s) => s.setMinimap);
  return (
    <section className="set-card">
      <h2>Minimap</h2>
      <p>O retângulo mostra onde você está. Arrasta pra pular.</p>
      <div className="set-grid-2">
        {(
          [
            ["off", "Off"],
            ["s", "Fino"],
            ["m", "Médio"],
            ["l", "Largo"],
          ] as const
        ).map(([id, label]) => (
          <button
            key={id}
            type="button"
            className={minimap === id ? "chip is-on" : "chip"}
            onClick={() => setMinimap(id)}
          >
            {label}
          </button>
        ))}
      </div>
    </section>
  );
}

function PluginSection() {
  const linter = useChrome((s) => s.pluginLinter);
  const todos = useChrome((s) => s.pluginTodos);
  const wrap = useChrome((s) => s.pluginWrap);
  const formatOnSave = useChrome((s) => s.pluginFormat);
  const crumbs = useChrome((s) => s.pluginCrumbs);
  const space = useChrome((s) => s.pluginSpace);
  const indent = useChrome((s) => s.pluginIndent);
  const lineNo = useChrome((s) => s.pluginLineNo);
  const ruler = useChrome((s) => s.pluginRuler);
  const fold = useChrome((s) => s.pluginFold);
  const colorHint = useChrome((s) => s.pluginColorHint);
  const gitGutter = useChrome((s) => s.pluginGitGutter);
  const todoMark = useChrome((s) => s.pluginTodoMark);
  const rainbow = useChrome((s) => s.pluginRainbow);
  const emmet = useChrome((s) => s.pluginEmmet);
  const sticky = useChrome((s) => s.pluginSticky);
  const comment = useChrome((s) => s.pluginComment);
  const urls = useChrome((s) => s.pluginUrls);
  const setLinter = useChrome((s) => s.setPluginLinter);
  const setTodos = useChrome((s) => s.setPluginTodos);
  const setWrap = useChrome((s) => s.setPluginWrap);
  const setFormat = useChrome((s) => s.setPluginFormat);
  const setCrumbs = useChrome((s) => s.setPluginCrumbs);
  const setSpace = useChrome((s) => s.setPluginSpace);
  const setIndent = useChrome((s) => s.setPluginIndent);
  const setLineNo = useChrome((s) => s.setPluginLineNo);
  const setRuler = useChrome((s) => s.setPluginRuler);
  const setFold = useChrome((s) => s.setPluginFold);
  const setColorHint = useChrome((s) => s.setPluginColorHint);
  const setGitGutter = useChrome((s) => s.setPluginGitGutter);
  const setTodoMark = useChrome((s) => s.setPluginTodoMark);
  const setRainbow = useChrome((s) => s.setPluginRainbow);
  const setEmmet = useChrome((s) => s.setPluginEmmet);
  const setSticky = useChrome((s) => s.setPluginSticky);
  const setComment = useChrome((s) => s.setPluginComment);
  const setUrls = useChrome((s) => s.setPluginUrls);
  const setSide = useChrome((s) => s.setSide);
  const openPath = useWorkspace((s) => s.openPath);
  const files = useWorkspace((s) => s.files);
  const writeFile = useWorkspace((s) => s.writeFile);
  const on: Record<string, boolean> = {
    linter,
    todos,
    wrap,
    formatOnSave,
    breadcrumbs: crumbs,
    whitespace: space,
    indent,
    lineNo,
    ruler,
    fold,
    colorHint,
    gitGutter,
    todoMark,
    rainbow,
    emmet,
    sticky,
    comment,
    urls,
  };
  const set: Record<string, (v: boolean) => void> = {
    linter: setLinter,
    todos: setTodos,
    wrap: setWrap,
    formatOnSave: setFormat,
    breadcrumbs: setCrumbs,
    whitespace: setSpace,
    indent: setIndent,
    lineNo: setLineNo,
    ruler: setRuler,
    fold: setFold,
    colorHint: setColorHint,
    gitGutter: setGitGutter,
    todoMark: setTodoMark,
    rainbow: setRainbow,
    emmet: setEmmet,
    sticky: setSticky,
    comment: setComment,
    urls: setUrls,
  };

  return (
    <>
      {PLUGIN_GROUPS.map((g) => (
        <section key={g.title} className="set-card">
          <h2>{g.title}</h2>
          {g.ids.map((id) => {
            const p = PLUGINS.find((x) => x.id === id);
            if (!p) return null;
            return (
              <div key={p.id} className="plug-row">
                <div>
                  <p className="plug-name">{p.label}</p>
                  <p className="plug-blurb">{p.blurb}</p>
                </div>
                <button
                  type="button"
                  className={on[p.id] ? "toggle is-on" : "toggle"}
                  aria-pressed={on[p.id]}
                  aria-label={p.label}
                  onClick={() => set[p.id]?.(!on[p.id])}
                >
                  <i />
                </button>
              </div>
            );
          })}
        </section>
      ))}
      <div className="set-inline">
        <Button
          size="sm"
          variant="outline"
          onClick={() => {
            const next = formatFile(openPath, files[openPath] ?? "");
            writeFile(openPath, next);
          }}
        >
          Formatar arquivo
        </Button>
        <Button size="sm" variant="ghost" onClick={() => setSide("problems")}>
          Ver problemas
        </Button>
      </div>
    </>
  );
}

function SkillsSection() {
  const files = useWorkspace((s) => s.files);
  const writeFile = useWorkspace((s) => s.writeFile);
  const openFile = useWorkspace((s) => s.openFile);
  const skills = allSkills(files);
  const installed = installedIds(files);
  const [url, setUrl] = useState("");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [market, setMarket] = useState<MarketItem[] | null>(null);

  return (
    <section className="set-card">
      <h2>Skills</h2>
      <p>
        No chat: <code>/frontend-design</code>. Instala do catálogo ou de um SKILL.md no GitHub.
      </p>

      <h3 className="mb-1 text-xs font-medium uppercase tracking-wide text-fg-subtle">Instaladas</h3>
      {skills.map((s) => (
        <div key={s.id} className="skill-row">
          <button type="button" className="skill-row-main" onClick={() => (s.path ? openFile(s.path) : openFile(skillPath(s.id)))}>
            <p className="text-sm">
              <code>/{s.id}</code> {s.name}
            </p>
            <p className="text-xs text-fg-subtle">{s.description}</p>
          </button>
          {installed.has(s.id) || s.path ? (
            <button type="button" className="chip" onClick={() => uninstallSkill(s.id)}>
              remover
            </button>
          ) : (
            <span className="text-xs text-fg-subtle">incluso</span>
          )}
        </div>
      ))}

      <h3 className="mb-1 mt-4 text-xs font-medium uppercase tracking-wide text-fg-subtle">Catálogo</h3>
      {SKILL_CATALOG.map((s) => {
        const on = installed.has(s.id);
        return (
          <div key={s.id} className="skill-row">
            <div>
              <p className="text-sm">
                <code>/{s.id}</code> {s.name}
              </p>
              <p className="text-xs text-fg-subtle">{s.description}</p>
            </div>
            <button
              type="button"
              className={on ? "chip" : "chip is-on"}
              disabled={on}
              onClick={() => {
                const err = installCatalog(s.id);
                setNote(err ?? `instalada /${s.id}`);
                if (!err) openFile(skillPath(s.id));
              }}
            >
              {on ? "ok" : "instalar"}
            </button>
          </div>
        );
      })}

      <h3 className="mb-1 mt-4 text-xs font-medium uppercase tracking-wide text-fg-subtle">Marketplace</h3>
      <p className="mb-2 text-xs text-fg-subtle">Lista skills oficiais em anthropics/skills.</p>
      <button
        type="button"
        className="chip is-on"
        disabled={busy}
        onClick={() => {
          setBusy(true);
          void listMarket()
            .then(setMarket)
            .catch((e) => setNote(e instanceof Error ? e.message : "falhou"))
            .finally(() => setBusy(false));
        }}
      >
        {market ? "atualizar lista" : "buscar no GitHub"}
      </button>
      {market?.map((s) => (
        <div key={`${s.repo}:${s.path}`} className="skill-row">
          <div>
            <p className="text-sm">
              <code>/{s.id}</code> {s.name}
            </p>
            <p className="text-xs text-fg-subtle">{s.repo}</p>
          </div>
          <button
            type="button"
            className={installed.has(s.id) ? "chip" : "chip is-on"}
            disabled={installed.has(s.id) || busy}
            onClick={() => {
              setBusy(true);
              void installMarket(s)
                .then((id) => {
                  setNote(`instalada /${id}`);
                  openFile(skillPath(id));
                })
                .catch((e) => setNote(e instanceof Error ? e.message : "falhou"))
                .finally(() => setBusy(false));
            }}
          >
            {installed.has(s.id) ? "ok" : "instalar"}
          </button>
        </div>
      ))}

      <h3 className="mb-1 mt-4 text-xs font-medium uppercase tracking-wide text-fg-subtle">De um link</h3>
      <p className="mb-2 text-xs text-fg-subtle">URL de um SKILL.md ou repo GitHub (raw / blob).</p>
      <div className="git-branch-row">
        <input
          className="field"
          placeholder="https://github.com/org/repo/blob/main/SKILL.md"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
        />
        <button
          type="button"
          className="chip is-on"
          disabled={!url.trim() || busy}
          onClick={() => {
            setBusy(true);
            setNote("");
            void installFromUrl(url)
              .then((id) => {
                setNote(`instalada /${id}`);
                setUrl("");
                openFile(skillPath(id));
              })
              .catch((e) => setNote(e instanceof Error ? e.message : "falhou"))
              .finally(() => setBusy(false));
          }}
        >
          {busy ? "…" : "instalar"}
        </button>
      </div>
      {note ? <p className="mt-2 text-xs text-fg-muted">{note}</p> : null}
      <div className="mt-3">
        <Button
          size="sm"
          variant="outline"
          onClick={() => {
            const path = ".colo/skills/custom.md";
            if (!files[path]) writeFile(path, SKILL_TEMPLATE);
            openFile(path);
          }}
        >
          Nova skill vazia
        </Button>
      </div>
    </section>
  );
}

export function applyTheme(id: ThemeId, syn?: Record<string, string>) {
  document.documentElement.setAttribute("data-theme", id);
  for (const field of SYN_FIELDS) {
    const value = syn?.[field.id];
    if (value) document.documentElement.style.setProperty(`--syn-${field.id}`, value);
    else document.documentElement.style.removeProperty(`--syn-${field.id}`);
  }
}
