import { kindOf, iconColor, type FileKind, type IconPackId } from "@/lib/workspace/icons";
import { useChrome } from "@/lib/workspace/chrome";

export function FileGlyph({
  path,
  folder,
  open,
  pack: packProp,
}: {
  path: string;
  folder?: boolean;
  open?: boolean;
  pack?: IconPackId;
}) {
  const live = useChrome((s) => s.iconPack);
  const pack = packProp ?? live;
  const kind = kindOf(path, folder, open);
  const color = iconColor(pack, kind);
  return (
    <svg className="file-glyph" viewBox="0 0 16 16" aria-hidden>
      {pack === "lucide" ? <Lucide kind={kind} /> : null}
      {pack === "catppuccin" ? <Catppuccin kind={kind} color={color} /> : null}
      {pack === "material" ? <Material kind={kind} color={color} /> : null}
      {pack === "seti" ? <Seti kind={kind} color={color} /> : null}
      {pack === "nord" ? <Nord kind={kind} color={color} /> : null}
    </svg>
  );
}

function Lucide({ kind }: { kind: FileKind }) {
  const s = { fill: "none" as const, stroke: "currentColor", strokeWidth: 1.35, strokeLinecap: "round" as const, strokeLinejoin: "round" as const };
  if (kind === "folder" || kind === "folder-open") {
    return (
      <path
        {...s}
        d={
          kind === "folder-open"
            ? "M1.2 4.1h4.1l1 1.2h8.5v7.4H1.2V4.1Zm0 3.2h13.6"
            : "M1.3 3.4h4.2l1.1 1.4H14.7v7.8H1.3V3.4Z"
        }
      />
    );
  }
  if (kind === "js" || kind === "ts") {
    return <text x="8" y="11.2" textAnchor="middle" fill="currentColor" fontSize="6.2" fontWeight="700" fontFamily="ui-sans-serif">{kind === "js" ? "JS" : "TS"}</text>;
  }
  if (kind === "jsx" || kind === "tsx") {
    return (
      <>
        <ellipse cx="8" cy="8" rx="5.2" ry="2.1" {...s} transform="rotate(-50 8 8)" />
        <ellipse cx="8" cy="8" rx="5.2" ry="2.1" {...s} transform="rotate(50 8 8)" />
        <circle cx="8" cy="8" r="1.05" fill="currentColor" />
      </>
    );
  }
  if (kind === "html") return <path {...s} d="M4.2 4.4 1.8 8l2.4 3.6M11.8 4.4 14.2 8l-2.4 3.6M9.3 3.6 6.7 12.4" />;
  if (kind === "css") return <path {...s} d="M4.4 3.8h7.2L10.8 12.4H5.2L4.4 3.8Zm1.5 2.4h5.2" />;
  if (kind === "json") return <path {...s} d="M6 3.6c-1.8.4-2.6 1.6-2.6 4.4s.8 4 2.6 4.4M10 3.6c1.8.4 2.6 1.6 2.6 4.4s-.8 4-2.6 4.4" />;
  if (kind === "md") return <path {...s} d="M3.2 4.2h9.6v7.6H3.2V4.2Zm1.6 5.8V6.1l2 2.4 2-2.4v3.9" />;
  if (kind === "swift") return <path {...s} d="M3.4 10.4c2.4-1 5.6-4.4 7.6-7.2-1.8 3.4-2 6.2.2 8.2-3.2.2-5.6-.4-7.8-1" />;
  if (kind === "npm") return <path {...s} d="M3.2 3.6h9.6v8.8H8.6V6.4H7.4v6H3.2V3.6Z" />;
  if (kind === "git") {
    return (
      <>
        <circle cx="4.4" cy="8" r="1.3" fill="currentColor" />
        <circle cx="11.2" cy="4.6" r="1.3" fill="currentColor" />
        <circle cx="11.2" cy="11.4" r="1.3" fill="currentColor" />
        <path {...s} d="M5.7 8H8.8V4.6M8.8 8v3.4" />
      </>
    );
  }
  if (kind === "img") return <path {...s} d="M2.6 4h10.8v8H2.6V4Zm1.4 6.4 2.4-2.6 1.8 1.8 2-2.2 2.6 3" />;
  if (kind === "sh") return <path {...s} d="M4.2 5.2 7.2 8l-3 2.8M8.4 11.2h3.6" />;
  return <path {...s} d="M4.2 2.4h5.2L12.4 5.4v8.2H4.2V2.4Zm5.2 0v3h3" />;
}

function Catppuccin({ kind, color }: { kind: FileKind; color: string }) {
  if (kind === "folder" || kind === "folder-open") {
    return (
      <>
        <path fill={color} d="M1 3.2h4.6l1.1 1.5H15v1.4H1V3.2Z" opacity="0.85" />
        <path fill={color} d={kind === "folder-open" ? "M1 6.1 2.4 13h11.4L15 6.1H1Z" : "M1 5.8h14V13H1V5.8Z"} />
        {kind === "folder-open" ? <path fill="#000" opacity="0.22" d="M1 6.1h14l-1.2 6.9H2.4Z" /> : null}
      </>
    );
  }
  const inner = catMark(kind);
  return (
    <>
      <rect x="1" y="1" width="14" height="14" rx="4.2" fill={color} />
      {inner}
    </>
  );
}

function catMark(kind: FileKind) {
  const f = "#1e1e2e";
  if (kind === "js") {
    return <text x="8" y="11.2" textAnchor="middle" fill={f} fontSize="7" fontWeight="800" fontFamily="ui-sans-serif, system-ui">JS</text>;
  }
  if (kind === "ts") {
    return <text x="8" y="11.2" textAnchor="middle" fill={f} fontSize="7" fontWeight="800" fontFamily="ui-sans-serif, system-ui">TS</text>;
  }
  if (kind === "jsx" || kind === "tsx") {
    return (
      <>
        <ellipse cx="8" cy="8" rx="4.4" ry="1.7" fill="none" stroke={f} strokeWidth="1.15" transform="rotate(-50 8 8)" />
        <ellipse cx="8" cy="8" rx="4.4" ry="1.7" fill="none" stroke={f} strokeWidth="1.15" transform="rotate(50 8 8)" />
        <circle cx="8" cy="8" r="0.95" fill={f} />
      </>
    );
  }
  if (kind === "html") return <path d="M4.1 5.1 2.4 8l1.7 2.9M11.9 5.1 13.6 8l-1.7 2.9M9.4 4.6 6.6 11.4" fill="none" stroke={f} strokeWidth="1.4" strokeLinecap="round" />;
  if (kind === "css") return <path d="M4.8 4.6h6.4l-.7 7-2.5.8-2.5-.8-.7-7Zm1.4 2h3.8" fill="none" stroke={f} strokeWidth="1.25" strokeLinejoin="round" />;
  if (kind === "json") return <path d="M5.4 4.4c-1.4.3-2 1.3-2 3.6s.6 3.3 2 3.6M10.6 4.4c1.4.3 2 1.3 2 3.6s-.6 3.3-2 3.6" fill="none" stroke={f} strokeWidth="1.4" strokeLinecap="round" />;
  if (kind === "md") return <path d="M3.6 4.8h8.8v6.4H3.6V4.8Zm1.4 4.6V6.4L7 8.6l2-2.2v3" fill="none" stroke={f} strokeWidth="1.2" strokeLinejoin="round" />;
  if (kind === "swift") return <path d="M3.6 10.2c2.2-.8 5.2-3.8 7-6.4-1.6 3-1.8 5.4.4 7.2-2.8.2-5-.4-7.4-.8Z" fill={f} />;
  if (kind === "npm") return <path d="M3.8 4.4h8.4v7.2H8.6V6.6H7.4v5H3.8V4.4Z" fill={f} />;
  if (kind === "git") {
    return (
      <>
        <circle cx="5" cy="8" r="1.2" fill={f} />
        <circle cx="10.6" cy="5.2" r="1.2" fill={f} />
        <circle cx="10.6" cy="10.8" r="1.2" fill={f} />
        <path d="M6.2 8h2.6V5.2M8.8 8v2.8" fill="none" stroke={f} strokeWidth="1.15" />
      </>
    );
  }
  if (kind === "img") return <path d="M3.4 4.6h9.2v6.8H3.4V4.6Zm1.2 5 2-2.1 1.5 1.5 1.8-2 2.2 2.6" fill="none" stroke={f} strokeWidth="1.15" />;
  if (kind === "sh") return <path d="M4.6 5.6 7.4 8l-2.8 2.4M8.4 10.8h3.2" fill="none" stroke={f} strokeWidth="1.4" strokeLinecap="round" />;
  return <path d="M4.6 3.6h4.6L11.6 6v6.6H4.6V3.6Zm4.6 0v2.4h2.4" fill="none" stroke={f} strokeWidth="1.2" />;
}

function Material({ kind, color }: { kind: FileKind; color: string }) {
  if (kind === "folder" || kind === "folder-open") {
    const tab = "#ffc107";
    const body = kind === "folder-open" ? "#ffca28" : "#ffc107";
    return (
      <>
        <path fill={tab} d="M1 2.8h5.1l1.2 1.6H15V5.4H1V2.8Z" />
        <path fill={body} d={kind === "folder-open" ? "M1 5.4 2.5 13.2h11.2L15 5.4H1Z" : "M1 5.2h14v8H1V5.2Z"} />
        {kind === "folder-open" ? <path fill="#ffe082" d="M1 5.4h14v1.3H1z" /> : null}
      </>
    );
  }
  const dark = shade(color, -0.35);
  return (
    <>
      <path fill={color} d="M3 1.4h6.2L13 5.2v9.4H3V1.4Z" />
      <path fill={dark} d="M9.2 1.4 13 5.2H9.2V1.4Z" opacity="0.55" />
      <rect x="3" y="10.2" width="10" height="4.4" fill={dark} />
      <text x="8" y="13.45" textAnchor="middle" fill="#fff" fontSize="3.7" fontWeight="800" fontFamily="ui-sans-serif, system-ui">
        {matLabel(kind)}
      </text>
    </>
  );
}

function matLabel(kind: FileKind) {
  if (kind === "js" || kind === "jsx") return "JS";
  if (kind === "ts" || kind === "tsx") return "TS";
  if (kind === "html") return "HTML";
  if (kind === "css") return "CSS";
  if (kind === "json") return "{ }";
  if (kind === "md") return "MD";
  if (kind === "swift") return "SW";
  if (kind === "npm") return "NPM";
  if (kind === "git") return "GIT";
  if (kind === "img") return "IMG";
  if (kind === "sh") return "SH";
  return "FILE";
}

function Seti({ kind, color }: { kind: FileKind; color: string }) {
  if (kind === "folder" || kind === "folder-open") {
    return <path fill={color} d="M1.4 3.2h4.4l1 1.3h7.8v8.3H1.4V3.2Zm0 2.6h13.2" />;
  }
  return (
    <>
      <circle cx="8" cy="8" r="6.1" fill={color} />
      <text x="8" y="10.4" textAnchor="middle" fill="#1a1a1a" fontSize="5.6" fontWeight="800" fontFamily="ui-sans-serif">
        {setiLetter(kind)}
      </text>
    </>
  );
}

function setiLetter(kind: FileKind) {
  if (kind === "js" || kind === "jsx") return "JS";
  if (kind === "ts" || kind === "tsx") return "TS";
  if (kind === "html") return "H";
  if (kind === "css") return "C";
  if (kind === "json") return "{}";
  if (kind === "md") return "M";
  if (kind === "swift") return "S";
  if (kind === "npm") return "N";
  if (kind === "git") return "G";
  if (kind === "img") return "I";
  if (kind === "sh") return ">";
  return "·";
}

function Nord({ kind, color }: { kind: FileKind; color: string }) {
  if (kind === "folder" || kind === "folder-open") {
    return (
      <path
        fill={color}
        d={
          kind === "folder-open"
            ? "M1.2 4h4.2l1 1.2h8.4v2.1l-1.3 6.4H2.6L1.2 7.3V4Z"
            : "M1.4 3.2h4.4l1.1 1.4h7.7v8.2H1.4V3.2Z"
        }
      />
    );
  }
  return (
    <>
      <rect x="2.2" y="2.2" width="11.6" height="11.6" rx="1.2" transform="rotate(45 8 8)" fill={color} />
      <text x="8" y="10.2" textAnchor="middle" fill="#2e3440" fontSize="5.2" fontWeight="800" fontFamily="ui-sans-serif">
        {setiLetter(kind)}
      </text>
    </>
  );
}

function shade(hex: string, t: number) {
  const h = hex.length === 4 ? `#${[...hex.slice(1)].map((c) => c + c).join("")}` : hex;
  const n = parseInt(h.slice(1), 16);
  const mix = (ch: number) => Math.max(0, Math.min(255, Math.round(ch * (1 + t))));
  const r = mix((n >> 16) & 255);
  const g = mix((n >> 8) & 255);
  const b = mix(n >> 0 & 255);
  return `#${[r, g, b].map((v) => v.toString(16).padStart(2, "0")).join("")}`;
}
