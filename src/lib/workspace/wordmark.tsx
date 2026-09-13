type Props = {
  className?: string;
  alt?: string;
  /** Welcome is always dark; ignore theme. */
  force?: "dark" | "light";
};

export function OdeteWordmark({ className, alt = "Odete", force }: Props) {
  const v = "v=9";
  const dark = (
    <img
      className={`odete-wm-dark ${className ?? ""}`.trim()}
      src={`/brand/odete-wordmark.png?${v}`}
      alt={force === "light" ? "" : alt}
    />
  );
  const light = (
    <img
      className={`odete-wm-light ${className ?? ""}`.trim()}
      src={`/brand/odete-wordmark-light.png?${v}`}
      alt={force === "dark" ? "" : alt}
    />
  );
  if (force === "dark") return dark;
  if (force === "light") return light;
  return (
    <span className="odete-wm">
      {dark}
      {light}
    </span>
  );
}
