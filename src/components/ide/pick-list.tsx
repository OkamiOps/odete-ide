import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { ChevronDown, Star } from "lucide-react";

export function PickList({
  value,
  options,
  onChange,
  disabled,
  compact,
  fill,
  ariaLabel,
  label,
  favorite,
  onFavorite,
}: {
  value: string;
  options: { id: string; label: string }[];
  onChange: (id: string) => void;
  disabled?: boolean;
  compact?: boolean;
  fill?: boolean;
  ariaLabel: string;
  label?: string;
  favorite?: string;
  onFavorite?: (id: string) => void;
}) {
  const btn = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const [box, setBox] = useState({ top: 0, left: 0, width: 220, up: false });
  const current = options.find((o) => o.id === value)?.label ?? options[0]?.label ?? "—";

  function place() {
    const r = btn.current?.getBoundingClientRect();
    if (!r) return;
    const width = Math.max(r.width, compact ? 220 : 280);
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
                  <div key={o.id} className={`pick-opt${o.id === value ? " is-on" : ""}`} role="option" aria-selected={o.id === value}>
                    <button
                      type="button"
                      className="pick-opt-main"
                      onClick={() => {
                        onChange(o.id);
                        setOpen(false);
                      }}
                    >
                      {o.label}
                    </button>
                    {onFavorite ? (
                      <button
                        type="button"
                        className={`pick-fav${o.id === favorite ? " is-on" : ""}`}
                        aria-label={o.id === favorite ? "favorito" : "marcar favorito"}
                        onClick={() => onFavorite(o.id)}
                      >
                        <Star size={14} strokeWidth={2} fill={o.id === favorite ? "currentColor" : "none"} />
                      </button>
                    ) : null}
                  </div>
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
