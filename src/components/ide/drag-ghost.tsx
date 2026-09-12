import { FileGlyph } from "@/components/ide/file-glyph";
import { useDrag } from "@/lib/workspace/drag";

export function DragGhost() {
  const path = useDrag((s) => s.path);
  const x = useDrag((s) => s.x);
  const y = useDrag((s) => s.y);
  if (!path) return null;
  const name = path.split("/").pop() ?? path;
  return (
    <div className="drag-ghost" style={{ left: x, top: y }}>
      <FileGlyph path={path} />
      {name}
    </div>
  );
}

export function DropHint({ side, label }: { side: "left" | "right"; label: string }) {
  const over = useDrag((s) => s.over);
  return (
    <div data-drop={side} className={over === side ? "drop-zone is-hot" : "drop-zone"}>
      {label}
    </div>
  );
}
