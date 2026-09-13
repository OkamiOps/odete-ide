import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { Monitor, RotateCw, Smartphone, Tablet } from "lucide-react";
import { markdownPage, isMdPath } from "@/lib/workspace/markdown";
import {
  buildPreviewHtml,
  classifyPreviewChange,
  lookupPreviewAsset,
  previewCss,
  previewHmrJs,
} from "@/lib/workspace/preview";
import { dispatchRuntime } from "@/lib/workspace/runtime";
import { useNodeRuntime } from "@/lib/workspace/node-runtime";
import { buildSwiftPlayground, isSwiftPath } from "@/lib/workspace/swift-play";
import { useWorkspace } from "@/lib/workspace/store";
import { isNoisePath } from "@/lib/workspace/ignore";
import type { FileMap } from "@/lib/workspace/types";

type Frame = "full" | "ipad" | "phone";

type Log = { id: number; level: string; text: string };

function sourceKey(files: Record<string, string>) {
  let h = 2166136261;
  const keys = Object.keys(files).sort();
  for (const k of keys) {
    if (isNoisePath(k)) continue;
    const v = files[k]!;
    for (let i = 0; i < k.length; i++) {
      h ^= k.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    h ^= v.length;
    h = Math.imul(h, 16777619);
    const n = Math.min(v.length, 250_000);
    for (let i = 0; i < n; i++) {
      h ^= v.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
  }
  return (h >>> 0).toString(36);
}

export function PreviewPane() {
  const files = useWorkspace((s) => s.files);
  const openPath = useWorkspace((s) => s.openPath);
  const wcUrl = useNodeRuntime((s) => s.previewUrl);
  const wcStatus = useNodeRuntime((s) => s.status);
  const swift = isSwiftPath(openPath);
  const md = isMdPath(openPath);
  const [frame, setFrame] = useState<Frame>("full");
  const [tick, setTick] = useState(0);
  const [wcGen, setWcGen] = useState(0);
  const [logs, setLogs] = useState<Log[]>([]);
  const [hmrKind, setHmrKind] = useState<"hmr" | "reload" | "">("");
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const filesRef = useRef(files);
  filesRef.current = files;
  const appliedRef = useRef<FileMap>({});
  const forceReload = useRef(false);
  const bootedRef = useRef(false);
  const key = useMemo(() => sourceKey(files), [files]);
  const [readyKey, setReadyKey] = useState(key);
  const [doc, setDoc] = useState("");
  const [frameId, setFrameId] = useState(0);

  useEffect(() => {
    const t = window.setTimeout(() => setReadyKey(key), 280);
    return () => window.clearTimeout(t);
  }, [key]);

  useEffect(() => {
    try {
      if (wcUrl) {
        appliedRef.current = filesRef.current;
        setHmrKind("hmr");
        forceReload.current = false;
        return;
      }
      const filesNow = filesRef.current;
      if (md) {
        setDoc(markdownPage(filesNow[openPath] ?? ""));
        setFrameId((n) => n + 1);
        appliedRef.current = filesNow;
        setHmrKind("");
        forceReload.current = false;
        return;
      }
      if (swift) {
        setDoc(buildSwiftPlayground(filesNow[openPath] ?? ""));
        setFrameId((n) => n + 1);
        appliedRef.current = filesNow;
        setHmrKind("");
        forceReload.current = false;
        return;
      }
      const html = buildPreviewHtml(filesNow);
      const win = iframeRef.current?.contentWindow;
      const first = !Object.keys(appliedRef.current).length;
      const ready = bootedRef.current && !!win;
      const cls = classifyPreviewChange(appliedRef.current, filesNow);
      if (!forceReload.current && !first && ready && cls.kind === "css" && cls.paths.length) {
        for (const p of cls.paths) {
          win!.postMessage({ source: "colo-hmr", kind: "css", path: p, content: previewCss(filesNow, p) }, "*");
        }
        appliedRef.current = filesNow;
        setHmrKind("hmr");
        return;
      }
      if (!forceReload.current && !first && ready && cls.kind === "js") {
        const payload = previewHmrJs(filesNow);
        if (payload) {
          win!.postMessage({ source: "colo-hmr", kind: "js", ...payload }, "*");
          appliedRef.current = filesNow;
          setHmrKind("hmr");
          return;
        }
      }
      setDoc(html);
      setFrameId((n) => n + 1);
      bootedRef.current = false;
      appliedRef.current = filesNow;
      setHmrKind(first || forceReload.current ? "" : "reload");
      forceReload.current = false;
    } catch (e) {
      const msg = e instanceof Error ? e.message : "preview falhou";
      setDoc(`<!doctype html><pre style="padding:16px;font:14px ui-monospace">${msg}</pre>`);
      setFrameId((n) => n + 1);
      setHmrKind("reload");
      forceReload.current = false;
    }
  }, [readyKey, openPath, swift, md, tick, wcUrl]);

  useLayoutEffect(() => {
    if (wcUrl || !doc) return;
    const el = iframeRef.current;
    if (!el) return;
    if (el.srcdoc !== doc) el.srcdoc = doc;
  }, [doc, frameId, wcUrl]);

  useEffect(() => {
    function onMsg(e: MessageEvent) {
      const d = e.data;
      if (!d || d.source !== "colo-preview") return;
      if (d.type === "fetch") {
        void (async () => {
          const url = String(d.url || "");
          const method = String(d.method || "GET");
          const body = typeof d.body === "string" ? d.body : d.body == null ? null : String(d.body);
          let res = lookupPreviewAsset(filesRef.current, url, method);
          if (res.status === 404 || res.status === 501) {
            try {
              const dyn = await dispatchRuntime(filesRef.current, url, method, body);
              if (dyn) res = dyn;
            } catch (e) {
              res = {
                status: 500,
                contentType: "application/json;charset=utf-8",
                body: JSON.stringify({ error: e instanceof Error ? e.message : String(e) }),
              };
            }
          }
          try {
            (e.source as Window | null)?.postMessage({ source: "colo-host", type: "fetch-res", id: d.id, ...res }, "*");
          } catch {
            /* iframe gone */
          }
        })();
        return;
      }
      if (d.type === "need-reload") {
        forceReload.current = true;
        setTick((n) => n + 1);
        return;
      }
      const text = Array.isArray(d.args) ? d.args.join(" ") : String(d.args ?? "");
      if (!text && !d.level) return;
      setLogs((xs) => [...xs.slice(-80), { id: Date.now() + Math.random(), level: d.level || "log", text }]);
    }
    window.addEventListener("message", onMsg);
    return () => window.removeEventListener("message", onMsg);
  }, []);

  return (
    <div className={`preview-frame is-${frame}`}>
      <div className="pane-hd">
        <span className="label">Preview</span>
        <em>
          {wcUrl
            ? wcStatus === "running"
              ? "Node"
              : "Node…"
            : md
              ? openPath
              : swift
                ? "Playground SwiftUI"
                : hmrKind === "hmr"
                  ? "HMR"
                  : "index.html"}
        </em>
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
              forceReload.current = true;
              if (wcUrl) setWcGen((n) => n + 1);
              setTick((n) => n + 1);
            }}
          >
            <RotateCw size={14} />
          </button>
        </div>
      </div>
      <div className="preview-stage">
        {wcUrl ? (
          <iframe
            key={`${wcUrl}:${wcGen}`}
            title="Preview do workspace"
            sandbox="allow-scripts allow-forms allow-modals allow-popups allow-downloads allow-same-origin"
            src={wcUrl}
            allow="cross-origin-isolated"
          />
        ) : doc ? (
          <iframe
            key={frameId}
            ref={iframeRef}
            title="Preview do workspace"
            sandbox="allow-scripts allow-forms allow-modals allow-popups allow-downloads"
            srcDoc={doc}
            onLoad={() => {
              bootedRef.current = true;
            }}
          />
        ) : (
          <p className="preview-console-empty" style={{ padding: 16 }}>
            montando preview…
          </p>
        )}
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
