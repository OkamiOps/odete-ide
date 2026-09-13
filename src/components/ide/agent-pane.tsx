import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { AtSign, Check, FolderOpen, History, ImagePlus, LoaderCircle, Paperclip, Plus, Send, Square, SquarePen, Undo2, X } from "lucide-react";
import { AgentConnect } from "@/components/ide/settings-pane";
import { ModelSelect } from "@/components/ide/model-select";
import { contextWindow, estimateTokens, fmtTok, useAgentChats } from "@/lib/agent/chats";
import { defaultEffort, effortKey, EFFORT_HINT, EFFORT_LABEL, effortsForModel, type EffortId } from "@/lib/agent/effort";
import { runAgentLoop, type ChatItem } from "@/lib/agent/loop";
import { usePatches } from "@/lib/agent/patches";
import { AGENTS, agentById } from "@/lib/agent/providers";
import type { AgentImage, AgentMessage } from "@/lib/agent/server";
import type { AgentMode } from "@/lib/agent/tools";
import { hunksOf } from "@/lib/workspace/hunks";
import { authForTurn } from "@/lib/agent/session";
import { agentConnected, currentAgentModel, currentEffort, useChrome } from "@/lib/workspace/chrome";
import { useNav } from "@/lib/workspace/nav";
import { allSkills } from "@/lib/workspace/skills";
import { useWorkspace } from "@/lib/workspace/store";

const STARTERS = [
  { label: "Explica o projeto", prompt: "explica o projeto em poucas linhas" },
  { label: "Muda o titulo pra Olá", prompt: "muda o título da página para Olá" },
  { label: "Faz um commit", prompt: "faz um commit das alterações atuais" },
];

const MODE_META: { id: AgentMode; label: string }[] = [
  { id: "chat", label: "chat" },
  { id: "plan", label: "plan" },
  { id: "build", label: "build" },
];

function expandMentions(text: string) {
  const files = useWorkspace.getState().files;
  return text.replace(/@([^\s]+)/g, (raw, path: string) => {
    const body = files[path];
    if (body === undefined) return raw;
    return `\n\nArquivo ${path}:\n\`\`\`\n${body.slice(0, 6000)}\n\`\`\`\n`;
  });
}

async function fileToImage(file: File): Promise<AgentImage | null> {
  if (!file.type.startsWith("image/")) return null;
  const bmp = await createImageBitmap(file);
  const max = 1280;
  const scale = Math.min(1, max / Math.max(bmp.width, bmp.height));
  const c = document.createElement("canvas");
  c.width = Math.max(1, Math.round(bmp.width * scale));
  c.height = Math.max(1, Math.round(bmp.height * scale));
  c.getContext("2d")!.drawImage(bmp, 0, 0, c.width, c.height);
  const url = c.toDataURL("image/jpeg", 0.72);
  const data = url.split(",")[1] ?? "";
  if (!data) return null;
  return { mime: "image/jpeg", data };
}

export function AgentPane() {
  const agentId = useChrome((s) => s.agentId);
  const connected = useChrome(agentConnected);
  const projectId = useWorkspace((s) => s.projectId);
  const files = useWorkspace((s) => s.files);
  const def = agentById(agentId);
  const [items, setItems] = useState<ChatItem[]>([]);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [shots, setShots] = useState<AgentImage[]>([]);
  const history = useRef<AgentMessage[]>([]);
  const box = useRef<HTMLDivElement>(null);
  const cancel = useRef(false);
  const draftRef = useRef("");
  const sendFn = useRef<(t: string) => void>(() => {});
  const fileRef = useRef<HTMLInputElement>(null);
  const clipRef = useRef<HTMLInputElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const [plus, setPlus] = useState(false);
  const [picker, setPicker] = useState<false | "file" | "skill">(false);
  const [histOpen, setHistOpen] = useState(false);
  const agentMode = useChrome((s) => s.agentMode);
  const threadMap = useAgentChats((s) => s.threads);

  useEffect(() => {
    const t = useAgentChats.getState().load(projectId);
    history.current = t.messages;
    setItems(t.items);
    cancel.current = false;
    setBusy(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId]);

  const saveTimer = useRef<number | null>(null);
  useEffect(() => {
    const el = inputRef.current;
    if (!el) return;
    el.style.height = "0px";
    el.style.height = `${Math.min(180, Math.max(52, el.scrollHeight))}px`;
  }, [draft]);
  useEffect(() => {
    if (!projectId) return;
    if (saveTimer.current) window.clearTimeout(saveTimer.current);
    saveTimer.current = window.setTimeout(() => {
      useAgentChats.getState().save(projectId, items, history.current);
    }, 250);
  }, [items, projectId]);

  useEffect(() => {
    draftRef.current = draft;
  }, [draft]);

  useEffect(() => {
    function onSend() {
      sendFn.current(draftRef.current);
    }
    window.addEventListener("colo-send-agent", onSend);
    return () => window.removeEventListener("colo-send-agent", onSend);
  }, []);

  const atHit = useMemo(() => {
    const m = draft.match(/@([^\s]*)$/);
    if (!m) return null;
    const q = (m[1] ?? "").toLowerCase();
    return Object.keys(files)
      .filter((p) => {
        const base = p.split("/").pop() ?? p;
        return !q || p.toLowerCase().includes(q) || base.toLowerCase().includes(q);
      })
      .slice(0, 8);
  }, [draft, files]);

  const slashHit = useMemo(() => {
    const m = draft.match(/(^|\s)\/([^\s]*)$/);
    if (!m) return null;
    const q = (m[2] ?? "").toLowerCase();
    return allSkills(files)
      .filter((s) => !q || s.id.includes(q) || s.name.toLowerCase().includes(q))
      .slice(0, 8);
  }, [draft, files]);

  const skillMenu = slashHit ?? (picker === "skill" ? allSkills(files).slice(0, 24) : null);
  const fileMenu =
    atHit ?? (picker === "file" ? Object.keys(files).sort().slice(0, 24) : null);

  function clear() {
    cancel.current = true;
    setBusy(false);
    const t = useAgentChats.getState().newChat(projectId);
    history.current = t.messages;
    setItems(t.items);
    setHistOpen(false);
  }

  function openThread(id: string) {
    const t = useAgentChats.getState().open(projectId, id);
    if (!t) return;
    cancel.current = true;
    setBusy(false);
    history.current = t.messages;
    setItems(t.items);
    setHistOpen(false);
  }

  function pickFile(path: string) {
    setPicker(false);
    setPlus(false);
    setDraft((d) => {
      if (/@([^\s]*)$/.test(d)) return d.replace(/@([^\s]*)$/, `@${path} `);
      return `${d}${d && !/\s$/.test(d) ? " " : ""}@${path} `;
    });
  }

  function pickSkill(id: string) {
    setPicker(false);
    setPlus(false);
    setDraft((d) => {
      if (/(^|\s)\/[^\s]*$/.test(d)) return d.replace(/(^|\s)\/[^\s]*$/, `$1/${id} `);
      return `${d}${d && !/\s$/.test(d) ? " " : ""}/${id} `;
    });
  }

  async function send(text: string) {
    const quote = useNav.getState().quote.trim();
    const prompt = text.trim();
    const pics = shots;
    const body = quote
      ? prompt
        ? `Trecho:\n\`\`\`\n${quote}\n\`\`\`\n\n${prompt}`
        : `explica este trecho:\n\`\`\`\n${quote}\n\`\`\``
      : prompt;
    if ((!body && !pics.length) || busy || !connected) return;
    useNav.getState().setQuote("");
    setDraft("");
    setShots([]);
    setBusy(true);
    cancel.current = false;
    const thumbs = pics.map((p) => `data:${p.mime};base64,${p.data}`);
    const userItem: ChatItem = {
      id: crypto.randomUUID(),
      kind: "user",
      text: prompt || (pics.length ? "imagem" : "trecho"),
      images: thumbs,
    };
    setItems((prev) => [...prev, userItem]);
    try {
      const tokens = await authForTurn(agentId);
      const chrome = useChrome.getState();
      const next = await runAgentLoop(
        history.current,
        expandMentions(body),
        (extra) => {
          if (cancel.current) return;
          setItems((prev) => {
            const i = prev.findIndex((p) => p.id === userItem.id);
            const head = i >= 0 ? prev.slice(0, i + 1) : [...prev, userItem];
            return [...head, ...extra];
          });
          requestAnimationFrame(() => {
            box.current?.scrollTo({ top: box.current.scrollHeight });
          });
        },
        {
          provider: agentId,
          model: currentAgentModel(chrome),
          access: tokens.access,
          accountId: tokens.accountId,
          mode: chrome.agentMode,
          effort:
            currentEffort(chrome) ||
            defaultEffort(effortsForModel(chrome.agentId, currentAgentModel(chrome))) ||
            undefined,
        },
        () => cancel.current,
        pics,
      );
      if (!cancel.current) history.current = next;
    } catch (e) {
      if (cancel.current) return;
      setItems((prev) => [
        ...prev,
        {
          id: crypto.randomUUID(),
          kind: "error",
          text: e instanceof Error ? e.message : "falha no agente",
        },
      ]);
    } finally {
      setBusy(false);
    }
  }
  sendFn.current = (t: string) => {
    void send(t);
  };

  const chats = useMemo(
    () =>
      Object.values(threadMap)
        .filter((t) => t.projectId === projectId)
        .sort((a, b) => b.updated - a.updated),
    [threadMap, projectId],
  );
  const empty = connected && items.length === 0;
  const pendingCount = usePatches((s) => s.items.filter((p) => p.status === "pending").length);
  const quote = useNav((s) => s.quote);

  const model = useChrome(currentAgentModel);
  const effortStored = useChrome(currentEffort);
  const options = effortsForModel(agentId, model);
  const effort = (options.includes(effortStored as EffortId) ? effortStored : defaultEffort(options)) as EffortId | "";
  const usedTok = estimateTokens({
    messages: history.current,
    files,
    draft,
    images: shots.length,
  });
  const maxTok = contextWindow(agentId, model);
  const ctxPct = Math.min(100, Math.round((usedTok / Math.max(1, maxTok)) * 100));

  return (
    <div className="agent-pane">
      <div className="agent-hd">
        <div className="agent-hd-top">
          <span className="label">Agente</span>
          <div className="agent-hd-ops">
            <button type="button" className="agent-icon" aria-label="novo chat" title="Novo chat" onClick={clear}>
              <SquarePen size={16} />
            </button>
            <button
              type="button"
              className={`agent-icon${histOpen ? " is-on" : ""}`}
              aria-label="histórico"
              title="Histórico"
              onClick={() => setHistOpen((v) => !v)}
            >
              <History size={16} />
            </button>
          </div>
        </div>
        <div className="agent-pick">
          {AGENTS.map((a) => (
            <button
              key={a.id}
              type="button"
              className={agentId === a.id ? "is-on" : undefined}
              onClick={() => useChrome.getState().setAgentId(a.id)}
            >
              {a.label}
            </button>
          ))}
        </div>
        {connected ? <ModelSelect provider={agentId} compact /> : null}
        {connected && options.length ? (
          <div
            className="agent-effort"
            role="tablist"
            aria-label="effort"
            style={{ gridTemplateColumns: `repeat(${options.length}, minmax(0, 1fr))` }}
          >
            {options.map((id) => (
              <button
                key={id}
                type="button"
                title={EFFORT_HINT[id]}
                className={effort === id ? "is-on" : undefined}
                onClick={() => useChrome.getState().setEffort(effortKey(agentId, model), id)}
              >
                {EFFORT_LABEL[id]}
              </button>
            ))}
          </div>
        ) : null}
        <div className="agent-modes" role="tablist" aria-label="modo do agente">
          {MODE_META.map((m) => (
            <button
              key={m.id}
              type="button"
              role="tab"
              aria-selected={agentMode === m.id}
              className={agentMode === m.id ? "is-on" : undefined}
              onClick={() => useChrome.getState().setAgentMode(m.id)}
            >
              {m.label}
            </button>
          ))}
        </div>
      </div>

      <div ref={box} className="agent-stream">
        {histOpen ? (
          <div className="chat-hist">
            {chats.length ? (
              chats.map((t) => (
                <div key={t.id} className="chat-hist-row">
                  <button type="button" className="chat-hist-main" onClick={() => openThread(t.id)}>
                    <b>{t.title}</b>
                    <span>{ago(t.updated)} · {t.items.filter((i) => i.kind === "user").length} msgs</span>
                  </button>
                  <button
                    type="button"
                    className="agent-icon"
                    aria-label="apagar conversa"
                    onClick={() => {
                      const next = useAgentChats.getState().remove(projectId, t.id);
                      history.current = next.messages;
                      setItems(next.items);
                    }}
                  >
                    <X size={14} />
                  </button>
                </div>
              ))
            ) : (
              <p className="clone-status">nenhuma conversa ainda</p>
            )}
          </div>
        ) : null}
        {!histOpen && !connected ? (
          <div className="agent-auth">
            <AgentConnect embedded />
          </div>
        ) : null}

        {!histOpen && empty ? (
          <div className="agent-empty">
            <p className="agent-empty-kicker">{def.vendor}</p>
            <h3>{def.label} pronto</h3>
            <p>Edita arquivo, git, npm e vite neste iPad. Sem outra máquina.</p>
            <div className="agent-starts">
              {STARTERS.map((s) => (
                <button key={s.label} type="button" onClick={() => void send(s.prompt)}>
                  {s.label}
                </button>
              ))}
            </div>
          </div>
        ) : null}

        {!histOpen
          ? items.map((item) => (
              <Message key={item.id} item={item} />
            ))
          : null}

        {!histOpen && pendingCount > 1 ? (
          <div className="patch-bar">
            <button type="button" onClick={() => usePatches.getState().acceptAll()}>
              Aceitar todos ({pendingCount})
            </button>
            <button type="button" onClick={() => usePatches.getState().rejectAll()}>
              Rejeitar
            </button>
          </div>
        ) : null}

        {busy ? (
          <div className="agent-busy">
            <LoaderCircle className="size-3.5 animate-spin" />
            trabalhando
          </div>
        ) : null}
      </div>

      {connected ? (
        <div className="agent-compose-wrap">
          {skillMenu ? (
            <div className="mention-list">
              {skillMenu.length ? (
                skillMenu.map((s) => (
                  <button
                    key={s.id}
                    type="button"
                    onMouseDown={(e) => {
                      e.preventDefault();
                      pickSkill(s.id);
                    }}
                  >
                    <b>/{s.id}</b>
                    <span>{s.description}</span>
                  </button>
                ))
              ) : (
                <span className="mention-empty">nenhuma skill</span>
              )}
            </div>
          ) : fileMenu ? (
            <div className="mention-list">
              {fileMenu.length ? (
                fileMenu.map((p) => (
                  <button
                    key={p}
                    type="button"
                    onMouseDown={(e) => {
                      e.preventDefault();
                      pickFile(p);
                    }}
                  >
                    {p}
                  </button>
                ))
              ) : (
                <span className="mention-empty">nenhum arquivo</span>
              )}
            </div>
          ) : plus ? (
            <div className="plus-menu">
              <button
                type="button"
                onClick={() => {
                  setPlus(false);
                  fileRef.current?.click();
                }}
              >
                <ImagePlus size={18} />
                Imagem
              </button>
              <button
                type="button"
                onClick={() => {
                  setPlus(false);
                  clipRef.current?.click();
                }}
              >
                <Paperclip size={18} />
                Arquivo
              </button>
              <button
                type="button"
                onClick={() => {
                  setPlus(false);
                  setPicker("file");
                }}
              >
                <AtSign size={18} />
                Mencionar
              </button>
              <button
                type="button"
                onClick={() => {
                  setPlus(false);
                  setPicker("skill");
                }}
              >
                <FolderOpen size={18} />
                Skills
              </button>
            </div>
          ) : null}
          {quote ? (
            <div className="agent-quote">
              <pre>{quote.slice(0, 400)}</pre>
              <button type="button" aria-label="tirar trecho" title="Tirar trecho" onClick={() => useNav.getState().setQuote("")}>
                <X size={14} />
              </button>
            </div>
          ) : null}
          {shots.length ? (
            <div className="agent-shots">
              {shots.map((s, i) => (
                <button
                  key={i}
                  type="button"
                  className="agent-shot"
                  aria-label="tirar imagem"
                  onClick={() => setShots((xs) => xs.filter((_, j) => j !== i))}
                >
                  <img src={`data:${s.mime};base64,${s.data}`} alt="" />
                </button>
              ))}
            </div>
          ) : null}
          <form
            className="agent-compose"
            onSubmit={(e) => {
              e.preventDefault();
              void send(draft);
            }}
          >
            <textarea
              ref={inputRef}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onPaste={(e) => {
                const fromItems = [...e.clipboardData.items]
                  .map((it) => it.getAsFile())
                  .filter((f): f is File => !!f);
                const files = [...e.clipboardData.files, ...fromItems].filter((f) => f.type.startsWith("image/"));
                if (!files.length) return;
                e.preventDefault();
                void Promise.all(files.map(fileToImage)).then((got) => {
                  const ok = got.filter((g): g is AgentImage => !!g);
                  if (ok.length) setShots((xs) => [...xs, ...ok].slice(0, 4));
                });
              }}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) {
                  e.preventDefault();
                  void send(draft);
                }
              }}
              rows={1}
              placeholder={`Fala com o ${def.label}…`}
              className="agent-input"
            />
            <input
              ref={fileRef}
              type="file"
              accept="image/*"
              hidden
              multiple
              onChange={(e) => {
                const files = [...(e.target.files ?? [])];
                e.target.value = "";
                void Promise.all(files.map(fileToImage)).then((got) => {
                  const ok = got.filter(Boolean) as AgentImage[];
                  if (ok.length) setShots((xs) => [...xs, ...ok].slice(0, 4));
                });
              }}
            />
            <input
              ref={clipRef}
              type="file"
              hidden
              multiple
              onChange={(e) => {
                const list = [...(e.target.files ?? [])];
                e.target.value = "";
                void (async () => {
                  for (const f of list) {
                    if (f.type.startsWith("image/")) {
                      const img = await fileToImage(f);
                      if (img) setShots((xs) => [...xs, img].slice(0, 4));
                    } else if (f.size < 200_000) {
                      const text = await f.text();
                      setDraft((d) => `${d}${d ? "\n\n" : ""}Arquivo ${f.name}:\n\`\`\`\n${text.slice(0, 8000)}\n\`\`\`\n`);
                    }
                  }
                })();
              }}
            />
            <div className="agent-compose-bar">
              <button
                type="button"
                className={`agent-icon-btn${plus ? " is-on" : ""}`}
                title="Anexar"
                aria-label="Anexar"
                onClick={() => {
                  setPicker(false);
                  setPlus((v) => !v);
                }}
              >
                <Plus size={20} />
              </button>
              <span className={`agent-ctx${ctxPct >= 85 ? " is-hot" : ctxPct >= 60 ? " is-warm" : ""}`} title="contexto estimado">
                {fmtTok(usedTok)}
                <em>/{fmtTok(maxTok)}</em>
              </span>
              {busy ? (
                <button
                  type="button"
                  className="agent-send is-stop"
                  aria-label="parar"
                  onClick={() => {
                    cancel.current = true;
                    setBusy(false);
                  }}
                >
                  <Square size={14} fill="currentColor" />
                </button>
              ) : (
                <button type="submit" className="agent-send" disabled={!draft.trim() && !quote && !shots.length} aria-label="enviar">
                  <Send size={18} />
                </button>
              )}
            </div>
          </form>
        </div>
      ) : null}
    </div>
  );
}

function ago(ts: number) {
  const s = Math.max(1, Math.round((Date.now() - ts) / 1000));
  if (s < 60) return "agora";
  if (s < 3600) return `${Math.round(s / 60)} min`;
  if (s < 86400) return `${Math.round(s / 3600)} h`;
  return `${Math.round(s / 86400)} d`;
}

function Message({ item }: { item: ChatItem }) {
  if (item.kind === "tool") {
    return (
      <div className="agent-tool">
        <b>{item.name}</b>
        <span className="min-w-0 truncate">{item.detail}</span>
      </div>
    );
  }
  if (item.kind === "error") {
    return <p className="agent-err">{item.text}</p>;
  }
  if (item.kind === "patch") {
    return <PatchCard item={item} />;
  }
  if (item.kind === "think") {
    return (
      <details className="agent-think">
        <summary>
          {item.live ? "Pensando…" : "Pensando"}
        </summary>
        <pre>{item.text}</pre>
      </details>
    );
  }
  if (item.kind === "user") {
    return (
      <div className="agent-msg is-user">
        {item.images?.length ? (
          <div className="agent-shots">
            {item.images.map((src, i) => (
              <img key={i} src={src} alt="" className="agent-shot-img" />
            ))}
          </div>
        ) : null}
        <RichText text={item.text} />
      </div>
    );
  }
  return (
    <div className="agent-msg is-bot">
      <RichText text={item.text} />
    </div>
  );
}

function RichText({ text }: { text: string }) {
  const chunks = text.split(/(```[\s\S]*?```)/g).filter((c) => c.length);
  return (
    <div className="md">
      {chunks.map((chunk, i) => {
        const fence = /^```(\w*)\n?([\s\S]*?)```$/.exec(chunk);
        if (fence) {
          return (
            <pre key={i} className="md-code">
              <code>{fence[2]}</code>
            </pre>
          );
        }
        return (
          <div key={i} className="md-block">
            {chunk.split(/\n{2,}/).map((p, j) => {
              const lines = p.split("\n");
              const list = lines.filter((l) => l.trim()).every((l) => /^\s*[-*]\s/.test(l));
              if (list) {
                return (
                  <ul key={j}>
                    {lines
                      .filter((l) => l.trim())
                      .map((l, k) => (
                        <li key={k}>{inline(l.replace(/^\s*[-*]\s/, ""))}</li>
                      ))}
                  </ul>
                );
              }
              return <p key={j}>{inline(p)}</p>;
            })}
          </div>
        );
      })}
    </div>
  );
}

function inline(s: string): ReactNode[] {
  return s.split(/(`[^`]+`|\*\*[^*]+\*\*)/g).map((part, i) => {
    if (part.startsWith("`") && part.endsWith("`") && part.length > 1) {
      return <code key={i}>{part.slice(1, -1)}</code>;
    }
    if (part.startsWith("**") && part.endsWith("**") && part.length > 3) {
      return <strong key={i}>{part.slice(2, -2)}</strong>;
    }
    return <span key={i}>{part}</span>;
  });
}

function PatchCard({ item }: { item: Extract<ChatItem, { kind: "patch" }> }) {
  const patch = usePatches((s) => s.items.find((p) => p.id === item.patchId));
  const status = patch?.status ?? "pending";
  const after = patch?.after ?? item.after;
  const before = patch?.before ?? item.before;
  const hunks = hunksOf(before, after);
  const add = hunks.reduce((n, h) => n + h.adds.length, 0);
  const del = hunks.reduce((n, h) => n + h.dels.length, 0);
  return (
    <div className={`patch-card is-${status}`}>
      <header>
        <b>{item.path}</b>
        <span>
          +{add} / −{del}
        </span>
      </header>
      {hunks.slice(0, 6).map((h, i) => (
        <div key={h.id} className="patch-hunk">
          <pre>
            {h.dels.slice(0, 3).map((l) => `− ${l}`).join("\n")}
            {h.dels.length && h.adds.length ? "\n" : ""}
            {h.adds.slice(0, 3).map((l) => `+ ${l}`).join("\n")}
          </pre>
          {status === "pending" && hunks.length > 1 ? (
            <button type="button" onClick={() => usePatches.getState().acceptHunk(item.patchId, i)}>
              hunk {i + 1}
            </button>
          ) : null}
        </div>
      ))}
      {status === "pending" ? (
        <div className="patch-ops">
          <button type="button" className="is-ok" onClick={() => usePatches.getState().accept(item.patchId)}>
            <Check size={14} /> Aceitar
          </button>
          <button type="button" onClick={() => usePatches.getState().reject(item.patchId)}>
            <X size={14} /> Rejeitar
          </button>
        </div>
      ) : (
        <div className="patch-ops">
          <em>{status === "accepted" ? "aplicado" : status === "undone" ? "desfeito" : "ignorado"}</em>
          {status === "accepted" ? (
            <button type="button" onClick={() => usePatches.getState().undo(item.patchId)}>
              <Undo2 size={14} /> Desfazer
            </button>
          ) : null}
        </div>
      )}
    </div>
  );
}
