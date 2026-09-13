import { useEffect, useState } from "react";
import { Star } from "lucide-react";
import { PickList } from "@/components/ide/pick-list";
import { listProviderModels, type ModelInfo } from "@/lib/agent/models";
import { rememberEfforts } from "@/lib/agent/effort";
import { rememberCtx } from "@/lib/agent/chats";
import type { AgentId } from "@/lib/agent/providers";
import { authForTurn } from "@/lib/agent/session";
import { useChrome } from "@/lib/workspace/chrome";

function usable(m: ModelInfo) {
  const id = m.id.toLowerCase();
  if (id.includes("imagine") || id.includes("image") || id.includes("video") || id.includes("tts")) {
    return false;
  }
  return true;
}

export function ModelSelect({ provider, compact }: { provider: AgentId; compact?: boolean }) {
  const grokModel = useChrome((s) => s.grokModel);
  const claudeModel = useChrome((s) => s.claudeModel);
  const codexModel = useChrome((s) => s.codexModel);
  const fav = useChrome((s) => s.favModels?.[provider] ?? "");
  const setGrok = useChrome((s) => s.setGrokModel);
  const setClaude = useChrome((s) => s.setClaudeModel);
  const setCodex = useChrome((s) => s.setCodexModel);
  const setFav = useChrome((s) => s.setFavModel);
  const claudeAuth = useChrome((s) => s.claudeAuth);
  const openaiAuth = useChrome((s) => s.openaiAuth);
  const [models, setModels] = useState<ModelInfo[]>([]);
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  const [custom, setCustom] = useState("");

  const value =
    provider === "claude" ? claudeModel : provider === "codex" ? codexModel : grokModel;
  const setValue =
    provider === "claude" ? setClaude : provider === "codex" ? setCodex : setGrok;

  async function load() {
    setBusy(true);
    setErr("");
    try {
      const tokens = await authForTurn(provider);
      const r = await listProviderModels({
        data: { provider, access: tokens.access, accountId: tokens.accountId },
      });
      const list = (r.models ?? []).filter(usable);
      for (const m of list) {
        if (m.efforts?.length) rememberEfforts(provider, m.id, m.efforts);
        if (m.ctx) rememberCtx(provider, m.id, m.ctx);
      }
      setModels(list);
      if (!r.ok) setErr(r.error);
      const cur = useChrome.getState();
      const current =
        provider === "claude" ? cur.claudeModel : provider === "codex" ? cur.codexModel : cur.grokModel;
      const favorite = cur.favModels?.[provider] ?? "";
      if (!current) {
        const next = (favorite && list.some((m) => m.id === favorite) ? favorite : "") || list[0]?.id || favorite;
        if (next) setValue(next);
      }
    } catch (e) {
      setErr(e instanceof Error ? e.message : "falha ao listar modelos");
    } finally {
      setBusy(false);
    }
  }

  useEffect(() => {
    void load();
  }, [provider, claudeAuth?.access, openaiAuth?.access]);

  const options = (() => {
    const list = [...models];
    const extra = [value, fav].filter(Boolean);
    for (const id of extra) {
      if (id && !list.some((m) => m.id === id)) list.unshift({ id, label: id });
    }
    return list.map((m) => ({
      id: m.id,
      label: m.id === fav ? `★ ${m.label}` : m.label,
    }));
  })();

  function pick(id: string) {
    setValue(id);
    if (!fav) setFav(provider, id);
  }

  const star = (
    <button
      type="button"
      className={`fav-star${value && value === fav ? " is-on" : ""}`}
      disabled={!value}
      title={value === fav ? "modelo favorito" : "definir como favorito"}
      aria-label="favorito"
      onClick={() => {
        if (value) setFav(provider, value);
      }}
    >
      <Star size={16} strokeWidth={2} fill={value && value === fav ? "currentColor" : "none"} />
    </button>
  );

  if (compact) {
    return (
      <div className="fav-row">
        <PickList
          compact
          fill
          label="Modelo"
          ariaLabel="Modelo"
          value={value}
          options={options}
          onChange={pick}
          disabled={busy && !options.length}
        />
        {star}
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <div className="fav-row">
        <PickList
          ariaLabel="Modelo"
          fill
          label="Modelo"
          value={value}
          options={options}
          onChange={pick}
          disabled={busy && !options.length}
        />
        {star}
      </div>
      <p className="fav-hint">
        {fav ? `Favorito: ${fav}. Ao voltar pra este provider, usa esse modelo.` : "Estrela = favorito deste provider."}
      </p>
      <div className="flex gap-2">
        <input
          className="field"
          placeholder="id do modelo"
          value={custom}
          onChange={(e) => setCustom(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && custom.trim()) {
              pick(custom.trim());
              setCustom("");
            }
          }}
          autoCapitalize="off"
          autoCorrect="off"
          spellCheck={false}
        />
        <button
          type="button"
          className="chip shrink-0"
          onClick={() => {
            if (custom.trim()) {
              pick(custom.trim());
              setCustom("");
            } else void load();
          }}
        >
          {custom.trim() ? "usar" : busy ? "…" : "atualizar"}
        </button>
      </div>
      {err ? <p className="text-xs text-fg-subtle">{err}</p> : null}
    </div>
  );
}
