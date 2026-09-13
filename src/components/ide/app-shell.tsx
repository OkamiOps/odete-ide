import { useEffect, useState } from "react";
import { Bot, Eye, FileCode2, Files, Settings, SquareTerminal } from "lucide-react";
import { ActivityBar } from "@/components/ide/activity-bar";
import { AgentPane } from "@/components/ide/agent-pane";
import { CenterPane } from "@/components/ide/center-pane";
import { CommandPalette } from "@/components/ide/command-palette";
import { Cheatsheet } from "@/components/ide/cheatsheet";
import { GhSheet } from "@/components/ide/gh-sheet";
import { useHub } from "@/lib/workspace/hub";
import { DragGhost } from "@/components/ide/drag-ghost";
import { KbBar } from "@/components/ide/kb-bar";
import { ProjectHub } from "@/components/ide/project-hub";
import { FileTree } from "@/components/ide/file-tree";
import { PaneError } from "@/components/ide/pane-error";
import { PreviewPane } from "@/components/ide/preview-pane";
import { SettingsPane } from "@/components/ide/settings-pane";
import { Sidebar } from "@/components/ide/sidebar";
import { TerminalPane } from "@/components/ide/terminal-pane";
import { applyTheme } from "@/components/ide/settings-pane";
import { Splitter, clamp } from "@/components/ide/splitter";
import { useChrome, type MobileTab } from "@/lib/workspace/chrome";
import { freeWorkspaceQuota, restoreAuth } from "@/lib/workspace/secrets";
import { setSheet, useProjects } from "@/lib/workspace/projects";
import { formatFile } from "@/lib/workspace/plugins";
import { useWorkspace } from "@/lib/workspace/store";

function AgentDock() {
  const split = useHub((s) => s.agentSplit);
  if (!split) return <AgentPane slot="a" />;
  return (
    <div className="agent-dock is-split">
      <AgentPane slot="a" />
      <AgentPane slot="b" />
    </div>
  );
}

function useWide() {
  const [wide, setWide] = useState(true);
  useEffect(() => {
    const m = window.matchMedia("(min-width: 640px)");
    const apply = () => setWide(m.matches);
    apply();
    m.addEventListener("change", apply);
    return () => m.removeEventListener("change", apply);
  }, []);
  return wide;
}

export function IdeApp() {
  const mobile = useChrome((s) => s.mobile);
  const agent = useChrome((s) => s.agent);
  const term = useChrome((s) => s.term);
  const side = useChrome((s) => s.side);
  const setPalette = useChrome((s) => s.setPalette);
  const toggleTerm = useChrome((s) => s.toggleTerm);
  const toggleSide = useChrome((s) => s.toggleSide);
  const setCenter = useChrome((s) => s.setCenter);
  const setSide = useChrome((s) => s.setSide);
  const setMobile = useChrome((s) => s.setMobile);
  const theme = useChrome((s) => s.theme);
  const synCustom = useChrome((s) => s.synCustom);
  const wide = useWide();

  useEffect(() => {
    applyTheme(theme, synCustom);
  }, [theme, synCustom]);

  useEffect(() => {
    freeWorkspaceQuota();
    function wait(api: { persist: { hasHydrated: () => boolean; onFinishHydration: (cb: () => void) => () => void } }) {
      return new Promise<void>((res) => {
        if (api.persist.hasHydrated()) return res();
        const un = api.persist.onFinishHydration(() => {
          un();
          res();
        });
      });
    }
    void Promise.all([wait(useChrome), wait(useProjects)]).then(() => restoreAuth());
  }, []);

  useEffect(() => {
    setSheet(false);
  }, []);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      const meta = e.metaKey || e.ctrlKey;
      if (!meta && e.key !== "Escape" && e.key !== "F12") return;
      const code = e.code;
      const key = e.key.length === 1 ? e.key.toLowerCase() : e.key.toLowerCase();
      const is = (letter: string) => key === letter || code === `Key${letter.toUpperCase()}`;

      if (meta && e.shiftKey && is("p")) {
        e.preventDefault();
        e.stopPropagation();
        setPalette(true, "cmds");
        return;
      }
      if (meta && is("p")) {
        e.preventDefault();
        e.stopPropagation();
        setPalette(true, "files");
        return;
      }
      if (meta && is("k")) {
        e.preventDefault();
        e.stopPropagation();
        setPalette(true, "all");
        return;
      }
      if (meta && is("j")) {
        e.preventDefault();
        e.stopPropagation();
        toggleTerm();
        return;
      }
      if (meta && is("b")) {
        e.preventDefault();
        e.stopPropagation();
        toggleSide();
        return;
      }
      if (meta && is("s") && !e.shiftKey) {
        e.preventDefault();
        e.stopPropagation();
        const chrome = useChrome.getState();
        if (chrome.pluginFormat) {
          const ws = useWorkspace.getState();
          ws.writeFile(ws.openPath, formatFile(ws.openPath, ws.files[ws.openPath] ?? ""));
        }
        return;
      }
      if (meta && is("f") && !e.shiftKey) {
        e.preventDefault();
        e.stopPropagation();
        useChrome.getState().setFindOpen(true);
        useChrome.getState().setCenter("code");
        return;
      }
      if (meta && (e.key === "Enter" || code === "Enter") && e.shiftKey) {
        e.preventDefault();
        e.stopPropagation();
        setCenter("preview");
        setMobile("preview");
        return;
      }
      if (meta && (e.key === "Enter" || code === "Enter")) {
        e.preventDefault();
        e.stopPropagation();
        useChrome.getState().toggleAgent();
        useChrome.setState({ agent: true, mobile: "agent" });
        window.dispatchEvent(new CustomEvent("colo-send-agent"));
        return;
      }
      if (e.shiftKey && e.altKey && is("f")) {
        e.preventDefault();
        const ws = useWorkspace.getState();
        ws.writeFile(ws.openPath, formatFile(ws.openPath, ws.files[ws.openPath] ?? ""));
        return;
      }
      if (meta && (e.key === "\\" || code === "Backslash")) {
        e.preventDefault();
        e.stopPropagation();
        setCenter("dual");
        return;
      }
      if (meta && e.shiftKey && is("f")) {
        e.preventDefault();
        e.stopPropagation();
        setSide("search");
        return;
      }
      if (meta && (e.key === "/" || e.key === "?" || code === "Slash")) {
        e.preventDefault();
        e.stopPropagation();
        useChrome.getState().setCheatsheet(!useChrome.getState().cheatsheet);
        return;
      }
      if (e.key === "F12") {
        e.preventDefault();
        window.dispatchEvent(new CustomEvent("colo-goto-def"));
        return;
      }
      if (e.key === "Escape") {
        setPalette(false);
        setSheet(false);
        useChrome.getState().setCheatsheet(false);
        useChrome.getState().setFindOpen(false);
      }
    }
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [setPalette, toggleTerm, setCenter, setSide, setMobile, toggleSide, side]);

  return (
    <div className="ide" data-mobile={mobile}>
      <div className="ide-work">
        {wide ? (
          <>
            <ActivityBar />
            <DesktopColumns agent={agent} term={term} />
          </>
        ) : (
          <PhonePanes />
        )}
      </div>
      <KbBar />
      {wide ? <StatusBar /> : <Dock />}
      <CommandPalette />
      <Cheatsheet />
      <GhSheet />
      <DragGhost />
      <ProjectHub />
    </div>
  );
}

function DesktopColumns({ agent, term }: { agent: boolean; term: boolean }) {
  const sideOpen = useChrome((s) => s.sideOpen);
  const sideW = useChrome((s) => s.sideW);
  const agentW = useChrome((s) => s.agentW);
  const termH = useChrome((s) => s.termH);
  const toggleSide = useChrome((s) => s.toggleSide);
  const toggleAgent = useChrome((s) => s.toggleAgent);
  const toggleTerm = useChrome((s) => s.toggleTerm);
  const split = useHub((s) => s.agentSplit);
  if (split) {
    return (
      <div className="agent-full">
        <AgentDock />
      </div>
    );
  }
  return (
    <div className="desk-wrap">
      <div className="desk">
        {sideOpen ? (
          <>
            <div className="side" style={{ width: sideW, flex: `0 0 ${sideW}px` }}>
              <Sidebar />
            </div>
            <Splitter
              axis="x"
              onDelta={(d) =>
                useChrome.setState((s) => ({ sideW: clamp(s.sideW + d, 180, 520) }))
              }
            />
          </>
        ) : null}
        <div className="desk-main">
          <div className="editor-slot">
            <PaneError name="Editor">
              <CenterPane />
            </PaneError>
          </div>
          {term ? (
            <>
              <Splitter
                axis="y"
                onDelta={(d) =>
                  useChrome.setState((s) => ({ termH: clamp(s.termH - d, 120, 480) }))
                }
              />
              <div className="term-slot" style={{ height: termH, flex: `0 0 ${termH}px` }}>
                <PaneError name="Terminal">
                  <TerminalPane />
                </PaneError>
              </div>
            </>
          ) : null}
        </div>
        {agent ? (
          <>
            <Splitter
              axis="x"
              onDelta={(d) =>
                useChrome.setState((s) => ({ agentW: clamp(s.agentW - d, 240, 720) }))
              }
            />
            <div className="agent-col" style={{ width: agentW, flex: `0 0 ${agentW}px` }}>
              <PaneError name="Agente">
                <AgentDock />
              </PaneError>
            </div>
          </>
        ) : null}
      </div>
      {!sideOpen ? (
        <button type="button" className="edge-open is-left" onClick={toggleSide}>
          Arquivos
        </button>
      ) : null}
      {!agent ? (
        <button type="button" className="edge-open is-right" onClick={toggleAgent}>
          Agente
        </button>
      ) : null}
      {!term ? (
        <button type="button" className="edge-open is-bottom" onClick={toggleTerm}>
          Terminal
        </button>
      ) : null}
    </div>
  );
}

function PhonePanes() {
  return (
    <div className="phone">
      <div className="phone-files">
        <FileTree />
      </div>
      <div className="phone-edit">
        <CenterPane />
      </div>
      <div className="phone-agent">
        <AgentDock />
      </div>
      <div className="phone-term">
        <TerminalPane />
      </div>
      <div className="phone-preview">
        <PreviewPane />
      </div>
      <div className="phone-settings">
        <SettingsPane />
      </div>
    </div>
  );
}

function StatusBar() {
  const projectName = useWorkspace((s) => s.projectName);
  const branch = useWorkspace((s) => s.branch);
  const openPath = useWorkspace((s) => s.openPath);
  const n = useWorkspace((s) => s.commits.length);
  const files = useWorkspace((s) => s.files);
  const head = useWorkspace((s) => s.commits.at(-1)?.files);
  const dirty =
    !head ||
    Object.keys(files).some((k) => files[k] !== head[k]) ||
    Object.keys(head).some((k) => files[k] !== head[k]);
  const theme = useChrome((s) => s.theme);
  const sideOpen = useChrome((s) => s.sideOpen);
  const agent = useChrome((s) => s.agent);
  const term = useChrome((s) => s.term);
  const toggleSide = useChrome((s) => s.toggleSide);
  const toggleAgent = useChrome((s) => s.toggleAgent);
  const toggleTerm = useChrome((s) => s.toggleTerm);
  return (
    <footer className="ide-status">
      <button type="button" onClick={() => setSheet("hub")} title="Projeto">
        <b>{branch}</b> · {projectName}
      </button>
      <button type="button" className={sideOpen ? "is-on" : undefined} onClick={toggleSide}>
        explorer
      </button>
      <button type="button" className={term ? "is-on" : undefined} onClick={toggleTerm}>
        term
      </button>
      <button type="button" className={agent ? "is-on" : undefined} onClick={toggleAgent}>
        agente
      </button>
      <span>{n} commit{n === 1 ? "" : "s"}</span>
      <span>{dirty ? "modificado" : "limpo"}</span>
      <span className="min-w-0 truncate">{openPath}</span>
      <span className="ml-auto">{theme}</span>
      <button type="button" onClick={() => useChrome.getState().setCheatsheet(true)} title="Atalhos">
        atalhos
      </button>
      <span>UTF-8</span>
    </footer>
  );
}

function Dock() {
  const tab = useChrome((s) => s.mobile);
  const setMobile = useChrome((s) => s.setMobile);
  const items: { id: MobileTab; label: string; icon: typeof Files }[] = [
    { id: "files", label: "Arquivos", icon: Files },
    { id: "edit", label: "Editor", icon: FileCode2 },
    { id: "agent", label: "Agente", icon: Bot },
    { id: "term", label: "Term", icon: SquareTerminal },
    { id: "preview", label: "Ver", icon: Eye },
    { id: "settings", label: "Ajustes", icon: Settings },
  ];
  return (
    <nav className="ide-dock" aria-label="Painéis">
      {items.map((it) => {
        const Icon = it.icon;
        return (
          <button
            key={it.id}
            type="button"
            className={tab === it.id ? "is-on" : undefined}
            onClick={() => setMobile(it.id)}
          >
            <Icon className="size-4" strokeWidth={1.6} />
            {it.label}
          </button>
        );
      })}
    </nav>
  );
}
