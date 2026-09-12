import { X } from "lucide-react";
import { FileGlyph } from "@/components/ide/file-glyph";
import { useChrome } from "@/lib/workspace/chrome";
import { fileDragHandlers, useDrag } from "@/lib/workspace/drag";
import { useWorkspace } from "@/lib/workspace/store";

export function EditorTabs() {
  const tabs = useWorkspace((s) => s.tabs);
  const openPath = useWorkspace((s) => s.openPath);
  const openFile = useWorkspace((s) => s.openFile);
  const closeTab = useWorkspace((s) => s.closeTab);
  const fileDirty = useWorkspace((s) => s.fileDirty);
  const center = useChrome((s) => s.center);
  const altPath = useChrome((s) => s.altPath);
  const editFocus = useChrome((s) => s.editFocus);

  return (
    <div className="tabs" role="tablist" aria-label="Arquivos abertos">
      {tabs.map((p) => {
        const name = p.split("/").pop() ?? p;
        const on = openPath === p || (center === "dual" && altPath === p);
        return (
          <div key={p} className={on ? "tab is-on" : "tab"} role="tab" aria-selected={on}>
            <button
              type="button"
              className="min-w-0 truncate"
              {...fileDragHandlers(p)}
              onClick={() => {
                if (useDrag.getState().skipClick) return;
                const chrome = useChrome.getState();
                if (chrome.center === "dual" && chrome.editFocus === "b") chrome.setAltPath(p);
                else openFile(p);
              }}
            >
              <FileGlyph path={p} />
              {name}
              {center === "dual" && editFocus === "b" && altPath === p ? " D" : ""}
              {fileDirty(p) ? " ·" : ""}
            </button>
            <button
              type="button"
              className="tab-x"
              aria-label={`fechar ${name}`}
              onClick={() => closeTab(p)}
            >
              <X className="size-3.5" strokeWidth={2} />
            </button>
          </div>
        );
      })}
    </div>
  );
}
