import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import { idbKv } from "./idb";
import { persistAuth } from "./secrets";
import { type AgentId, agentById } from "@/lib/agent/providers";
import type { EffortId } from "@/lib/agent/effort";
import type { TokenBundle } from "@/lib/agent/oauth";
import type { ThemeId } from "./themes";
import type { SynColors } from "./themes";
import type { IconPackId } from "./icons";
import type { PermitMode } from "@/lib/agent/permit";
import type { AgentMode } from "@/lib/agent/tools";

export type SideId = "files" | "search" | "git" | "settings" | "problems";
export type CenterId = "code" | "preview" | "split" | "diff" | "dual";
export type MobileTab = "files" | "edit" | "agent" | "term" | "preview" | "settings";
export type MinimapId = "off" | "s" | "m" | "l";

const ENTERED_KEY = "odete-entered";

export function hasEnteredWorkspace() {
  try {
    if (localStorage.getItem(ENTERED_KEY) === "1") return true;
  } catch {
    /* */
  }
  return false;
}

function markEntered() {
  try {
    localStorage.setItem(ENTERED_KEY, "1");
  } catch {
    /* ignore quota / private mode */
  }
}

export function enterWorkspace() {
  markEntered();
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
  "setPermitMode",
  "setFindOpen",
  "setEffort",
  "setPluginEmmet",
  "setPluginSticky",
  "setPluginComment",
  "setPluginUrls",
  "setSlotAgent",
  "setSlotMode",
  "setSlotPermit",
  "setSlotModel",
] as const;
export type PaletteKind = "all" | "files" | "cmds";

export type SlotId = "a" | "b";

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
  permitMode: PermitMode;
  effortByKey: Record<string, EffortId>;
  mobile: MobileTab;
  creating: boolean;
  agentId: AgentId;
  slotAgent: Record<SlotId, AgentId>;
  slotMode: Record<SlotId, AgentMode>;
  slotPermit: Record<SlotId, PermitMode>;
  slotModel: Record<SlotId, string>;
  grokModel: string;
  claudeModel: string;
  codexModel: string;
  favModels: Record<AgentId, string>;
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
  splitPct: number;
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
  setPermitMode: (m: PermitMode) => void;
  setEffort: (key: string, effort: EffortId) => void;
  setMobile: (t: MobileTab) => void;
  setCreating: (v: boolean) => void;
  setAgentId: (id: AgentId) => void;
  setSlotAgent: (slot: SlotId, id: AgentId) => void;
  setSlotMode: (slot: SlotId, m: AgentMode) => void;
  setSlotPermit: (slot: SlotId, m: PermitMode) => void;
  setSlotModel: (slot: SlotId, m: string) => void;
  setGrokModel: (m: string) => void;
  setClaudeModel: (m: string) => void;
  setCodexModel: (m: string) => void;
  setFavModel: (id: AgentId, m: string) => void;
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
  setSplitPct: (n: number) => void;
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
      welcome: !hasEnteredWorkspace(),
      side: "files",
      center: "code",
      agent: true,
      term: true,
      palette: false,
      paletteKind: "all" as PaletteKind,
      findOpen: false,
      agentMode: "build" as AgentMode,
      permitMode: "auto" as PermitMode,
      effortByKey: {} as Record<string, EffortId>,
      mobile: "edit",
      creating: false,
      agentId: "grok",
      slotAgent: { a: "grok", b: "grok" },
      slotMode: { a: "build", b: "build" },
      slotPermit: { a: "auto", b: "auto" },
      slotModel: { a: "", b: "" },
      grokModel: "grok-4-1-fast-reasoning",
      claudeModel: "",
      codexModel: "",
      favModels: { grok: "grok-4-1-fast-reasoning", claude: "", codex: "" },
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
      splitPct: 50,
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
        set({ sideOpen: true, agent: true, term: true, sideW: 248, agentW: 320, termH: 200, splitPct: 50 }),
      setSideW: (sideW) => set({ sideW }),
      setAgentW: (agentW) => set({ agentW }),
      setTermH: (termH) => set({ termH }),
      setSplitPct: (splitPct) => set({ splitPct }),
      setPalette: (palette, kind) =>
        set((s) => ({ palette, paletteKind: kind ?? (palette ? s.paletteKind : "all") })),
      setFindOpen: (findOpen) => set({ findOpen }),
      setAgentMode: (agentMode) => set((s) => ({ agentMode, slotMode: { ...s.slotMode, a: agentMode } })),
      setPermitMode: (permitMode) => set((s) => ({ permitMode, slotPermit: { ...s.slotPermit, a: permitMode } })),
      setEffort: (key, effort) =>
        set((s) => ({ effortByKey: { ...s.effortByKey, [key]: effort } })),
      setMobile: (mobile) => set({ mobile }),
      setCreating: (creating) => set({ creating }),
      setAgentId: (agentId) =>
        set((s) => {
          const fav = s.favModels?.[agentId];
          const slotAgent = { ...s.slotAgent, a: agentId };
          if (!fav) return { agentId, slotAgent };
          if (agentId === "claude") return { agentId, slotAgent, claudeModel: fav };
          if (agentId === "codex") return { agentId, slotAgent, codexModel: fav };
          return { agentId, slotAgent, grokModel: fav };
        }),
      setSlotAgent: (slot, id) =>
        set((s) => {
          const slotAgent = { a: s.slotAgent?.a ?? s.agentId, b: s.slotAgent?.b ?? "grok", [slot]: id };
          const fav = s.favModels?.[id] || "";
          const slotModel = { a: s.slotModel?.a ?? "", b: s.slotModel?.b ?? "", [slot]: fav };
          if (slot === "a") {
            const extra = !fav
              ? {}
              : id === "claude"
                ? { claudeModel: fav }
                : id === "codex"
                  ? { codexModel: fav }
                  : { grokModel: fav };
            return { agentId: id, slotAgent, slotModel, ...extra };
          }
          return { slotAgent, slotModel };
        }),
      setSlotMode: (slot, m) =>
        set((s) => ({
          slotMode: { a: s.slotMode?.a ?? s.agentMode, b: s.slotMode?.b ?? "build", [slot]: m },
          ...(slot === "a" ? { agentMode: m } : {}),
        })),
      setSlotPermit: (slot, m) =>
        set((s) => ({
          slotPermit: { a: s.slotPermit?.a ?? s.permitMode, b: s.slotPermit?.b ?? "auto", [slot]: m },
          ...(slot === "a" ? { permitMode: m } : {}),
        })),
      setSlotModel: (slot, m) =>
        set((s) => {
          const slotModel = { a: s.slotModel?.a ?? "", b: s.slotModel?.b ?? "", [slot]: m };
          if (slot !== "a") return { slotModel };
          const id = s.slotAgent?.[slot] ?? s.agentId;
          if (id === "claude") return { slotModel, claudeModel: m };
          if (id === "codex") return { slotModel, codexModel: m };
          return { slotModel, grokModel: m };
        }),
      setGrokModel: (grokModel) => set({ grokModel }),
      setClaudeModel: (claudeModel) => set({ claudeModel }),
      setCodexModel: (codexModel) => set({ codexModel }),
      setFavModel: (id, m) =>
        set((s) => ({
          favModels: { ...s.favModels, [id]: m },
          ...(id === "claude" ? { claudeModel: m } : id === "codex" ? { codexModel: m } : { grokModel: m }),
        })),
      setClaudeAuth: (claudeAuth) => {
        set({ claudeAuth });
        void persistAuth();
      },
      setOpenaiAuth: (openaiAuth) => {
        set({ openaiAuth });
        void persistAuth();
      },
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
      storage: createJSONStorage(() => idbKv),
      partialize: (s) => ({
        side: s.side,
        center: s.center,
        agent: s.agent,
        term: s.term,
        agentId: s.agentId,
        slotAgent: s.slotAgent,
        slotMode: s.slotMode,
        slotPermit: s.slotPermit,
        slotModel: s.slotModel,
        grokModel: s.grokModel,
        claudeModel: s.claudeModel,
        codexModel: s.codexModel,
        favModels: s.favModels,
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
        sideOpen: s.sideOpen,
        sideW: s.sideW,
        agentW: s.agentW,
        termH: s.termH,
        splitPct: s.splitPct,
        altPath: s.altPath,
        editFocus: s.editFocus,
        mobile: s.mobile,
        agentMode: s.agentMode,
        permitMode: s.permitMode,
        effortByKey: s.effortByKey,
      }),
      merge: (persisted, current) => {
        const p = { ...((persisted ?? {}) as Record<string, unknown>) };
        if (persisted && Object.keys(p).length) markEntered();
        p.welcome = !hasEnteredWorkspace();
        if (p.theme === "verdent") p.theme = "volt";
        if (p.pluginMinimap === true && !p.minimap) p.minimap = "m";
        if (p.pluginMinimap === false && !p.minimap) p.minimap = "off";
        delete p.pluginMinimap;
        if (typeof p.sideW !== "number" || p.sideW < 160) delete p.sideW;
        if (typeof p.agentW !== "number" || p.agentW < 200) delete p.agentW;
        if (typeof p.termH !== "number" || p.termH < 120) delete p.termH;
        if (typeof p.splitPct !== "number" || p.splitPct < 22 || p.splitPct > 78) delete p.splitPct;
        for (const key of ACTIONS) delete p[key];
        const prev = (p.favModels ?? {}) as Record<string, string>;
        p.favModels = {
          grok: prev.grok || (p.grokModel as string) || "grok-4-1-fast-reasoning",
          claude: prev.claude || (p.claudeModel as string) || "",
          codex: prev.codex || (p.codexModel as string) || "",
        };
        const sa = (p.slotAgent ?? {}) as Record<string, string>;
        p.slotAgent = {
          a: sa.a || (p.agentId as string) || "grok",
          b: sa.b || "grok",
        };
        const sm = (p.slotMode ?? {}) as Record<string, string>;
        p.slotMode = { a: sm.a || p.agentMode || "build", b: sm.b || "build" };
        const sp = (p.slotPermit ?? {}) as Record<string, string>;
        p.slotPermit = { a: sp.a || p.permitMode || "auto", b: sp.b || "auto" };
        const sml = (p.slotModel ?? {}) as Record<string, string>;
        p.slotModel = { a: sml.a || (p.grokModel as string) || "", b: sml.b || "" };
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
  slotAgent?: Record<SlotId, AgentId>;
  slotModel?: Record<SlotId, string>;
}, slot?: SlotId) {
  const id = slot ? (s.slotAgent?.[slot] ?? s.agentId) : s.agentId;
  const slotM = slot ? s.slotModel?.[slot] : "";
  if (slotM) return slotM;
  if (id === "claude") return s.claudeModel;
  if (id === "codex") return s.codexModel;
  return s.grokModel || agentById("grok").defaultModel;
}

export function currentEffort(s: {
  agentId: AgentId;
  grokModel: string;
  claudeModel: string;
  codexModel: string;
  effortByKey: Record<string, EffortId>;
  slotAgent?: Record<SlotId, AgentId>;
  slotModel?: Record<SlotId, string>;
}, slot?: SlotId): EffortId | "" {
  const id = slot ? (s.slotAgent?.[slot] ?? s.agentId) : s.agentId;
  const model = currentAgentModel(s, slot);
  return s.effortByKey[`${id}:${model}`] ?? "";
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
