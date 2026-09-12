import { insertAtCursor, moveCursor, sendEscape, sendTab } from "@/lib/workspace/nav";

const GROUPS: { id: string; label: string; run: () => void }[][] = [
  [
    { id: "esc", label: "esc", run: sendEscape },
    { id: "tab", label: "tab", run: sendTab },
  ],
  [
    { id: "l", label: "←", run: () => moveCursor("l") },
    { id: "u", label: "↑", run: () => moveCursor("u") },
    { id: "d", label: "↓", run: () => moveCursor("d") },
    { id: "r", label: "→", run: () => moveCursor("r") },
  ],
  [
    { id: "br1", label: "{", run: () => insertAtCursor("{") },
    { id: "br2", label: "}", run: () => insertAtCursor("}") },
    { id: "pa1", label: "(", run: () => insertAtCursor("(") },
    { id: "pa2", label: ")", run: () => insertAtCursor(")") },
    { id: "sq1", label: "[", run: () => insertAtCursor("[") },
    { id: "sq2", label: "]", run: () => insertAtCursor("]") },
  ],
  [
    { id: "arr", label: "=>", run: () => insertAtCursor(" => ") },
    { id: "qt", label: '"', run: () => insertAtCursor('"') },
    { id: "bt", label: "`", run: () => insertAtCursor("`") },
    { id: "sc", label: ";", run: () => insertAtCursor(";") },
    { id: "eq", label: "=", run: () => insertAtCursor("=") },
    { id: "sl", label: "/", run: () => insertAtCursor("/") },
  ],
];

export function KbBar() {
  return (
    <div className="kb-bar" role="toolbar" aria-label="teclas extra">
      <div className="kb-inner">
        {GROUPS.map((g, i) => (
          <div key={i} className="kb-group">
            {g.map((k) => (
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
        ))}
      </div>
    </div>
  );
}