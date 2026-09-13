import { useEffect, useMemo, useRef, useState } from "react";
import { MessageSquarePlus, Play, Plus, X } from "lucide-react";
import { runShellAsync } from "@/lib/workspace/shell";
import { quoteSelection } from "@/lib/workspace/nav";
import { useChrome } from "@/lib/workspace/chrome";
import { useTerms } from "@/lib/workspace/terms";
import { pkgScripts } from "@/lib/workspace/pkg-scripts";
import { useWorkspace } from "@/lib/workspace/store";
import { cn } from "@/lib/utils";

const CMDS = [
  "help",
  "ls",
  "cat",
  "pwd",
  "cd",
  "mkdir",
  "touch",
  "rm",
  "echo",
  "clear",
  "git status",
  "git log",
  "git diff",
  "git add",
  "git commit -m ",
  "git push",
  "git pull",
  "git stash",
  "git stash pop",
  "git blame",
  "npm i",
  "npx vite",
];

function complete(draft: string, files: string[], cwd: string) {
  const parts = draft.split(/\s+/);
  const last = parts[parts.length - 1] ?? "";
  if (parts.length <= 1) {
    const hits = CMDS.filter((c) => c.startsWith(draft));
    return hits[0] ?? draft;
  }
  const names = files
    .map((p) => {
      if (!cwd) return p;
      if (p === cwd || p.startsWith(cwd + "/")) return p.slice(cwd.length ? cwd.length + 1 : 0);
      return p;
    })
    .filter((p) => p.startsWith(last));
  if (!names.length) return draft;
  parts[parts.length - 1] = names[0]!;
  return parts.join(" ");
}

export function TerminalPane() {
  const tabs = useTerms((s) => s.tabs);
  const active = useTerms((s) => s.active);
  const tab = tabs.find((t) => t.id === active) ?? tabs[0]!;
  const cwd = useWorkspace((s) => s.cwd);
  const files = useWorkspace((s) => s.files);
  const [cmd, setCmd] = useState("");
  const [histI, setHistI] = useState(-1);
  const end = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const names = useMemo(() => Object.keys(files).sort(), [files]);
  const scripts = useMemo(() => pkgScripts(files), [files]);

  useEffect(() => {
    function onMsg(e: MessageEvent) {
      const d = e.data as { source?: string; level?: string; args?: unknown };
      if (!d || d.source !== "colo-preview") return;
      const text = Array.isArray(d.args) ? d.args.join(" ") : String(d.args ?? "");
      useTerms.getState().print(d.level === "error" || d.level === "warn" ? "err" : "out", `[vite] ${text}`);
    }
    window.addEventListener("message", onMsg);
    return () => window.removeEventListener("message", onMsg);
  }, []);

  useEffect(() => {
    const el = inputRef.current;
    if (!el) return;
    el.style.height = "0px";
    el.style.height = `${Math.min(140, Math.max(40, el.scrollHeight))}px`;
  }, [cmd]);

  function run(line: string) {
    const t = line.trim();
    if (!t) return;
    useTerms.getState().pushHist(t);
    setHistI(-1);
    void runShellAsync(t).then((out) => {
      if (out && !out.startsWith("ERROR") && /^(npm run |npm start|npx vite|vite|npm dev)/.test(t) && !/\b(build|test|lint)\b/.test(t)) {
        useChrome.getState().setCenter("preview");
      }
    });
    setCmd("");
  }

  return (
    <div className="flex h-full min-h-0 flex-col bg-bg">
      <div className="term-tabs">
        <div className="term-tablist">
          {tabs.map((t) => (
            <div key={t.id} className={cn("term-tab", t.id === active && "is-on")}>
              <button type="button" onClick={() => useTerms.getState().setActive(t.id)}>
                {t.name}
              </button>
              {tabs.length > 1 ? (
                <button
                  type="button"
                  className="term-tab-x"
                  aria-label={`fechar ${t.name}`}
                  onClick={() => useTerms.getState().close(t.id)}
                >
                  <X size={14} />
                </button>
              ) : null}
            </div>
          ))}
        </div>
        <div className="term-tab-ops">
          <button type="button" className="term-add" aria-label="novo terminal" title="Novo terminal" onClick={() => useTerms.getState().add()}>
            <Plus size={16} />
          </button>
          <button
            type="button"
            className="term-add"
            aria-label="Enviar seleção ao agente"
            title="Enviar seleção ao agente"
            onClick={() => {
              if (!quoteSelection()) return;
              useChrome.setState({ agent: true, mobile: "agent" });
            }}
          >
            <MessageSquarePlus size={16} />
          </button>
          <span className="term-cwd">{cwd ? `/${cwd}` : "/"}</span>
        </div>
      </div>
      <div className="term-log">
        {tab.lines.map((l) => (
          <pre
            key={l.id}
            className={cn(
              "term-line",
              l.kind === "in" && "is-in",
              l.kind === "err" && "is-err",
              l.kind === "ok" && "is-ok",
              l.kind === "out" && "is-out",
            )}
          >
            {l.text}
          </pre>
        ))}
        <div ref={end} />
      </div>
      {scripts.length ? (
        <div className="term-scripts">
          {scripts.map((s) => (
            <button key={s} type="button" onClick={() => run(`npm run ${s}`)}>
              {s}
            </button>
          ))}
        </div>
      ) : null}
      <form
        className="term-compose-wrap"
        onSubmit={(e) => {
          e.preventDefault();
          run(cmd);
        }}
      >
        <div className="term-compose">
          <span className="term-prompt">%</span>
          <textarea
            ref={inputRef}
            id="colo-term"
            rows={1}
            enterKeyHint="enter"
            value={cmd}
            onChange={(e) => {
              setCmd(e.target.value);
              setHistI(-1);
            }}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                run(cmd);
                return;
              }
              const atStart = e.currentTarget.selectionStart === 0 && e.currentTarget.selectionEnd === 0;
              if (e.key === "ArrowUp" && atStart) {
                e.preventDefault();
                const hist = tab.hist;
                if (!hist.length) return;
                const next = histI < 0 ? hist.length - 1 : Math.max(0, histI - 1);
                setHistI(next);
                setCmd(hist[next] ?? "");
              }
              if (e.key === "ArrowDown" && e.currentTarget.selectionStart === cmd.length) {
                e.preventDefault();
                const hist = tab.hist;
                if (histI < 0) return;
                const next = histI + 1;
                if (next >= hist.length) {
                  setHistI(-1);
                  setCmd("");
                } else {
                  setHistI(next);
                  setCmd(hist[next] ?? "");
                }
              }
              if (e.key === "Tab") {
                e.preventDefault();
                setCmd(complete(cmd, names, cwd));
              }
            }}
            placeholder="help · git status · npm i"
            className="term-input"
            aria-label="comando do terminal"
            autoCapitalize="off"
            autoCorrect="off"
            autoComplete="off"
            spellCheck={false}
          />
          <button type="submit" className="term-run" aria-label="run">
            <Play size={14} fill="currentColor" />
            Run
          </button>
        </div>
      </form>
    </div>
  );
}
