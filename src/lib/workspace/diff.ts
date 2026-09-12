export type DiffLine = { kind: "eq" | "add" | "del"; text: string };

export function lineDiff(before: string, after: string): DiffLine[] {
  const A = before.split("\n");
  const B = after.split("\n");
  const n = A.length;
  const m = B.length;
  if (n + m === 0) return [];
  if (n + m > 2500) return greedyDiff(A, B);

  const dp: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i]![j] = A[i] === B[j] ? (dp[i + 1]![j + 1]! + 1) : Math.max(dp[i + 1]![j]!, dp[i]![j + 1]!);
    }
  }
  const out: DiffLine[] = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (A[i] === B[j]) {
      out.push({ kind: "eq", text: A[i]! });
      i += 1;
      j += 1;
    } else if (dp[i + 1]![j]! >= dp[i]![j + 1]!) {
      out.push({ kind: "del", text: A[i]! });
      i += 1;
    } else {
      out.push({ kind: "add", text: B[j]! });
      j += 1;
    }
  }
  while (i < n) {
    out.push({ kind: "del", text: A[i]! });
    i += 1;
  }
  while (j < m) {
    out.push({ kind: "add", text: B[j]! });
    j += 1;
  }
  return out;
}

function greedyDiff(A: string[], B: string[]): DiffLine[] {
  const out: DiffLine[] = [];
  const max = Math.max(A.length, B.length);
  for (let i = 0; i < max; i++) {
    const a = A[i];
    const b = B[i];
    if (a === b) out.push({ kind: "eq", text: a ?? "" });
    else {
      if (a !== undefined) out.push({ kind: "del", text: a });
      if (b !== undefined) out.push({ kind: "add", text: b });
    }
  }
  return out;
}

export function fileDiff(
  path: string,
  files: Record<string, string>,
  head?: Record<string, string>,
) {
  const after = files[path];
  const before = head?.[path];
  if (after === undefined && before === undefined) return [];
  if (after === undefined) return lineDiff(before ?? "", "");
  if (before === undefined) return lineDiff("", after);
  return lineDiff(before, after);
}

export function diffStats(before: string | undefined, after: string | undefined) {
  if (before === after) return { add: 0, del: 0 };
  const rows = fileDiff("__", { __: after ?? "" }, { __: before ?? "" });
  return {
    add: rows.filter((r) => r.kind === "add").length,
    del: rows.filter((r) => r.kind === "del").length,
  };
}

export function fileStatus(before: string | undefined, after: string | undefined): "A" | "D" | "M" {
  if (before === undefined) return "A";
  if (after === undefined) return "D";
  return "M";
}
