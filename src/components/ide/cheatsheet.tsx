import { useMemo, useState } from "react";
import { X } from "lucide-react";
import { useChrome } from "@/lib/workspace/chrome";

const GROUPS: { title: string; rows: { keys: string; do: string }[] }[] = [
  {
    title: "Navegar",
    rows: [
      { keys: "⌘ K", do: "Paleta (tudo)" },
      { keys: "⌘ P", do: "Abrir arquivo" },
      { keys: "⌘ Shift P", do: "Comandos" },
      { keys: "⌘ Shift F", do: "Busca no projeto" },
      { keys: "Esc", do: "Fecha overlay" },
    ],
  },
  {
    title: "Editor",
    rows: [
      { keys: "⌘ F", do: "Buscar no arquivo" },
      { keys: "⌘ S", do: "Salvar · formatar se ligado" },
      { keys: "Shift Alt F", do: "Formatar arquivo" },
      { keys: "⌘ /", do: "Esta folha" },
    ],
  },
  {
    title: "Painéis",
    rows: [
      { keys: "⌘ B", do: "Explorer" },
      { keys: "⌘ J", do: "Terminal" },
      { keys: "⌘ \\", do: "Dois arquivos" },
      { keys: "⌘ Shift ↵", do: "Preview" },
    ],
  },
  {
    title: "Agente",
    rows: [{ keys: "⌘ ↵", do: "Enviar ao agente" }],
  },
];

export function Cheatsheet() {
  const open = useChrome((s) => s.cheatsheet);
  const [q, setQ] = useState("");
  const needle = q.trim().toLowerCase();
  const groups = useMemo(
    () =>
      GROUPS.map((g) => ({
        ...g,
        rows: needle
          ? g.rows.filter((r) => `${r.keys} ${r.do}`.toLowerCase().includes(needle))
          : g.rows,
      })).filter((g) => g.rows.length),
    [needle],
  );
  if (!open) return null;
  return (
    <div className="cheat-scrim" onClick={() => useChrome.getState().setCheatsheet(false)}>
      <div className="cheat-card" onClick={(e) => e.stopPropagation()} role="dialog" aria-label="Atalhos">
        <div className="project-sheet-hd">
          <b>Atalhos</b>
          <button
            type="button"
            className="ex-add"
            aria-label="fechar"
            onClick={() => useChrome.getState().setCheatsheet(false)}
          >
            <X size={18} />
          </button>
        </div>
        <div className="cheat-body">
          <input
            className="field"
            placeholder="buscar atalho"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            autoFocus
          />
          {groups.length ? (
            groups.map((g) => (
              <section key={g.title} className="cheat-group">
                <h3>{g.title}</h3>
                <ul>
                  {g.rows.map((r) => (
                    <li key={r.keys}>
                      <span>{r.do}</span>
                      <span className="cheat-keys">
                        {r.keys.split(" ").map((k) => (
                          <kbd key={k}>{k}</kbd>
                        ))}
                      </span>
                    </li>
                  ))}
                </ul>
              </section>
            ))
          ) : (
            <p className="clone-status">nenhum atalho com esse nome</p>
          )}
          <p className="cheat-foot">Magic Keyboard ou teclado externo · ⌘ é Cmd</p>
        </div>
      </div>
    </div>
  );
}