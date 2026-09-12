import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import { type AgentId, agentById } from "@/lib/agent/providers";
import type { EffortId } from "@/lib/agent/effort";
import type { TokenBundle } from "@/lib/agent/oauth";
import type { ThemeId } from "./themes";
import type { SynColors } from "./themes";
import type { IconPackId } from "./icons";

export type SideId = "files" | "search" | "git" | "settings" | "problems";
export type CenterId = "code" | "preview" | "split" | "diff" | "dual";
export type MobileTab = "files" | "edit" | "agent" | "term" | "preview" | "settings";
export type MinimapId = "off" | "s" | "m" | "l";

const ENTERED_KEY = "colo-entered";

export function hasEnteredWorkspace() {
  try {
    return localStorage.getItem(ENTERED_KEY) === "1";
  } catch {
    return false;
  }
}

export function enterWorkspace() {
  try {
    localStorage.setItem(ENTERED_KEY, "1");
  } catch {
    /* ignore quota / private mode */
  }
  useChrome.setState({ welcome: false });
}

const ACTIONS = [
  "dismissWelcome",
  "setSide",
  "setCenter",
  "toggleAgent",
  "toggleTerm",
  "setPalette",
  "setMobile",
  "setCreating",
  "setAgentId",
  "setGrokModel",
  "setClaudeModel",
  "setCodexModel",
  "setClaudeAuth",
  "setOpenaiAuth",
  "setTheme",
  "setIconPack",
  "setPluginLinter",
  "setPluginTodos",
  "setPluginWrap",
  "setPluginFormat",
  "setPluginCrumbs",
  "setPluginSpace",
  "setPluginIndent",
  "setPluginLineNo",
  "setPluginRuler",
  "setPluginFold",
  "setMinimap",
  "setPluginColorHint",
  "setPluginSelectMatch",
  "toggleSide",
  "resetLayout",
  "setSideW",
  "setAgentW",
  "setTermH",
  "setSynColor",
  "resetSyn",
  "setAltPath",
  "setEditFocus",
  "setCheatsheet",
  "setAgentMode",
  "setFindOpen",
  "setEffort",
  "setPluginEmmet",
  "setPluginSticky",
  "setPluginComment",
  "setPluginUrls",
] as const;
export type PaletteKind = "all" | "files" | "cmds";

type ChromeState = {
  welcome: boolean;
  side: SideId;
  center: CenterId;
  agent: boolean;
  term: boolean;
  palette: boolean;
  paletteKind: PaletteKind;
  findOpen: boolean;
  agentMode: AgentMode;
  effortByKey: Record<string, EffortId>;
  mobile: MobileTab;
  creating: boolean;
  agentId: AgentId;
  grokModel: string;
  claudeModel: string;
  codexModel: string;
  claudeAuth: TokenBundle | null;
  openaiAuth: TokenBundle | null;
  theme: ThemeId;
  synCustom: SynColors;
  iconPack: IconPackId;
  pluginLinter: boolean;
  pluginTodos: boolean;
  pluginWrap: boolean;
  pluginFormat: boolean;
  pluginCrumbs: boolean;
  pluginSpace: boolean;
  pluginIndent: boolean;
  pluginLineNo: boolean;
  pluginRuler: boolean;
  pluginFold: boolean;
  minimap: MinimapId;
  pluginColorHint: boolean;
  pluginSelectMatch: boolean;
  pluginGitGutter: boolean;
  pluginTodoMark: boolean;
  pluginRainbow: boolean;
  pluginEmmet: boolean;
  pluginSticky: boolean;
  pluginComment: boolean;
  pluginUrls: boolean;
  skillsOff: string[];
  sideOpen: boolean;
  sideW: number;
  agentW: number;
  termH: number;
  altPath: string;
  editFocus: "a" | "b";
  cheatsheet: boolean;
  dismissWelcome: () => void;
  setSide: (s: SideId) => void;
  setCenter: (c: CenterId) => void;
  toggleAgent: () => void;
  toggleTerm: () => void;
  setPalette: (v: boolean, kind?: PaletteKind) => void;
  setFindOpen: (v: boolean) => void;
  setAgentMode: (m: AgentMode) => void;
  setEffort: (key: string, effort: EffortId) => void;
  setMobile: (t: MobileTab) => void;
  setCreating: (v: boolean) => void;
  setAgentId: (id: AgentId) => void;
  setGrokModel: (m: string) => void;
  setClaudeModel: (m: string) => void;
  setCodexModel: (m: string) => void;
  setClaudeAuth: (t: TokenBundle | null) => void;
  setOpenaiAuth: (t: TokenBundle | null) => void;
  setTheme: (t: ThemeId) => void;
  setSynColor: (key: keyof SynColors, color: string) => void;
  resetSyn: () => void;
  setIconPack: (p: IconPackId) => void;
  setPluginLinter: (v: boolean) => void;
  setPluginTodos: (v: boolean) => void;
  setPluginWrap: (v: boolean) => void;
  setPluginFormat: (v: boolean) => void;
  setPluginCrumbs: (v: boolean) => void;
  setPluginSpace: (v: boolean) => void;
  setPluginIndent: (v: boolean) => void;
  setPluginLineNo: (v: boolean) => void;
  setPluginRuler: (v: boolean) => void;
  setPluginFold: (v: boolean) => void;
  setMinimap: (v: MinimapId) => void;
  setPluginColorHint: (v: boolean) => void;
  setPluginSelectMatch: (v: boolean) => void;
  setPluginGitGutter: (v: boolean) => void;
  setPluginTodoMark: (v: boolean) => void;
  setPluginRainbow: (v: boolean) => void;
  setPluginEmmet: (v: boolean) => void;
  setPluginSticky: (v: boolean) => void;
  setPluginComment: (v: boolean) => void;
  setPluginUrls: (v: boolean) => void;
  toggleSkill: (id: string, on: boolean) => void;
  toggleSide: () => void;
  resetLayout: () => void;
  setSideW: (n: number) => void;
  setAgentW: (n: number) => void;
  setTermH: (n: number) => void;
  setAltPath: (p: string) => void;
  setEditFocus: (f: "a" | "b") => void;
  setCheatsheet: (v: boolean) => void;
};

function safeStorage() {
  return {
    getItem: (name: string) => {
      try {
        return localStorage.getItem(name);
      } catch {
        return null;
      }
    },
    setItem: (name: string, value: string) => {
      try {
        localStorage.setItem(name, value);
      } catch {
        /* quota / private mode */
      }
    },
    removeItem: (name: string) => {
      try {
        localStorage.removeItem(name);
      } catch {
        /* ignore */
      }
    },
  };
}

export const useChrome = create<ChromeState>()(
  persist(
    (set) => ({
      welcome: false,
      side: "files",
      center: "code",
      agent: true,
      term: true,
      palette: false,
      paletteKind: "all" as PaletteKind,
      findOpen: false,
      agentMode: "build" as AgentMode,
      effortByKey: {} as Record<string, EffortId>,
      mobile: "edit",
      creating: false,
      agentId: "grok",
      grokModel: "grok-4-1-fast-reasoning",
      claudeModel: "",
      codexModel: "",
      claudeAuth: null,
      openaiAuth: null,
      theme: "colo",
      synCustom: {},
      iconPack: "catppuccin",
      pluginLinter: true,
      pluginTodos: true,
      pluginWrap: false,
      pluginFormat: false,
      pluginCrumbs: true,
      pluginSpace: false,
      pluginIndent: false,
      pluginLineNo: true,
      pluginRuler: false,
      pluginFold: true,
      minimap: "m",
      pluginColorHint: true,
      pluginSelectMatch: true,
      pluginGitGutter: true,
      pluginTodoMark: true,
      pluginRainbow: true,
      pluginEmmet: true,
      pluginSticky: true,
      pluginComment: true,
      pluginUrls: true,
      skillsOff: [],
      sideOpen: true,
      sideW: 248,
      agentW: 320,
      termH: 200,
      altPath: "index.html",
      editFocus: "a" as const,
      cheatsheet: false,
      dismissWelcome: () => enterWorkspace(),
      setSide: (side) => set({ side, sideOpen: true }),
      setCenter: (center) => set({ center }),
      toggleAgent: () => set((s) => ({ agent: !s.agent })),
      toggleTerm: () => set((s) => ({ term: !s.term })),
      toggleSide: () => set((s) => ({ sideOpen: !s.sideOpen })),
      resetLayout: () =>
        set({ sideOpen: true, agent: true, term: true, sideW: 248, agentW: 320, termH: 200 }),
      setSideW: (sideW) => set({ sideW }),
      setAgentW: (agentW) => set({ agentW }),
      setTermH: (termH) => set({ termH }),
      setPalette: (palette, kind) =>
        set((s) => ({ palette, paletteKind: kind ?? (palette ? s.paletteKind : "all") })),
      setFindOpen: (findOpen) => set({ findOpen }),
      setAgentMode: (agentMode) => set({ agentMode }),
      setEffort: (key, effort) =>
        set((s) => ({ effortByKey: { ...s.effortByKey, [key]: effort } })),
      setMobile: (mobile) => set({ mobile }),
      setCreating: (creating) => set({ creating }),
      setAgentId: (agentId) => set({ agentId }),
      setGrokModel: (grokModel) => set({ grokModel }),
      setClaudeModel: (claudeModel) => set({ claudeModel }),
      setCodexModel: (codexModel) => set({ codexModel }),
      setClaudeAuth: (claudeAuth) => set({ claudeAuth }),
      setOpenaiAuth: (openaiAuth) => set({ openaiAuth }),
      setTheme: (theme) => set({ theme }),
      setSynColor: (key, color) =>
        set((s) => ({ synCustom: { ...s.synCustom, [key]: color } })),
      resetSyn: () => set({ synCustom: {} }),
      setIconPack: (iconPack) => set({ iconPack }),
      setPluginLinter: (pluginLinter) => set({ pluginLinter }),
      setPluginTodos: (pluginTodos) => set({ pluginTodos }),
      setPluginWrap: (pluginWrap) => set({ pluginWrap }),
      setPluginFormat: (pluginFormat) => set({ pluginFormat }),
      setPluginCrumbs: (pluginCrumbs) => set({ pluginCrumbs }),
      setPluginSpace: (pluginSpace) => set({ pluginSpace }),
      setPluginIndent: (pluginIndent) => set({ pluginIndent }),
      setPluginLineNo: (pluginLineNo) => set({ pluginLineNo }),
      setPluginRuler: (pluginRuler) => set({ pluginRuler }),
      setPluginFold: (pluginFold) => set({ pluginFold }),
      setMinimap: (minimap) => set({ minimap }),
      setPluginColorHint: (pluginColorHint) => set({ pluginColorHint }),
      setPluginSelectMatch: (pluginSelectMatch) => set({ pluginSelectMatch }),
      setPluginGitGutter: (pluginGitGutter) => set({ pluginGitGutter }),
      setPluginTodoMark: (pluginTodoMark) => set({ pluginTodoMark }),
      setPluginRainbow: (pluginRainbow) => set({ pluginRainbow }),
      setPluginEmmet: (pluginEmmet) => set({ pluginEmmet }),
      setPluginSticky: (pluginSticky) => set({ pluginSticky }),
      setPluginComment: (pluginComment) => set({ pluginComment }),
      setPluginUrls: (pluginUrls) => set({ pluginUrls }),
      toggleSkill: (id, on) =>
        set((s) => ({
          skillsOff: on ? s.skillsOff.filter((x) => x !== id) : [...new Set([...s.skillsOff, id])],
        })),
      setAltPath: (altPath) => set({ altPath }),
      setEditFocus: (editFocus) => set({ editFocus }),
      setCheatsheet: (cheatsheet) => set({ cheatsheet }),
    }),
    {
      name: "colo-chrome-v3",
      storage: createJSONStorage(safeStorage),
      partialize: (s) => ({
        side: s.side,
        center: s.center,
        agent: s.agent,
        term: s.term,
        agentId: s.agentId,
        grokModel: s.grokModel,
        claudeModel: s.claudeModel,
        codexModel: s.codexModel,
        claudeAuth: s.claudeAuth,
        openaiAuth: s.openaiAuth,
        theme: s.theme,
        synCustom: s.synCustom,
        iconPack: s.iconPack,
        pluginLinter: s.pluginLinter,
        pluginTodos: s.pluginTodos,
        pluginWrap: s.pluginWrap,
        pluginFormat: s.pluginFormat,
        pluginCrumbs: s.pluginCrumbs,
        pluginSpace: s.pluginSpace,
        pluginIndent: s.pluginIndent,
        pluginLineNo: s.pluginLineNo,
        pluginRuler: s.pluginRuler,
        pluginFold: s.pluginFold,
        minimap: s.minimap,
        pluginColorHint: s.pluginColorHint,
        pluginSelectMatch: s.pluginSelectMatch,
        pluginGitGutter: s.pluginGitGutter,
        pluginTodoMark: s.pluginTodoMark,
        pluginRainbow: s.pluginRainbow,
        pluginEmmet: s.pluginEmmet,
        pluginSticky: s.pluginSticky,
        pluginComment: s.pluginComment,
        pluginUrls: s.pluginUrls,
        skillsOff: s.skillsOff,
        sideW: s.sideW,
        agentW: s.agentW,
        termH: s.termH,
        agentMode: s.agentMode,
        effortByKey: s.effortByKey,
      }),
      merge: (persisted, current) => {
        const p = { ...((persisted ?? {}) as Record<string, unknown>) };
        p.welcome = false;
        if (p.theme === "verdent") p.theme = "volt";
        if (p.pluginMinimap === true && !p.minimap) p.minimap = "m";
        if (p.pluginMinimap === false && !p.minimap) p.minimap = "off";
        delete p.pluginMinimap;
        delete p.sideOpen;
        if (typeof p.sideW !== "number" || p.sideW < 160) delete p.sideW;
        if (typeof p.agentW !== "number" || p.agentW < 200) delete p.agentW;
        if (typeof p.termH !== "number" || p.termH < 120) delete p.termH;
        for (const key of ACTIONS) delete p[key];
        return { ...current, ...p } as ChromeState;
      },
    },
  ),
);

export function currentAgentModel(s: {
  agentId: AgentId;
  grokModel: string;
  claudeModel: string;
  codexModel: string;
}) {
  if (s.agentId === "claude") return s.claudeModel;
  if (s.agentId === "codex") return s.codexModel;
  return s.grokModel || agentById("grok").defaultModel;
}

export function currentEffort(s: {
  agentId: AgentId;
  grokModel: string;
  claudeModel: string;
  codexModel: string;
  effortByKey: Record<string, EffortId>;
}): EffortId | "" {
  const model = currentAgentModel(s);
  return s.effortByKey[`${s.agentId}:${model}`] ?? "";
}

export function agentConnected(s: {
  agentId: AgentId;
  claudeAuth: TokenBundle | null;
  openaiAuth: TokenBundle | null;
}) {
  if (s.agentId === "grok") return true;
  if (s.agentId === "claude") return Boolean(s.claudeAuth?.access);
  return Boolean(s.openaiAuth?.access);
}
