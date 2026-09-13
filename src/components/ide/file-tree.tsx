import { useEffect, useRef, useState, type MouseEvent } from "react";
import { ChevronRight, Pencil, Plus, Trash2 } from "lucide-react";
import { FileGlyph } from "@/components/ide/file-glyph";
import { ProjectMenu } from "@/components/ide/project-hub";
import { useChrome } from "@/lib/workspace/chrome";
import { fileDragHandlers, useDrag } from "@/lib/workspace/drag";
import { useWorkspace } from "@/lib/workspace/store";

function treeFromFiles(paths: string[]) {
  const dirs = new Map<string, string[]>();
  const rootFiles: string[] = [];
  for (const p of paths.sort()) {
    const i = p.indexOf("/");
    if (i < 0) rootFiles.push(p);
    else {
      const dir = p.slice(0, i);
      const rest = p.slice(i + 1);
      const list = dirs.get(dir) ?? [];
      list.push(rest);
      dirs.set(dir, list);
    }
  }
  return { dirs, rootFiles };
}

function Guides({ depth }: { depth: number }) {
  if (depth <= 0) return null;
  return (
    <span className="tree-guides" aria-hidden>
      {Array.from({ length: depth }, (_, i) => (
        <i key={i} />
      ))}
    </span>
  );
}

function Node({
  prefix,
  paths,
  depth,
}: {
  prefix: string;
  paths: string[];
  depth: number;
}) {
  const { dirs, rootFiles } = treeFromFiles(paths);
  const [open, setOpen] = useState<Record<string, boolean>>({});
  const isOpen = (dir: string) => {
    if (dir === "node_modules" || dir === "dist" || dir === ".next" || dir === ".git" || dir === "coverage") {
      return open[dir] === true;
    }
    return open[dir] !== false;
  };

  return (
    <>
      {[...dirs.keys()].sort().map((dir) => {
        const expanded = isOpen(dir);
        const dot = dir.startsWith(".");
        return (
          <div key={prefix + dir}>
            <button
              type="button"
              className={dot ? "tree-dir is-dot" : "tree-dir"}
              aria-expanded={expanded}
              onClick={() => setOpen((v) => ({ ...v, [dir]: !expanded }))}
            >
              <Guides depth={depth} />
              <ChevronRight
                className={expanded ? "tree-chevron is-open" : "tree-chevron"}
                strokeWidth={1.8}
              />
              <FileGlyph path={dir} folder open={expanded} />
              <span className="tree-name">{dir}</span>
            </button>
            {expanded ? (
              <Node prefix={`${prefix}${dir}/`} paths={dirs.get(dir) ?? []} depth={depth + 1} />
            ) : null}
          </div>
        );
      })}
      {rootFiles.map((name) => (
        <FileRow key={prefix + name} full={prefix + name} name={name} depth={depth} />
      ))}
    </>
  );
}

function FileRow({ full, name, depth }: { full: string; name: string; depth: number }) {
  const openPath = useWorkspace((s) => s.openPath);
  const altPath = useChrome((s) => s.altPath);
  const center = useChrome((s) => s.center);
  const openFile = useWorkspace((s) => s.openFile);
  const deleteFile = useWorkspace((s) => s.deleteFile);
  const renameFile = useWorkspace((s) => s.renameFile);
  const fileDirty = useWorkspace((s) => s.fileDirty);
  const [editing, setEditing] = useState(false);
  const [next, setNext] = useState(full);
  const on = openPath === full || (center === "dual" && altPath === full);
  const dirty = fileDirty(full);
  const dot = name.startsWith(".");

  function commit() {
    const dest = next.trim();
    if (dest && dest !== full) renameFile(full, dest);
    setEditing(false);
  }

  if (editing) {
    return (
      <form
        className="tree-row"
        onSubmit={(e) => {
          e.preventDefault();
          commit();
        }}
      >
        <Guides depth={depth} />
        <span className="tree-gutter" />
        <input
          className="field tree-rename"
          value={next}
          autoFocus
          onChange={(e) => setNext(e.target.value)}
          onBlur={commit}
        />
      </form>
    );
  }

  return (
    <div className={on ? "tree-row is-on" : "tree-row"}>
      <button
        type="button"
        className={on ? "tree-file is-on" : "tree-file"}
        {...fileDragHandlers(full)}
        onClick={() => {
          if (useDrag.getState().skipClick) return;
          const chrome = useChrome.getState();
          if (chrome.center === "dual" && chrome.editFocus === "b") chrome.setAltPath(full);
          else openFile(full);
        }}
      >
        <Guides depth={depth} />
        <span className="tree-gutter" />
        <FileGlyph path={full} />
        <span className={dot ? "tree-name is-dot" : "tree-name"}>{name}</span>
        {dirty ? <span className="dot" title="modificado" /> : null}
      </button>
      <button
        type="button"
        className="tree-del"
        aria-label={`renomear ${name}`}
        onPointerDown={(e) => e.stopPropagation()}
        onClick={() => {
          setNext(full);
          setEditing(true);
        }}
      >
        <Pencil className="size-3" strokeWidth={1.6} />
      </button>
      <button
        type="button"
        className="tree-del"
        aria-label={`apagar ${name}`}
        onPointerDown={(e) => e.stopPropagation()}
        onClick={() => deleteFile(full)}
      >
        <Trash2 className="size-3" strokeWidth={1.6} />
      </button>
    </div>
  );
}

export function FileTree() {
  const files = useWorkspace((s) => s.files);
  const projectName = useWorkspace((s) => s.projectName);
  const remote = useWorkspace((s) => s.remote);
  const creating = useChrome((s) => s.creating);
  const setCreating = useChrome((s) => s.setCreating);
  const createFile = useWorkspace((s) => s.createFile);
  const [name, setName] = useState("");
  const [menuOpen, setMenuOpen] = useState(false);
  const [menu, setMenu] = useState({ top: 52, left: 56, width: 260 });
  const wrap = useRef<HTMLDivElement>(null);

  function submit() {
    const path = name.trim() || "untitled.md";
    createFile(path.includes(".") ? path : `${path}.md`);
    setName("");
    setCreating(false);
  }

  function toggleMenu(e: MouseEvent<HTMLButtonElement>) {
    const r = e.currentTarget.getBoundingClientRect();
    const width = Math.max(248, r.width + 48);
    const maxH = Math.min(420, window.innerHeight * 0.7);
    let top = r.bottom + 6;
    let left = r.left;
    if (top + Math.min(280, maxH) > window.innerHeight - 8) {
      top = Math.max(8, window.innerHeight - maxH - 8);
    }
    if (left + width > window.innerWidth - 8) left = Math.max(8, window.innerWidth - width - 8);
    setMenu({ top, left, width });
    setMenuOpen((v) => !v);
  }

  useEffect(() => {
    if (!menuOpen) return;
    function onDoc(e: Event) {
      const t = e.target as Node;
      if (wrap.current?.contains(t)) return;
      setMenuOpen(false);
    }
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") setMenuOpen(false);
    }
    document.addEventListener("mousedown", onDoc);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDoc);
      document.removeEventListener("keydown", onKey);
    };
  }, [menuOpen]);

  return (
    <div className="flex h-full min-h-0 flex-col" ref={wrap}>
      <div className="ex-hd">
        <button
          type="button"
          className={menuOpen ? "ex-proj is-on" : "ex-proj"}
          onClick={toggleMenu}
          aria-label={projectName || "Odete"}
        >
          <img className="ex-mark" src="/brand/odete-wordmark.png?v=8" alt="" />
          {projectName && !/^odete$/i.test(projectName) ? <strong>{projectName}</strong> : null}
          <ChevronRight className={menuOpen ? "tree-chevron is-open" : "tree-chevron"} size={16} strokeWidth={1.8} />
        </button>
        <button
          type="button"
          className="ex-add"
          aria-label="novo arquivo"
          onClick={() => setCreating(true)}
        >
          <Plus size={18} strokeWidth={1.8} />
        </button>
      </div>
      {menuOpen ? (
        <div className="ex-menu" style={{ top: menu.top, left: menu.left, width: menu.width }} role="menu">
          <ProjectMenu onPick={() => setMenuOpen(false)} />
        </div>
      ) : null}
      {remote ? <p className="ex-remote">{remote}</p> : null}
      {creating ? (
        <form
          className="ex-new"
          onSubmit={(e) => {
            e.preventDefault();
            submit();
          }}
        >
          <input
            autoFocus
            className="field"
            placeholder="src/novo.js"
            value={name}
            onChange={(e) => setName(e.target.value)}
            onBlur={() => {
              if (!name.trim()) setCreating(false);
            }}
            onKeyDown={(e) => {
              if (e.key === "Escape") setCreating(false);
            }}
          />
        </form>
      ) : null}
      <nav className="tree" aria-label="Arquivos">
        <Node prefix="" paths={Object.keys(files)} depth={0} />
      </nav>
    </div>
  );
}
