import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { ChevronDown } from "lucide-react";

export function PickList({
  value,
  options,
  onChange,
  disabled,
  compact,
  fill,
  ariaLabel,
  label,
}: {
  value: string;
  options: { id: string; label: string }[];
  onChange: (id: string) => void;
  disabled?: boolean;
  compact?: boolean;
  fill?: boolean;
  ariaLabel: string;
  label?: string;
}) {
  const btn = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const [box, setBox] = useState({ top: 0, left: 0, width: 220, up: false });
  const current = options.find((o) => o.id === value)?.label ?? options[0]?.label ?? "—";

  function place() {
    const r = btn.current?.getBoundingClientRect();
    if (!r) return;
    const width = Math.max(r.width, compact ? 180 : 260);
    const left = Math.min(r.left, window.innerWidth - width - 8);
    const spaceBelow = window.innerHeight - r.bottom;
    const up = spaceBelow < 240 && r.top > spaceBelow;
    setBox({
      top: up ? r.top - 8 : r.bottom + 6,
      left: Math.max(8, left),
      width,
      up,
    });
  }

  useEffect(() => {
    if (!open) return;
    place();
    function onDoc(e: MouseEvent) {
      const t = e.target as Node;
      if (btn.current?.contains(t) || menu.current?.contains(t)) return;
      setOpen(false);
    }
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") setOpen(false);
    }
    window.addEventListener("mousedown", onDoc);
    window.addEventListener("resize", place);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("mousedown", onDoc);
      window.removeEventListener("resize", place);
      window.removeEventListener("keydown", onKey);
    };
  }, [open]);

  return (
    <>
      <button
        ref={btn}
        type="button"
        className={["pick-btn", compact ? "is-compact" : "", fill ? "is-fill" : "", label ? "has-label" : ""]
          .filter(Boolean)
          .join(" ")}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={ariaLabel}
        disabled={disabled}
        onClick={() => setOpen((v) => !v)}
      >
        {label ? <em>{label}</em> : null}
        <span className="pick-val">
          <span>{current}</span>
          <ChevronDown size={16} strokeWidth={2} />
        </span>
      </button>
      {open
        ? createPortal(
            <div
              ref={menu}
              className="pick-menu"
              role="listbox"
              style={{
                top: box.up ? undefined : box.top,
                bottom: box.up ? window.innerHeight - box.top : undefined,
                left: box.left,
                width: box.width,
              }}
            >
              {options.length ? (
                options.map((o) => (
                  <button
                    key={o.id}
                    type="button"
                    role="option"
                    aria-selected={o.id === value}
                    className={o.id === value ? "is-on" : undefined}
                    onClick={() => {
                      onChange(o.id);
                      setOpen(false);
                    }}
                  >
                    {o.label}
                  </button>
                ))
              ) : (
                <p className="pick-empty">nada pra escolher</p>
              )}
            </div>,
            document.body,
          )
        : null}
    </>
  );
}
