import { useEffect, useMemo, useState } from "react";
import { useChrome } from "@/lib/workspace/chrome";
import { useNav } from "@/lib/workspace/nav";
import { formatFile } from "@/lib/workspace/plugins";
import { THEMES } from "@/lib/workspace/themes";
import { ICON_PACKS } from "@/lib/workspace/icons";
import { setSheet } from "@/lib/workspace/projects";
import { useWorkspace } from "@/lib/workspace/store";
import { downloadZip } from "@/lib/workspace/zip";

export function CommandPalette() {
  const open = useChrome((s) => s.palette);
  const kind = useChrome((s) => s.paletteKind);
  const setPalette = useChrome((s) => s.setPalette);
  const setCenter = useChrome((s) => s.setCenter);
  const toggleTerm = useChrome((s) => s.toggleTerm);
  const toggleAgent = useChrome((s) => s.toggleAgent);
  const setSide = useChrome((s) => s.setSide);
  const setCreating = useChrome((s) => s.setCreating);
  const setTheme = useChrome((s) => s.setTheme);
  const setIconPack = useChrome((s) => s.setIconPack);
  const files = useWorkspace((s) => s.files);
  const openFile = useWorkspace((s) => s.openFile);
  const openPath = useWorkspace((s) => s.openPath);
  const writeFile = useWorkspace((s) => s.writeFile);
  const reset = useWorkspace((s) => s.resetWorkspace);
  const [q, setQ] = useState("");
  const [i, setI] = useState(0);

  const items = useMemo(() => {
    const cmds = [
      { id: "find", label: "Buscar no arquivo", hint: "⌘F", run: () => useChrome.getState().setFindOpen(true) },
      { id: "preview", label: "Abrir preview", hint: "⌘⇧Enter", run: () => setCenter("preview") },
      { id: "dual", label: "Dois arquivos", hint: "⌘\\", run: () => setCenter("dual") },
      { id: "diff", label: "Abrir diff", hint: "", run: () => setCenter("diff") },
      { id: "side", label: "Esconder / mostrar explorer", hint: "⌘B", run: () => useChrome.getState().toggleSide() },
      { id: "layout", label: "Restaurar painéis", hint: "", run: () => useChrome.getState().resetLayout() },
      { id: "term", label: "Terminal", hint: "⌘J", run: () => toggleTerm() },
      { id: "agent", label: "Agente", hint: "", run: () => toggleAgent() },
      { id: "mode-chat", label: "Agente: modo chat", hint: "modo", run: () => useChrome.getState().setAgentMode("chat") },
      { id: "mode-plan", label: "Agente: modo plan", hint: "modo", run: () => useChrome.getState().setAgentMode("plan") },
      { id: "mode-build", label: "Agente: modo build", hint: "modo", run: () => useChrome.getState().setAgentMode("build") },
      { id: "zip-export", label: "Exportar zip do projeto", hint: "", run: () => {
        const s = useWorkspace.getState();
        void downloadZip(s.projectName, s.files);
      } },
      { id: "cheat", label: "Atalhos do teclado", hint: "⌘/", run: () => useChrome.getState().setCheatsheet(true) },
      { id: "new", label: "Novo arquivo", hint: "", run: () => { setSide("files"); setCreating(true); } },
      { id: "proj", label: "Projeto…", hint: "", run: () => setSheet("hub") },
      { id: "proj-new", label: "Novo projeto", hint: "", run: () => setSheet("new") },
      { id: "proj-open", label: "Abrir projeto", hint: "", run: () => setSheet("open") },
      { id: "proj-library", label: "Projetos neste iPad", hint: "", run: () => setSheet("library") },
      { id: "proj-recent", label: "Abrir recente", hint: "", run: () => setSheet("recent") },
      { id: "proj-clone", label: "Clonar repo GitHub", hint: "", run: () => setSheet("clone") },
      { id: "proj-gh", label: "Conectar GitHub", hint: "", run: () => setSheet("github") },
      { id: "proj-close", label: "Fechar projeto", hint: "", run: () => useWorkspace.getState().closeProject() },
      { id: "reset", label: "Restaurar workspace exemplo", hint: "", run: () => reset() },
      {
        id: "format",
        label: "Formatar arquivo",
        hint: "Shift+Alt+F",
        run: () => writeFile(openPath, formatFile(openPath, files[openPath] ?? "")),
      },
      { id: "problems", label: "Problemas", hint: "", run: () => setSide("problems") },
      ...THEMES.map((t) => ({
        id: `theme:${t.id}`,
        label: `Tema: ${t.label}`,
        hint: "tema",
        run: () => setTheme(t.id),
      })),
      ...ICON_PACKS.map((p) => ({
        id: `icons:${p.id}`,
        label: `Ícones: ${p.label}`,
        hint: "ícones",
        run: () => setIconPack(p.id),
      })),
    ];
    const fileItems = Object.keys(files)
      .sort()
      .map((p) => ({
        id: `f:${p}`,
        label: p,
        hint: "arquivo",
        run: () => openFile(p),
      }));
    const all = kind === "files" ? fileItems : kind === "cmds" ? cmds : [...cmds, ...fileItems];
    const n = q.trim().toLowerCase();
    const lineOnly = n.match(/^:(\d+)$/);
    if (lineOnly) {
      const line = Number(lineOnly[1]);
      return [{ id: "goto", label: `Ir para linha ${line}`, hint: "ir", run: () => useNav.getState().go(openPath, line) }];
    }
    const withLine = n.match(/^(.+):(\d+)$/);
    if (withLine) {
      const file = Object.keys(files).find((p) => p.toLowerCase().includes(withLine[1]!));
      const line = Number(withLine[2]);
      if (file) {
        return [{
          id: "goto-f",
          label: `${file}:${line}`,
          hint: "ir",
          run: () => {
            openFile(file);
            useNav.getState().go(file, line);
          },
        }];
      }
    }
    return n ? all.filter((x) => x.label.toLowerCase().includes(n)) : all;
  }, [files, q, openFile, reset, setCenter, setCreating, setSide, toggleAgent, toggleTerm, setTheme, setIconPack, writeFile, openPath, kind]);

  useEffect(() => {
    setI(0);
  }, [q, open]);

  useEffect(() => {
    if (!open) setQ("");
  }, [open]);

  if (!open) return null;

  function go(index: number) {
    const item = items[index];
    if (!item) return;
    item.run();
    setPalette(false);
  }

  return (
    <div
      className="palette"
      onClick={() => setPalette(false)}
      onKeyDown={(e) => {
        if (e.key === "Escape") setPalette(false);
      }}
    >
      <div
        className="palette-box"
        role="dialog"
        aria-label="Paleta de comandos"
        onClick={(e) => e.stopPropagation()}
      >
        <input
          autoFocus
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder={kind === "files" ? "abrir arquivo…" : kind === "cmds" ? "comando…" : "arquivo ou comando…"}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown") {
              e.preventDefault();
              setI((n) => Math.min(n + 1, items.length - 1));
            } else if (e.key === "ArrowUp") {
              e.preventDefault();
              setI((n) => Math.max(n - 1, 0));
            } else if (e.key === "Enter") {
              e.preventDefault();
              go(i);
            } else if (e.key === "Escape") {
              setPalette(false);
            }
          }}
        />
        <div className="palette-list">
          {items.length === 0 ? (
            <p className="px-3 py-2 text-xs text-fg-subtle">nada encontrado</p>
          ) : null}
          {items.slice(0, 20).map((it, idx) => (
            <button
              key={it.id}
              type="button"
              className={idx === i ? "palette-item is-on" : "palette-item"}
              onMouseEnter={() => setI(idx)}
              onClick={() => go(idx)}
            >
              <span>{it.label}</span>
              {it.hint ? <kbd>{it.hint}</kbd> : null}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
