import { create } from "zustand";
import type { PointerEvent as PE } from "react";
import { useChrome } from "./chrome";
import { useWorkspace } from "./store";

export type DropSide = "left" | "right";

type DragState = {
  path: string | null;
  x: number;
  y: number;
  over: DropSide | null;
  skipClick: boolean;
  start: (path: string, x: number, y: number) => void;
  move: (x: number, y: number) => void;
  setOver: (over: DropSide | null) => void;
  cancel: () => void;
  commit: () => void;
};

function hitSide(x: number, y: number): DropSide | null {
  const stack = document.elementsFromPoint(x, y);
  for (const n of stack) {
    if (!(n instanceof HTMLElement)) continue;
    const side = n.dataset.drop;
    if (side === "left" || side === "right") return side;
  }
  return null;
}

function clearDragging() {
  document.documentElement.removeAttribute("data-dragging");
}

export const useDrag = create<DragState>((set, get) => ({
  path: null,
  x: 0,
  y: 0,
  over: null,
  skipClick: false,
  start: (path, x, y) => {
    document.documentElement.dataset.dragging = "1";
    set({ path, x, y, over: hitSide(x, y), skipClick: true });
  },
  move: (x, y) => set({ x, y, over: hitSide(x, y) }),
  setOver: (over) => set({ over }),
  cancel: () => {
    clearDragging();
    set({ path: null, over: null, skipClick: false });
  },
  commit: () => {
    const { path, over } = get();
    clearDragging();
    set({ path: null, over: null });
    if (!path || !over) return;
    const ws = useWorkspace.getState();
    const ch = useChrome.getState();
    if (over === "left") {
      ws.openFile(path);
      ch.setEditFocus("a");
      return;
    }
    ch.setAltPath(path);
    ch.setCenter("dual");
    ch.setEditFocus("b");
  },
}));

const session = {
  path: "",
  ox: 0,
  oy: 0,
  pid: -1,
  armed: false,
  live: false,
};

function detach() {
  window.removeEventListener("pointermove", onWinMove);
  window.removeEventListener("pointerup", onWinUp);
  window.removeEventListener("pointercancel", onWinUp);
  window.removeEventListener("blur", onWinBlur);
}

function onWinMove(e: PointerEvent) {
  if (!session.armed || e.pointerId !== session.pid) return;
  const dx = e.clientX - session.ox;
  const dy = e.clientY - session.oy;
  if (!session.live && Math.hypot(dx, dy) < 14) return;
  if (!session.live) begin(e.clientX, e.clientY);
  e.preventDefault();
  useDrag.getState().move(e.clientX, e.clientY);
}

function onWinUp(e: PointerEvent) {
  if (e.pointerId !== session.pid) return;
  finish(session.live);
}

function onWinBlur() {
  if (!session.armed) return;
  finish(false);
}

function finish(commit: boolean) {
  detach();
  session.armed = false;
  session.pid = -1;
  const live = session.live;
  session.live = false;
  if (commit && live) {
    useDrag.getState().commit();
    window.setTimeout(() => useDrag.setState({ skipClick: false }), 40);
    return;
  }
  useDrag.getState().cancel();
}

function begin(x: number, y: number) {
  if (session.live) return;
  session.live = true;
  useDrag.getState().start(session.path, x, y);
}

export function fileDragHandlers(path: string) {
  function down(e: PE) {
    if (e.button !== 0 && e.pointerType !== "touch") return;
    session.path = path;
    session.ox = e.clientX;
    session.oy = e.clientY;
    session.pid = e.pointerId;
    session.armed = true;
    session.live = false;
    window.addEventListener("pointermove", onWinMove, { passive: false });
    window.addEventListener("pointerup", onWinUp);
    window.addEventListener("pointercancel", onWinUp);
    window.addEventListener("blur", onWinBlur);
  }

  return { onPointerDown: down };
}
