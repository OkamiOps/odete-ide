import { useEffect, useMemo, useRef, useState } from "react";
import { Plus, MessageSquarePlus, X } from "lucide-react";
import { runShell } from "@/lib/workspace/shell";
import { quoteSelection } from "@/lib/workspace/nav";
import { useChrome } from "@/lib/workspace/chrome";
import { useTerms } from "@/lib/workspace/terms";
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
  const names = useMemo(() => Object.keys(files).sort(), [files]);

  useEffect(() => {
    end.current?.scrollIntoView({ block: "end" });
  }, [tab.lines.length, tab.id]);

  function run(line: string) {
    const t = line.trim();
    if (!t) return;
    useTerms.getState().pushHist(t);
    setHistI(-1);
    runShell(t);
    setCmd("");
  }

  return (
    <div className="flex h-full min-h-0 flex-col bg-bg">
      <div className="pane-hd term-tabs">
        <div className="term-tablist">
          {tabs.map((t) => (
            <button
              key={t.id}
              type="button"
              className={t.id === active ? "is-on" : undefined}
              onClick={() => useTerms.getState().setActive(t.id)}
            >
              {t.name}
              {tabs.length > 1 ? (
                <i
                  onClick={(e) => {
                    e.stopPropagation();
                    useTerms.getState().close(t.id);
                  }}
                >
                  <X size={11} />
                </i>
              ) : null}
            </button>
          ))}
        </div>
        <button type="button" className="term-add" aria-label="novo terminal" title="Novo terminal" onClick={() => useTerms.getState().add()}>
          <Plus size={14} />
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
          <MessageSquarePlus size={14} />
        </button>
        <em>{cwd ? `/${cwd}` : "/"}</em>
      </div>
      <div className="min-h-0 flex-1 overflow-auto px-3 py-2 font-mono text-xs leading-5">
        {tab.lines.map((l) => (
          <pre
            key={l.id}
            className={cn(
              "whitespace-pre-wrap",
              l.kind === "in" && "text-fg",
              l.kind === "err" && "text-danger",
              l.kind === "ok" && "text-ok",
              l.kind === "out" && "text-fg-muted",
            )}
          >
            {l.text}
          </pre>
        ))}
        <div ref={end} />
      </div>
      <form
        className="flex h-11 items-center gap-2 border-t border-border px-3"
        onSubmit={(e) => {
          e.preventDefault();
          run(cmd);
        }}
      >
        <span className="font-mono text-xs text-fg-subtle">%</span>
        <input
          id="colo-term"
          type="text"
          enterKeyHint="enter"
          value={cmd}
          onChange={(e) => {
            setCmd(e.target.value);
            setHistI(-1);
          }}
          onKeyDown={(e) => {
            if (e.key === "ArrowUp") {
              e.preventDefault();
              const hist = tab.hist;
              if (!hist.length) return;
              const next = histI < 0 ? hist.length - 1 : Math.max(0, histI - 1);
              setHistI(next);
              setCmd(hist[next] ?? "");
            }
            if (e.key === "ArrowDown") {
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
          className="h-full min-w-0 flex-1 bg-transparent font-mono text-xs text-fg outline-none placeholder:text-fg-subtle"
          aria-label="comando do terminal"
          autoCapitalize="off"
          autoCorrect="off"
          autoComplete="off"
          spellCheck={false}
        />
        <button type="submit" className="chip shrink-0">
          run
        </button>
      </form>
    </div>
  );
}
