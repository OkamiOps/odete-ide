import { collectDiags } from "@/lib/workspace/plugins";
import { useChrome } from "@/lib/workspace/chrome";
import { useNav } from "@/lib/workspace/nav";
import { useWorkspace } from "@/lib/workspace/store";

export function ProblemsPane() {
  const files = useWorkspace((s) => s.files);
  const openFile = useWorkspace((s) => s.openFile);
  const linter = useChrome((s) => s.pluginLinter);
  const todos = useChrome((s) => s.pluginTodos);
  const diags = collectDiags(files, { linter, todos });

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="pane-hd">
        <span className="label">Problemas</span>
        <em>{diags.length}</em>
      </div>
      <div className="min-h-0 flex-1 overflow-auto">
        {diags.length === 0 ? (
          <p className="p-4 text-xs text-fg-muted">Nada aqui. Linter e TODOs limpos.</p>
        ) : (
          diags.map((d) => (
            <button
              key={d.id}
              type="button"
              className="hit"
              onClick={() => {
                openFile(d.path);
                useChrome.getState().setCenter("code");
                useNav.getState().go(d.path, d.line);
              }}
            >
              <b>
                {d.path}:{d.line}
              </b>
              <span className={d.severity === "error" ? "text-danger" : "text-fg-muted"}>
                {d.message}
              </span>
            </button>
          ))
        )}
      </div>
    </div>
  );
}
