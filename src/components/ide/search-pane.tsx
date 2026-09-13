import { useMemo, useState } from "react";
import { useNav } from "@/lib/workspace/nav";
import { useWorkspace } from "@/lib/workspace/store";

export function SearchPane() {
  const [q, setQ] = useState("");
  const [rep, setRep] = useState("");
  const grep = useWorkspace((s) => s.grep);
  const openFile = useWorkspace((s) => s.openFile);
  const replaceInFiles = useWorkspace((s) => s.replaceInFiles);
  const [note, setNote] = useState("");
  const hits = useMemo(() => {
    if (q.trim().length < 2) return [];
    const raw = grep(q.trim());
    if (raw === "sem resultados" || raw === "regex inválida") return [];
    return raw.split("\n").map((line) => {
      const m = line.match(/^([^:]+):(\d+):\s?(.*)$/);
      return m
        ? { path: m[1]!, line: m[2]!, text: m[3]! }
        : { path: line, line: "", text: "" };
    });
  }, [q, grep]);

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="pane-hd">
        <span className="label">Busca</span>
        <em>{hits.length ? `${hits.length}` : ""}</em>
      </div>
      <div className="search-fields">
        <input
          className="field"
          placeholder="buscar no workspace"
          value={q}
          onChange={(e) => { setQ(e.target.value); setNote(""); }}
          aria-label="buscar"
        />
        <input
          className="field"
          placeholder="substituir por…"
          value={rep}
          onChange={(e) => setRep(e.target.value)}
          aria-label="substituir"
        />
        <button
          type="button"
          className="chip"
          disabled={q.trim().length < 2 || !hits.length}
          onClick={() => {
            const r = replaceInFiles(q.trim(), rep);
            setNote(`${r.hits} em ${r.files} arquivo(s)`);
          }}
        >
          Substituir tudo
        </button>
        <button
          type="button"
          className="chip"
          disabled={q.trim().length < 2}
          onClick={() => {
            const path = useWorkspace.getState().openPath;
            const r = replaceInFiles(q.trim(), rep, path);
            setNote(`${r.hits} em ${path}`);
          }}
        >
          Substituir
        </button>
        {note ? <p className="search-note">{note}</p> : null}
      </div>
      <div className="min-h-0 flex-1 overflow-auto px-1 pb-3">
        {q.trim().length >= 2 && hits.length === 0 ? (
          <p className="px-3 py-2 text-xs text-fg-subtle">sem resultados</p>
        ) : null}
        {hits.map((h, i) => (
          <button
            key={`${h.path}:${h.line}:${i}`}
            type="button"
            className="hit"
            onClick={() => {
              openFile(h.path);
              if (h.line) useNav.getState().go(h.path, Number(h.line));
            }}
          >
            <b>
              {h.path}
              {h.line ? `:${h.line}` : ""}
            </b>
            {h.text}
          </button>
        ))}
      </div>
    </div>
  );
}
