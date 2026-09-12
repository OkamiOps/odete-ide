import { useEffect, useRef, useState } from "react";
import { ChevronLeft, ChevronRight, Clock, GitCommit, MessageSquarePlus, X } from "lucide-react";
import { FileGlyph } from "@/components/ide/file-glyph";
import { useChrome } from "@/lib/workspace/chrome";
import { fileDragHandlers, useDrag } from "@/lib/workspace/drag";
import { quoteSelection, useNav } from "@/lib/workspace/nav";
import { useWorkspace } from "@/lib/workspace/store";

export function EditorTabs() {
  const tabs = useWorkspace((s) => s.tabs);
  const openPath = useWorkspace((s) => s.openPath);
  const openFile = useWorkspace((s) => s.openFile);
  const closeTab = useWorkspace((s) => s.closeTab);
  const fileDirty = useWorkspace((s) => s.fileDirty);
  const center = useChrome((s) => s.center);
  const altPath = useChrome((s) => s.altPath);
  const editFocus = useChrome((s) => s.editFocus);
  const histOn = useNav((s) => s.hist);
  const blameOn = useNav((s) => s.blame);
  const scroller = useRef<HTMLDivElement>(null);
  const [more, setMore] = useState({ left: false, right: false });

  function syncMore() {
    const el = scroller.current;
    if (!el) return;
    setMore({
      left: el.scrollLeft > 6,
      right: el.scrollLeft + el.clientWidth < el.scrollWidth - 6,
    });
  }

  useEffect(() => {
    const el = scroller.current;
    if (!el) return;
    syncMore();
    const ro = new ResizeObserver(syncMore);
    ro.observe(el);
    el.addEventListener("scroll", syncMore, { passive: true });
    return () => {
      ro.disconnect();
      el.removeEventListener("scroll", syncMore);
    };
  }, [tabs, openPath]);

  useEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const on = el.querySelector<HTMLElement>(".tab.is-on");
    on?.scrollIntoView({ inline: "nearest", block: "nearest" });
    syncMore();
  }, [openPath]);

  function nudge(dir: -1 | 1) {
    scroller.current?.scrollBy({ left: dir * 180, behavior: "smooth" });
  }

  return (
    <div className={`ed-bar${more.left ? " has-left" : ""}${more.right ? " has-right" : ""}`}>
      {more.left ? (
        <button type="button" className="tab-more" aria-label="abas à esquerda" onClick={() => nudge(-1)}>
          <ChevronLeft size={18} />
        </button>
      ) : null}
      <div className="tabs" role="tablist" aria-label="Arquivos abertos" ref={scroller}>
        {tabs.map((p) => {
          const name = p.split("/").pop() ?? p;
          const on = openPath === p || (center === "dual" && altPath === p);
          return (
            <div key={p} className={on ? "tab is-on" : "tab"} role="tab" aria-selected={on}>
              <button
                type="button"
                className="tab-main"
                {...fileDragHandlers(p)}
                onClick={() => {
                  if (useDrag.getState().skipClick) return;
                  const chrome = useChrome.getState();
                  if (chrome.center === "dual" && chrome.editFocus === "b") chrome.setAltPath(p);
                  else openFile(p);
                }}
              >
                <FileGlyph path={p} />
                <span className="tab-name">{name}</span>
                {center === "dual" && editFocus === "b" && altPath === p ? <em>D</em> : null}
                {fileDirty(p) ? <i className="tab-dot" /> : null}
              </button>
              <button
                type="button"
                className="tab-x"
                aria-label={`fechar ${name}`}
                onClick={() => closeTab(p)}
              >
                <X size={16} strokeWidth={2.2} />
              </button>
            </div>
          );
        })}
      </div>
      {more.right ? (
        <button type="button" className="tab-more" aria-label="abas à direita" onClick={() => nudge(1)}>
          <ChevronRight size={18} />
        </button>
      ) : null}
      <div className="ed-acts">
        <button
          type="button"
          className={histOn ? "is-on" : undefined}
          title="Histórico"
          aria-label="Histórico"
          onClick={() => useNav.getState().setHist(!histOn)}
        >
          <Clock size={20} strokeWidth={1.7} />
        </button>
        <button
          type="button"
          className={blameOn ? "is-on" : undefined}
          title="Blame"
          aria-label="Blame"
          onClick={() => useNav.getState().setBlame(!blameOn)}
        >
          <GitCommit size={20} strokeWidth={1.7} />
        </button>
        <button
          type="button"
          title="Enviar seleção ao agente"
          aria-label="Enviar seleção ao agente"
          onClick={() => {
            if (!quoteSelection()) return;
            useChrome.setState({ agent: true, mobile: "agent" });
          }}
        >
          <MessageSquarePlus size={20} strokeWidth={1.7} />
        </button>
      </div>
    </div>
  );
}