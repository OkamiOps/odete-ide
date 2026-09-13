import { Bot, CircleAlert, Files, GitBranch, Search, Settings } from "lucide-react";
import { useChrome, type SideId } from "@/lib/workspace/chrome";

const ITEMS: { id: SideId; label: string; icon: typeof Files }[] = [
  { id: "files", label: "Arquivos", icon: Files },
  { id: "search", label: "Busca", icon: Search },
  { id: "git", label: "Git", icon: GitBranch },
  { id: "problems", label: "Problemas", icon: CircleAlert },
  { id: "settings", label: "Ajustes", icon: Settings },
];

export function ActivityBar() {
  const side = useChrome((s) => s.side);
  const setSide = useChrome((s) => s.setSide);
  const sideOpen = useChrome((s) => s.sideOpen);
  const toggleSide = useChrome((s) => s.toggleSide);
  const agent = useChrome((s) => s.agent);
  const toggleAgent = useChrome((s) => s.toggleAgent);

  return (
    <nav className="rail" aria-label="Atividade">
      <span className="rail-mark" title="Odete">
        <img src="/brand/odete-icon.png" width={22} height={22} alt="" />
      </span>
      {ITEMS.map((it) => {
        const Icon = it.icon;
        const on = sideOpen && side === it.id;
        return (
          <button
            key={it.id}
            type="button"
            className={on ? "rail-btn is-on" : "rail-btn"}
            title={on ? `Esconder ${it.label}` : `Mostrar ${it.label}`}
            aria-label={it.label}
            aria-pressed={on}
            onClick={() => (on ? toggleSide() : setSide(it.id))}
          >
            <Icon className="size-5" strokeWidth={1.6} />
          </button>
        );
      })}
      <span className="rail-space" />
      <button
        type="button"
        className={agent ? "rail-btn is-on" : "rail-btn"}
        title={agent ? "Esconder agente" : "Mostrar agente"}
        aria-label="Agente"
        aria-pressed={agent}
        onClick={toggleAgent}
      >
        <Bot className="size-5" strokeWidth={1.6} />
      </button>
    </nav>
  );
}
