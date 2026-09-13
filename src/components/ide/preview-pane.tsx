import { useEffect, useMemo, useState } from "react";
import { Monitor, RotateCw, Smartphone, Tablet } from "lucide-react";
import { markdownPage, isMdPath } from "@/lib/workspace/markdown";
import { buildPreviewHtml } from "@/lib/workspace/preview";
import { buildSwiftPlayground, isSwiftPath } from "@/lib/workspace/swift-play";
import { useWorkspace } from "@/lib/workspace/store";
import { isNoisePath } from "@/lib/workspace/ignore";

type Frame = "full" | "ipad" | "phone";

type Log = { id: number; level: string; text: string };

function sourceKey(files: Record<string, string>) {
  const parts: string[] = [];
  for (const k of Object.keys(files).sort()) {
    if (isNoisePath(k)) continue;
    parts.push(`${k}:${files[k]!.length}`);
  }
  return parts.join("|");
}

export function PreviewPane() {
  const files = useWorkspace((s) => s.files);
  const openPath = useWorkspace((s) => s.openPath);
  const swift = isSwiftPath(openPath);
  const md = isMdPath(openPath);
  const [frame, setFrame] = useState<Frame>("full");
  const [tick, setTick] = useState(0);
  const [logs, setLogs] = useState<Log[]>([]);
  const key = useMemo(() => sourceKey(files), [files]);
  const [readyKey, setReadyKey] = useState(key);
  useEffect(() => {
    const t = window.setTimeout(() => setReadyKey(key), 280);
    return () => window.clearTimeout(t);
  }, [key]);
  const srcDoc = useMemo(
    () =>
      md
        ? markdownPage(files[openPath] ?? "")
        : swift
          ? buildSwiftPlayground(files[openPath] ?? "")
          : buildPreviewHtml(files),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [readyKey, openPath, swift, md, tick],
  );

  useEffect(() => {
    function onMsg(e: MessageEvent) {
      const d = e.data;
      if (!d || d.source !== "colo-preview") return;
      const text = Array.isArray(d.args) ? d.args.join(" ") : String(d.args ?? "");
      setLogs((xs) => [...xs.slice(-80), { id: Date.now() + Math.random(), level: d.level || "log", text }]);
    }
    window.addEventListener("message", onMsg);
    return () => window.removeEventListener("message", onMsg);
  }, []);

  return (
    <div className={`preview-frame is-${frame}`}>
      <div className="pane-hd">
        <span className="label">Preview</span>
        <em>{md ? openPath : swift ? openPath : "index.html"}</em>
        <div className="preview-ops">
          <button type="button" className={frame === "full" ? "is-on" : undefined} title="tela cheia" onClick={() => setFrame("full")}>
            <Monitor size={14} />
          </button>
          <button type="button" className={frame === "ipad" ? "is-on" : undefined} title="iPad" onClick={() => setFrame("ipad")}>
            <Tablet size={14} />
          </button>
          <button type="button" className={frame === "phone" ? "is-on" : undefined} title="iPhone" onClick={() => setFrame("phone")}>
            <Smartphone size={14} />
          </button>
          <button
            type="button"
            title="recarregar"
            onClick={() => {
              setLogs([]);
              setTick((n) => n + 1);
            }}
          >
            <RotateCw size={14} />
          </button>
        </div>
      </div>
      <div className="preview-stage">
        <iframe key={tick} title="Preview do workspace" sandbox="allow-scripts allow-forms allow-modals allow-popups allow-downloads" srcDoc={srcDoc} />
      </div>
      <div className="preview-console">
        <header>
          <span>Console</span>
          <button type="button" onClick={() => setLogs([])}>
            limpar
          </button>
        </header>
        <div className="preview-console-body">
          {logs.length === 0 ? <p className="preview-console-empty">sem logs</p> : null}
          {logs.map((l) => (
            <p key={l.id} className={`is-${l.level}`}>
              {l.text}
            </p>
          ))}
        </div>
      </div>
    </div>
  );
}
