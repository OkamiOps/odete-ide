import { useEffect, useState } from "react";
import { PickList } from "@/components/ide/pick-list";
import { listProviderModels, type ModelInfo } from "@/lib/agent/models";
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
  const setGrok = useChrome((s) => s.setGrokModel);
  const setClaude = useChrome((s) => s.setClaudeModel);
  const setCodex = useChrome((s) => s.setCodexModel);
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
      if (!r.ok) {
        setErr(r.error);
        setModels(list);
      } else {
        setModels(list);
        if (list.length && !list.some((m) => m.id === value)) {
          setValue(list[0]!.id);
        }
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

  const options = models.some((m) => m.id === value)
    ? models
    : value
      ? [{ id: value, label: value }, ...models]
      : models;

  if (compact) {
    return (
      <PickList
        compact
        fill
        ariaLabel="Modelo"
        value={value}
        options={options}
        onChange={setValue}
        disabled={busy && !options.length}
      />
    );
  }

  return (
    <div className="space-y-2">
      <p className="text-xs text-fg-subtle">Modelo</p>
      <PickList
        ariaLabel="Modelo"
        value={value}
        options={options}
        onChange={setValue}
        disabled={busy && !options.length}
      />
      <div className="flex gap-2">
        <input
          className="field"
          placeholder="id do modelo"
          value={custom}
          onChange={(e) => setCustom(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && custom.trim()) {
              setValue(custom.trim());
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
              setValue(custom.trim());
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
