import { insertAtCursor, moveCursor, sendEscape, sendTab } from "@/lib/workspace/nav";

const KEYS: { id: string; label: string; run: () => void }[] = [
  { id: "esc", label: "esc", run: sendEscape },
  { id: "tab", label: "tab", run: sendTab },
  { id: "l", label: "←", run: () => moveCursor("l") },
  { id: "r", label: "→", run: () => moveCursor("r") },
  { id: "u", label: "↑", run: () => moveCursor("u") },
  { id: "d", label: "↓", run: () => moveCursor("d") },
  { id: "br1", label: "{", run: () => insertAtCursor("{") },
  { id: "br2", label: "}", run: () => insertAtCursor("}") },
  { id: "pa1", label: "(", run: () => insertAtCursor("(") },
  { id: "pa2", label: ")", run: () => insertAtCursor(")") },
  { id: "sq1", label: "[", run: () => insertAtCursor("[") },
  { id: "sq2", label: "]", run: () => insertAtCursor("]") },
  { id: "arr", label: "=>", run: () => insertAtCursor(" => ") },
  { id: "qt", label: '"', run: () => insertAtCursor('"') },
  { id: "bt", label: "`", run: () => insertAtCursor("`") },
  { id: "sc", label: ";", run: () => insertAtCursor(";") },
  { id: "eq", label: "=", run: () => insertAtCursor("=") },
  { id: "sl", label: "/", run: () => insertAtCursor("/") },
];

export function KbBar() {
  return (
    <div className="kb-bar" role="toolbar" aria-label="teclas extra">
      {KEYS.map((k) => (
        <button
          key={k.id}
          type="button"
          onPointerDown={(e) => {
            e.preventDefault();
            k.run();
          }}
        >
          {k.label}
        </button>
      ))}
    </div>
  );
}
