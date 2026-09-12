import { useChrome } from "@/lib/workspace/chrome";

const ROWS: { keys: string; do: string }[] = [
  { keys: "⌘ K", do: "Paleta (tudo)" },
  { keys: "⌘ P", do: "Abrir arquivo" },
  { keys: "⌘ Shift P", do: "Comandos" },
  { keys: "⌘ F", do: "Buscar no arquivo" },
  { keys: "⌘ B", do: "Explorer" },
  { keys: "⌘ J", do: "Terminal" },
  { keys: "⌘ ↵", do: "Enviar ao agente" },
  { keys: "⌘ Shift ↵", do: "Preview" },
  { keys: "⌘ \\", do: "Dois arquivos" },
  { keys: "⌘ Shift F", do: "Busca no projeto" },
  { keys: "⌘ S", do: "Formatar (se ligado)" },
  { keys: "Shift Alt F", do: "Formatar arquivo" },
  { keys: "⌘ /", do: "Esta folha" },
  { keys: "Esc", do: "Fecha overlay" },
];

export function Cheatsheet() {
  const open = useChrome((s) => s.cheatsheet);
  if (!open) return null;
  return (
    <div className="cheat-scrim" onClick={() => useChrome.getState().setCheatsheet(false)}>
      <div className="cheat-card" onClick={(e) => e.stopPropagation()} role="dialog" aria-label="Atalhos">
        <header>
          <b>Atalhos</b>
          <span>teclado do iPad</span>
        </header>
        <ul>
          {ROWS.map((r) => (
            <li key={r.keys}>
              <kbd>{r.keys}</kbd>
              <span>{r.do}</span>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
