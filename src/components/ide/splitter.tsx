import { useRef } from "react";

export function Splitter({
  axis,
  onDelta,
}: {
  axis: "x" | "y";
  onDelta: (delta: number) => void;
}) {
  const last = useRef(0);
  return (
    <div
      className={axis === "x" ? "splitter is-x" : "splitter is-y"}
      role="separator"
      aria-orientation={axis === "x" ? "vertical" : "horizontal"}
      onPointerDown={(e) => {
        e.preventDefault();
        e.stopPropagation();
        const node = e.currentTarget;
        node.setPointerCapture(e.pointerId);
        last.current = axis === "x" ? e.clientX : e.clientY;
        node.classList.add("is-drag");
      }}
      onPointerMove={(e) => {
        if (!e.currentTarget.hasPointerCapture(e.pointerId)) return;
        const now = axis === "x" ? e.clientX : e.clientY;
        const d = now - last.current;
        last.current = now;
        if (d) onDelta(d);
      }}
      onPointerUp={(e) => {
        e.currentTarget.classList.remove("is-drag");
        try {
          e.currentTarget.releasePointerCapture(e.pointerId);
        } catch {
          /* already released */
        }
      }}
    />
  );
}

export function clamp(n: number, min: number, max: number) {
  return Math.min(max, Math.max(min, n));
}
