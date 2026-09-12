import { extOf } from "@/lib/utils";

export type IconPackId = "lucide" | "catppuccin" | "material" | "seti" | "nord";

export type FileKind =
  | "folder"
  | "folder-open"
  | "js"
  | "jsx"
  | "ts"
  | "tsx"
  | "html"
  | "css"
  | "json"
  | "md"
  | "swift"
  | "npm"
  | "git"
  | "img"
  | "sh"
  | "file";

export const ICON_PACKS: { id: IconPackId; label: string; blurb: string }[] = [
  { id: "lucide", label: "Lucide", blurb: "Traço fino, outline." },
  { id: "catppuccin", label: "Catppuccin", blurb: "Pastel arredondado, mocha." },
  { id: "material", label: "Material", blurb: "Documento com aba, VS Code." },
  { id: "seti", label: "Seti", blurb: "Círculos do Atom." },
  { id: "nord", label: "Nord", blurb: "Losango polar." },
];

const COLORS: Record<IconPackId, Record<FileKind, string>> = {
  lucide: {
    folder: "currentColor",
    "folder-open": "currentColor",
    js: "currentColor",
    jsx: "currentColor",
    ts: "currentColor",
    tsx: "currentColor",
    html: "currentColor",
    css: "currentColor",
    json: "currentColor",
    md: "currentColor",
    swift: "currentColor",
    npm: "currentColor",
    git: "currentColor",
    img: "currentColor",
    sh: "currentColor",
    file: "currentColor",
  },
  catppuccin: {
    folder: "#f9e2af",
    "folder-open": "#f9e2af",
    js: "#f9e2af",
    jsx: "#94e2d5",
    ts: "#89b4fa",
    tsx: "#89dceb",
    html: "#fab387",
    css: "#cba6f7",
    json: "#f9e2af",
    md: "#89b4fa",
    swift: "#fab387",
    npm: "#a6e3a1",
    git: "#fab387",
    img: "#f5c2e7",
    sh: "#a6e3a1",
    file: "#cdd6f4",
  },
  material: {
    folder: "#ffca28",
    "folder-open": "#ffca28",
    js: "#ffca28",
    jsx: "#00bcd4",
    ts: "#0288d1",
    tsx: "#0288d1",
    html: "#e44d26",
    css: "#42a5f5",
    json: "#fbc02d",
    md: "#42a5f5",
    swift: "#ff6e40",
    npm: "#8bc34a",
    git: "#e64a19",
    img: "#26a69a",
    sh: "#4caf50",
    file: "#90a4ae",
  },
  seti: {
    folder: "#4d78cc",
    "folder-open": "#4d78cc",
    js: "#f1e05a",
    jsx: "#61dafb",
    ts: "#3178c6",
    tsx: "#3178c6",
    html: "#e34c26",
    css: "#563d7c",
    json: "#cbcb41",
    md: "#519aba",
    swift: "#ffac45",
    npm: "#cb3837",
    git: "#f54d27",
    img: "#26a69a",
    sh: "#89e051",
    file: "#d4d7d6",
  },
  nord: {
    folder: "#88c0d0",
    "folder-open": "#88c0d0",
    js: "#ebcb8b",
    jsx: "#8fbcbb",
    ts: "#81a1c1",
    tsx: "#88c0d0",
    html: "#bf616a",
    css: "#b48ead",
    json: "#ebcb8b",
    md: "#81a1c1",
    swift: "#d08770",
    npm: "#a3be8c",
    git: "#d08770",
    img: "#a3be8c",
    sh: "#a3be8c",
    file: "#d8dee9",
  },
};

const LETTER: Partial<Record<FileKind, string>> = {
  js: "JS",
  jsx: "JX",
  ts: "TS",
  tsx: "TX",
  html: "H",
  css: "C",
  json: "{}",
  md: "M",
  swift: "S",
  npm: "N",
  git: "G",
  sh: ">",
};

export function kindOf(path: string, folder?: boolean, open?: boolean): FileKind {
  if (folder) return open ? "folder-open" : "folder";
  const name = path.split("/").pop() ?? path;
  if (name === "package.json" || name === "package-lock.json") return "npm";
  if (name === ".gitignore" || name.startsWith(".git")) return "git";
  const ext = extOf(name);
  if (ext === "js") return "js";
  if (ext === "jsx") return "jsx";
  if (ext === "ts") return "ts";
  if (ext === "tsx") return "tsx";
  if (ext === "html") return "html";
  if (ext === "css") return "css";
  if (ext === "json" || ext === "webmanifest") return "json";
  if (ext === "md" || ext === "mdx") return "md";
  if (ext === "swift") return "swift";
  if (["png", "jpg", "jpeg", "gif", "svg", "webp"].includes(ext)) return "img";
  if (["sh", "bash", "zsh"].includes(ext)) return "sh";
  return "file";
}

export function iconColor(pack: IconPackId, kind: FileKind) {
  return COLORS[pack][kind];
}

export function iconLetter(kind: FileKind) {
  return LETTER[kind] ?? "";
}

export function packById(id: string) {
  return ICON_PACKS.find((p) => p.id === id) ?? ICON_PACKS[0]!;
}
