export type ThemeId =
  | "odete"
  | "colo"
  | "catppuccin"
  | "latte"
  | "darcula"
  | "cursor"
  | "claude"
  | "linear"
  | "github"
  | "okami"
  | "volt";

export type ThemeDef = {
  id: ThemeId;
  label: string;
  blurb: string;
  dark: boolean;
  swatch: [string, string, string];
};

export const THEMES: ThemeDef[] = [
  {
    id: "odete",
    label: "Odete",
    blurb: "Noite da marca.",
    dark: true,
    swatch: ["#08080a", "#4fd4ea", "#121216"],
  },
  {
    id: "catppuccin",
    label: "Catppuccin",
    blurb: "Mocha.",
    dark: true,
    swatch: ["#1e1e2e", "#cba6f7", "#313244"],
  },
  {
    id: "latte",
    label: "Latte",
    blurb: "Catppuccin claro.",
    dark: false,
    swatch: ["#eff1f5", "#8839ef", "#e6e9ef"],
  },
  {
    id: "darcula",
    label: "Darcula",
    blurb: "JetBrains.",
    dark: true,
    swatch: ["#2b2b2b", "#cc7832", "#3c3f41"],
  },
  {
    id: "cursor",
    label: "Cursor",
    blurb: "Laranja.",
    dark: true,
    swatch: ["#181818", "#f54e00", "#1f1f1f"],
  },
  {
    id: "claude",
    label: "Claude",
    blurb: "Terracota.",
    dark: false,
    swatch: ["#faf9f5", "#cc785c", "#f5f0e8"],
  },
  {
    id: "linear",
    label: "Linear",
    blurb: "Índigo.",
    dark: true,
    swatch: ["#010102", "#5e6ad2", "#141516"],
  },
  {
    id: "github",
    label: "GitHub",
    blurb: "Dark dimmed.",
    dark: true,
    swatch: ["#0d1117", "#2f81f7", "#161b22"],
  },
  {
    id: "okami",
    label: "OkamiOps",
    blurb: "Laranja, magenta, ciano.",
    dark: true,
    swatch: ["#060609", "#ff7a3d", "#0b0b12"],
  },
  {
    id: "volt",
    label: "Volt",
    blurb: "Emerald.",
    dark: true,
    swatch: ["#101010", "#00d992", "#1a1a1a"],
  },
];

export function themeById(id: string) {
  const key = id === "colo" ? "odete" : id;
  return THEMES.find((t) => t.id === key) ?? THEMES[0]!;
}

export const SYN_FIELDS = [
  { id: "keyword", label: "Keyword" },
  { id: "string", label: "String" },
  { id: "comment", label: "Comentário" },
  { id: "number", label: "Número" },
  { id: "func", label: "Função" },
  { id: "type", label: "Tipo" },
] as const;

export type SynKey = (typeof SYN_FIELDS)[number]["id"];
export type SynColors = Partial<Record<SynKey, string>>;
