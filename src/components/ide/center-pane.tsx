import { CodeEditor } from "@/components/ide/code-editor";
import { DiffPane } from "@/components/ide/diff-pane";
import { DropHint } from "@/components/ide/drag-ghost";
import { EditorTabs } from "@/components/ide/editor-tabs";
import { PickList } from "@/components/ide/pick-list";
import { PreviewPane } from "@/components/ide/preview-pane";
import { usePatches } from "@/lib/agent/patches";
import { useChrome, type CenterId } from "@/lib/workspace/chrome";
import { useDrag } from "@/lib/workspace/drag";
import { useWorkspace } from "@/lib/workspace/store";
import { isNoisePath } from "@/lib/workspace/ignore";

const MODES: { id: CenterId; label: string }[] = [
  { id: "code", label: "Código" },
  { id: "diff", label: "Diff" },
  { id: "dual", label: "Dois" },
  { id: "split", label: "Split" },
  { id: "preview", label: "Preview" },
];

export function CenterPane() {
  const center = useChrome((s) => s.center);
  const setCenter = useChrome((s) => s.setCenter);
  const crumbs = useChrome((s) => s.pluginCrumbs);
  const altPath = useChrome((s) => s.altPath);
  const editFocus = useChrome((s) => s.editFocus);
  const setEditFocus = useChrome((s) => s.setEditFocus);
  const setAltPath = useChrome((s) => s.setAltPath);
  const openPath = useWorkspace((s) => s.openPath);
  const patchItems = usePatches((s) => s.items);
  const pending = patchItems.filter((p) => p.status === "pending");
  const openFile = useWorkspace((s) => s.openFile);
  const files = useWorkspace((s) => s.files);
  const parts = openPath.split("/").filter(Boolean);
  const names = Object.keys(files).filter((p) => !isNoisePath(p)).sort();
  const opts = names.map((p) => ({ id: p, label: p }));
  const dragging = useDrag((s) => !!s.path);
  const right =
    files[altPath] !== undefined && altPath !== openPath
      ? altPath
      : names.find((p) => p !== openPath) ?? openPath;

  function goDual() {
    if (!files[altPath] || altPath === openPath) {
      const other = names.find((p) => p !== openPath);
      if (other) setAltPath(other);
    }
    setCenter("dual");
  }

  return (
    <section className="center-pane">
      <EditorTabs />
      {pending.length ? (
        <div className="patch-queue">
          {pending.map((p) => (
            <div key={p.id} className="patch-queue-item">
              <button
                type="button"
                onClick={() => {
                  openFile(p.path);
                  setCenter("diff");
                }}
              >
                {p.path}
              </button>
              <button type="button" onClick={() => usePatches.getState().accept(p.id)}>
                ok
              </button>
              <button type="button" onClick={() => usePatches.getState().reject(p.id)}>
                x
              </button>
            </div>
          ))}
        </div>
      ) : null}
      <div className="ed-modes" role="tablist" aria-label="Modo do editor">
        {MODES.map((m) => (
          <button
            key={m.id}
            type="button"
            className={center === m.id ? "is-on" : undefined}
            onClick={() => (m.id === "dual" ? goDual() : setCenter(m.id))}
          >
            {m.label}
          </button>
        ))}
      </div>
      {crumbs && center !== "preview" && center !== "dual" ? (
        <div className="crumbs">
          {parts.map((p, i) => (
            <span key={`${p}-${i}`}>
              {i > 0 ? <i>/</i> : null}
              {p}
            </span>
          ))}
        </div>
      ) : null}
      <div
        className={
          center === "split" || center === "dual"
            ? "center-main is-split min-h-0 flex-1"
            : "center-main min-h-0 flex-1"
        }
      >
        {dragging && center !== "dual" ? (
          <div className="drop-split">
            <DropHint side="left" label="Abrir aqui" />
            <DropHint side="right" label="Dividir à direita" />
          </div>
        ) : null}
        {center === "diff" ? (
          <div className="fill-pane">
            <DiffPane />
          </div>
        ) : null}
        {center === "code" || center === "split" ? (
          <div className="fill-pane">
            <CodeEditor />
          </div>
        ) : null}
        {center === "dual" ? (
          <>
            <div
              className={editFocus === "a" ? "fill-pane is-focus" : "fill-pane"}
              onPointerDown={() => setEditFocus("a")}
            >
              <div className="dual-hd">
                <span>Esq</span>
                <PickList
                  value={openPath}
                  options={opts}
                  onChange={(p) => {
                    openFile(p);
                    setEditFocus("a");
                  }}
                  fill
                  ariaLabel="arquivo da esquerda"
                />
              </div>
              <CodeEditor pane="a" />
              {dragging ? <DropHint side="left" label="Solta à esquerda" /> : null}
            </div>
            <div
              className={editFocus === "b" ? "fill-pane is-focus" : "fill-pane"}
              onPointerDown={() => setEditFocus("b")}
            >
              <div className="dual-hd">
                <span>Dir</span>
                <PickList
                  value={right}
                  options={opts}
                  onChange={(p) => {
                    setAltPath(p);
                    setEditFocus("b");
                  }}
                  fill
                  ariaLabel="arquivo da direita"
                />
              </div>
              <CodeEditor path={right} pane="b" />
              {dragging ? <DropHint side="right" label="Solta à direita" /> : null}
            </div>
          </>
        ) : null}
        {center === "preview" || center === "split" ? (
          <div className="preview-slot">
            <PreviewPane />
          </div>
        ) : null}
      </div>
    </section>
  );
}
