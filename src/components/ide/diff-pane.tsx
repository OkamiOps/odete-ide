import { useMemo, useState } from "react";
import { fileDiff } from "@/lib/workspace/diff";
import { useWorkspace } from "@/lib/workspace/store";

export function DiffPane() {
  const files = useWorkspace((s) => s.files);
  const commits = useWorkspace((s) => s.commits);
  const openPath = useWorkspace((s) => s.openPath);
  const openFile = useWorkspace((s) => s.openFile);
  const head = commits[commits.length - 1]?.files;
  const changed = useMemo(() => {
    const keys = new Set([...Object.keys(files), ...Object.keys(head ?? {})]);
    return [...keys].filter((k) => files[k] !== head?.[k]).sort();
  }, [files, head]);
  const [pick, setPick] = useState<string | null>(null);
  const path = pick && changed.includes(pick) ? pick : changed.includes(openPath) ? openPath : changed[0];
  const rows = path ? fileDiff(path, files, head) : [];
  const adds = rows.filter((r) => r.kind === "add").length;
  const dels = rows.filter((r) => r.kind === "del").length;

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="pane-hd">
        <span className="label">Diff</span>
        <em>
          {changed.length ? `${changed.length} arq · +${adds} −${dels}` : "limpo"}
        </em>
      </div>
      {changed.length ? (
        <div className="flex gap-1 overflow-auto border-b border-border px-2 py-1">
          {changed.map((p) => (
            <button
              key={p}
              type="button"
              className={p === path ? "chip is-on" : "chip"}
              onClick={() => {
                setPick(p);
                openFile(p);
              }}
            >
              {p.split("/").pop()}
            </button>
          ))}
        </div>
      ) : null}
      <div className="min-h-0 flex-1 overflow-auto font-mono text-xs leading-5">
        {!path ? (
          <p className="p-4 text-fg-muted">Nada modificado desde o último commit.</p>
        ) : (
          rows.map((r, i) => (
            <div key={`${i}:${r.kind}`} className={`diff-line is-${r.kind}`}>
              <span className="diff-mark">
                {r.kind === "add" ? "+" : r.kind === "del" ? "−" : " "}
              </span>
              <span className="diff-code">{r.text || " "}</span>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
