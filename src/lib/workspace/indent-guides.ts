import { RangeSetBuilder } from "@codemirror/state";
import { Decoration, ViewPlugin, type DecorationSet, type EditorView, type ViewUpdate } from "@codemirror/view";

const mark = Decoration.mark({ class: "cm-indent-guide" });

function build(view: EditorView) {
  const builder = new RangeSetBuilder<Decoration>();
  const tab = 2;
  for (const { from, to } of view.visibleRanges) {
    let pos = from;
    while (pos <= to) {
      const line = view.state.doc.lineAt(pos);
      const m = /^( +|\t+)/.exec(line.text);
      if (m) {
        const chunk = m[1]!.includes("\t") ? 1 : tab;
        const levels = Math.floor(m[1]!.length / chunk);
        for (let i = 0; i < levels; i++) {
          const at = line.from + i * chunk;
          if (at < line.to) builder.add(at, at + 1, mark);
        }
      }
      pos = line.to + 1;
    }
  }
  return builder.finish();
}

export function indentGuides() {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      constructor(view: EditorView) {
        this.decorations = build(view);
      }
      update(u: ViewUpdate) {
        if (u.docChanged || u.viewportChanged) this.decorations = build(u.view);
      }
    },
    { decorations: (v) => v.decorations },
  );
}
