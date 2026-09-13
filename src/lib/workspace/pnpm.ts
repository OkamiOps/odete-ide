import type { FileMap } from "./types";

export type PnpmWorkspace = {
  packages: string[];
  catalog: Record<string, string>;
  catalogs: Record<string, Record<string, string>>;
};

export type WsPkg = {
  name: string;
  dir: string;
  version: string;
  dependencies: Record<string, string>;
  devDependencies: Record<string, string>;
  peerDependencies: Record<string, string>;
  main?: string;
  module?: string;
};

export type PnpmCtx = {
  packages: WsPkg[];
  catalog: Record<string, string>;
  catalogs: Record<string, Record<string, string>>;
};

export type ResolvedSpec =
  | { kind: "registry"; want: string }
  | { kind: "workspace"; want: string; local: WsPkg }
  | { kind: "workspace-missing"; want: string }
  | { kind: "file"; want: string };

function unquote(s: string) {
  const t = s.trim();
  if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) return t.slice(1, -1);
  return t;
}

function parseJson(raw?: string): Record<string, unknown> {
  try {
    return JSON.parse(raw || "{}") as Record<string, unknown>;
  } catch {
    return {};
  }
}

function asDeps(v: unknown): Record<string, string> {
  if (!v || typeof v !== "object") return {};
  const out: Record<string, string> = {};
  for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
    if (typeof val === "string") out[k] = val;
  }
  return out;
}

export function parsePnpmWorkspace(raw?: string): PnpmWorkspace {
  const packages: string[] = [];
  const catalog: Record<string, string> = {};
  const catalogs: Record<string, Record<string, string>> = {};
  if (!raw) return { packages, catalog, catalogs };
  let section: "none" | "packages" | "catalog" | "catalogs" = "none";
  let named: string | null = null;
  for (const line of raw.split(/\r?\n/)) {
    if (/^\s*#/.test(line) || !line.trim()) continue;
    const indent = line.match(/^\s*/)?.[0].length ?? 0;
    const t = line.trim();
    if (indent === 0 && t.endsWith(":")) {
      const key = t.slice(0, -1).trim();
      section = key === "packages" ? "packages" : key === "catalog" ? "catalog" : key === "catalogs" ? "catalogs" : "none";
      named = null;
      continue;
    }
    if (section === "packages" && t.startsWith("-")) {
      packages.push(unquote(t.replace(/^-/, "")));
      continue;
    }
    if (section === "catalog" && t.includes(":")) {
      const i = t.indexOf(":");
      catalog[unquote(t.slice(0, i))] = unquote(t.slice(i + 1));
      continue;
    }
    if (section === "catalogs") {
      if (indent <= 2 && t.endsWith(":") && !t.startsWith("-")) {
        named = unquote(t.slice(0, -1));
        catalogs[named] = catalogs[named] ?? {};
        continue;
      }
      if (named && t.includes(":")) {
        const i = t.indexOf(":");
        catalogs[named]![unquote(t.slice(0, i))] = unquote(t.slice(i + 1));
      }
    }
  }
  return { packages, catalog, catalogs };
}

export function matchWorkspaceGlob(glob: string, dir: string) {
  const g = glob.replace(/^\.\//, "").replace(/\/$/, "");
  const d = dir.replace(/^\.\//, "").replace(/\/$/, "");
  if (g === "." || g === "") return d === "" || d === ".";
  if (g === d) return true;
  const re = new RegExp(
    `^${g
      .replace(/[.+^${}()|[\]\\]/g, "\\$&")
      .replace(/\*\*/g, "::DS::")
      .replace(/\*/g, "[^/]+")
      .replace(/::DS::/g, ".*")}$`,
  );
  return re.test(d);
}

export function workspacePackages(files: FileMap): WsPkg[] {
  const yaml = parsePnpmWorkspace(files["pnpm-workspace.yaml"] || files["pnpm-workspace.yml"] || "");
  const root = parseJson(files["package.json"]);
  const pkgWs = root.workspaces;
  const extra: string[] = [];
  if (Array.isArray(pkgWs)) extra.push(...pkgWs.filter((x): x is string => typeof x === "string"));
  else if (pkgWs && typeof pkgWs === "object" && Array.isArray((pkgWs as { packages?: unknown }).packages)) {
    extra.push(...(pkgWs as { packages: string[] }).packages);
  }
  const globs = [...yaml.packages, ...extra];
  const out: WsPkg[] = [];
  const seen = new Set<string>();
  function add(pathPkg: string, dir: string) {
    const j = parseJson(files[pathPkg]);
    const name = typeof j.name === "string" && j.name ? j.name : dir || "root";
    if (seen.has(name)) return;
    seen.add(name);
    out.push({
      name,
      dir,
      version: typeof j.version === "string" ? j.version : "0.0.0",
      dependencies: asDeps(j.dependencies),
      devDependencies: asDeps(j.devDependencies),
      peerDependencies: asDeps(j.peerDependencies),
      main: typeof j.main === "string" ? j.main : undefined,
      module: typeof j.module === "string" ? j.module : undefined,
    });
  }
  add("package.json", "");
  if (globs.length) {
    for (const k of Object.keys(files)) {
      if (!k.endsWith("/package.json") || k === "package.json") continue;
      const dir = k.slice(0, -"/package.json".length);
      if (globs.some((g) => matchWorkspaceGlob(g, dir))) add(k, dir);
    }
  }
  return out;
}

export function pnpmContext(files: FileMap): PnpmCtx {
  const yaml = parsePnpmWorkspace(files["pnpm-workspace.yaml"] || files["pnpm-workspace.yml"] || "");
  const root = parseJson(files["package.json"]);
  const field = (root.pnpm ?? {}) as {
    catalog?: Record<string, string>;
    catalogs?: Record<string, Record<string, string>>;
  };
  return {
    packages: workspacePackages(files),
    catalog: { ...yaml.catalog, ...(field.catalog ?? {}) },
    catalogs: { ...yaml.catalogs, ...(field.catalogs ?? {}) },
  };
}

export function resolveDepSpec(name: string, spec: string, ctx: PnpmCtx): ResolvedSpec {
  const s = (spec || "*").trim();
  if (/^workspace:/.test(s)) {
    const local = ctx.packages.find((p) => p.name === name);
    if (!local) return { kind: "workspace-missing", want: s };
    return { kind: "workspace", want: local.version, local };
  }
  if (/^catalog:/.test(s)) {
    const named = s.slice("catalog:".length).trim();
    const ver = named ? ctx.catalogs[named]?.[name] : ctx.catalog[name];
    return { kind: "registry", want: ver || "*" };
  }
  if (/^(file|link):/.test(s)) return { kind: "file", want: s };
  return { kind: "registry", want: s || "*" };
}

export function workspaceEntry(files: FileMap, pkg: WsPkg): string | undefined {
  const prefixed = (p: string) => {
    const clean = p.replace(/^\.\//, "");
    return pkg.dir ? `${pkg.dir}/${clean}` : clean;
  };
  const tries = [
    pkg.module && prefixed(pkg.module),
    pkg.main && prefixed(pkg.main),
    prefixed("src/index.ts"),
    prefixed("src/index.tsx"),
    prefixed("src/index.js"),
    prefixed("src/index.jsx"),
    prefixed("index.ts"),
    prefixed("index.tsx"),
    prefixed("index.js"),
    prefixed("index.jsx"),
  ].filter((x): x is string => !!x);
  return tries.find((p) => files[p] !== undefined);
}

export function workspaceImportAliases(files: FileMap): Record<string, string> {
  const out: Record<string, string> = {};
  for (const pkg of workspacePackages(files)) {
    if (!pkg.dir) continue;
    const entry = workspaceEntry(files, pkg);
    if (!entry) continue;
    out[pkg.name] = `/${entry}`;
  }
  return out;
}
