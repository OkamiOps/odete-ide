import { lineDiff } from "./diff";

export type Hunk = {
  id: string;
  dels: string[];
  adds: string[];
  beforeStart: number;
  afterStart: number;
};

export function hunksOf(before: string, after: string): Hunk[] {
  const rows = lineDiff(before, after);
  const out: Hunk[] = [];
  let b = 1;
  let a = 1;
  let cur: Hunk | null = null;
  const flush = () => {
    if (cur) out.push(cur);
    cur = null;
  };
  for (const r of rows) {
    if (r.kind === "eq") {
      flush();
      b += 1;
      a += 1;
      continue;
    }
    if (!cur) {
      cur = {
        id: `h${out.length}`,
        dels: [],
        adds: [],
        beforeStart: b,
        afterStart: a,
      };
    }
    if (r.kind === "del") {
      cur.dels.push(r.text);
      b += 1;
    } else {
      cur.adds.push(r.text);
      a += 1;
    }
  }
  flush();
  return out;
}

export function discardHunk(head: string, current: string, index: number) {
  const hunks = hunksOf(head, current);
  const h = hunks[index];
  if (!h) return current;
  const lines = current.split("\n");
  lines.splice(h.afterStart - 1, h.adds.length, ...h.dels);
  return lines.join("\n");
}

export function keepOnlyHunk(head: string, current: string, index: number) {
  const hunks = hunksOf(head, current);
  const h = hunks[index];
  if (!h) return head;
  const lines = head.split("\n");
  lines.splice(h.beforeStart - 1, h.dels.length, ...h.adds);
  return lines.join("\n");
}

export function addedLines(before: string, after: string) {
  const hunks = hunksOf(before, after);
  const lines = new Set<number>();
  for (const h of hunks) {
    for (let i = 0; i < h.adds.length; i++) lines.add(h.afterStart + i);
  }
  return lines;
}
