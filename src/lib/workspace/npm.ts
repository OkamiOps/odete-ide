import { useWorkspace } from "./store";
import { pauseSync, resumeSync } from "./folder";
import { isToolPkg, parseLock } from "./npm-lock";
import { pnpmContext, resolveDepSpec } from "./pnpm";

export type NpmInfo = {
  name: string;
  version: string;
  main?: string;
  module?: string;
  dependencies?: Record<string, string>;
  peerDependencies?: Record<string, string>;
  optionalDependencies?: Record<string, string>;
};

export type StackKind = "spa" | "ssr" | "api";
export type Stack = { id: string; kind: StackKind; label: string };

export { isToolPkg, parseLock, lockOfFiles, esmImports, virtualNpmFile, virtualNpmNames } from "./npm-lock";

const MAX_PACKAGES = 1200;
const CONCURRENCY = 8;

function encName(name: string) {
  return name.startsWith("@") ? name.replace("/", "%2F") : encodeURIComponent(name);
}

export function parsePkg(raw?: string) {
  try {
    return JSON.parse(raw || "{}") as {
      name?: string;
      dependencies?: Record<string, string>;
      devDependencies?: Record<string, string>;
      peerDependencies?: Record<string, string>;
      scripts?: Record<string, string>;
    };
  } catch {
    return {};
  }
}

function specName(s: string) {
  if (s.startsWith("@")) {
    const i = s.indexOf("@", 1);
    return i > 0 ? { name: s.slice(0, i), ver: s.slice(i + 1) } : { name: s, ver: "" };
  }
  const i = s.lastIndexOf("@");
  return i > 0 ? { name: s.slice(0, i), ver: s.slice(i + 1) } : { name: s, ver: "" };
}

export function detectStack(pkg: {
  dependencies?: Record<string, string>;
  devDependencies?: Record<string, string>;
}): Stack {
  const all = { ...pkg.dependencies, ...pkg.devDependencies };
  if (all.next) return { id: "next", kind: "ssr", label: "Next.js" };
  if (all.astro) return { id: "astro", kind: "ssr", label: "Astro" };
  if (all["@remix-run/react"] || all["@remix-run/node"] || all.remix) return { id: "remix", kind: "ssr", label: "Remix" };
  if (all["@nestjs/core"]) return { id: "nest", kind: "api", label: "Nest" };
  if (all["@tanstack/react-start"] || all["@tanstack/start"]) {
    return { id: "tanstack-start", kind: "ssr", label: "TanStack Start" };
  }
  if (all.vite || all["@vitejs/plugin-react"]) return { id: "vite", kind: "spa", label: "Vite" };
  if (all["react-scripts"]) return { id: "cra", kind: "spa", label: "CRA" };
  if (all.react) return { id: "react", kind: "spa", label: "React" };
  return { id: "html", kind: "spa", label: "HTML" };
}

export function stackHint(stack: Stack) {
  if (stack.kind === "spa") {
    return `${stack.label}: npm run dev sobe o Vite no Node deste iPad. HMR de verdade.`;
  }
  if (stack.id === "nest") {
    return `Nest: npm run start sobe o servidor no Node deste iPad. o Preview aponta pra ele.`;
  }
  if (stack.id === "next") {
    return `Next: npm run dev sobe o Next neste iPad (1º boot é lento). o Preview aponta pro servidor.`;
  }
  return `${stack.label}: npm run dev/start usa o Node deste iPad.`;
}

async function lookup(name: string, want?: string): Promise<NpmInfo> {
  const q = want ? `&ver=${encodeURIComponent(want)}` : "";
  const local = await fetch(`/api/npm?name=${encName(name)}${q}`);
  if (local.ok) {
    const j = (await local.json()) as NpmInfo & { error?: string };
    if (j.name && j.version) return j;
  }
  const spec = want && /^\d/.test(want.replace(/^[vV^~>=<]+/, "")) ? `@${want.replace(/^[vV^~>=<]+/, "")}` : "";
  const r = await fetch(`https://cdn.jsdelivr.net/npm/${name}${spec}/package.json`);
  if (!r.ok) throw new Error(`${name}: ${r.status}`);
  const pkg = (await r.json()) as NpmInfo;
  if (!pkg.version) throw new Error(`${name}: sem versão`);
  return {
    name: pkg.name || name,
    version: pkg.version,
    main: pkg.main,
    dependencies: pkg.dependencies,
    peerDependencies: pkg.peerDependencies,
  };
}

export async function npmInstall(args: string[], onNote?: (s: string) => void): Promise<string> {
  const w = useWorkspace.getState();
  pauseSync();
  try {
    const pkg = parsePkg(w.readFile("package.json"));
    pkg.dependencies = pkg.dependencies ?? {};
    pkg.devDependencies = pkg.devDependencies ?? {};
    const flags = args.filter((a) => a.startsWith("-"));
    const saveDev = flags.includes("-D") || flags.includes("--save-dev");
    const production = flags.includes("--production") || flags.includes("--omit=dev");
    const unknown = flags.filter(
      (a) => !["-D", "--save-dev", "--production", "--omit=dev", "-P", "--save", "--offline", "--frozen-lockfile"].includes(a),
    );
    const requested = args.filter((a) => a && !a.startsWith("-")).map(specName);
    const ctx = pnpmContext(w.files);
    const fromFile = [
      ...Object.entries(pkg.dependencies ?? {}).map(([name, ver]) => ({
        name,
        ver,
        kind: "runtime" as const,
      })),
      ...(production
        ? []
        : Object.entries(pkg.devDependencies ?? {}).map(([name, ver]) => ({
            name,
            ver,
            kind: "tool" as const,
          }))),
    ];
    type Job = { name: string; want: string; recurse: boolean; top: boolean };
    const seed: Job[] = requested.length
      ? requested.map((n) => ({
          name: n.name,
          want: n.ver,
          recurse: !isToolPkg(n.name),
          top: true,
        }))
      : fromFile.map((n) => ({
          name: n.name,
          want: n.ver,
          recurse: n.kind === "runtime" && !isToolPkg(n.name),
          top: true,
        }));
    if (!requested.length) {
      for (const wp of ctx.packages) {
        if (!wp.dir) continue;
        seed.push({ name: wp.name, want: `workspace:${wp.version}`, recurse: true, top: false });
        for (const [dep, range] of Object.entries(wp.dependencies)) {
          seed.push({ name: dep, want: range, recurse: !isToolPkg(dep), top: false });
        }
      }
    }
    if (!seed.length) return "package.json sem dependências. use: npm i react";

    const prev = parseLock(w.readFile("package-lock.colo.json"));
    const lock: Record<string, string> = { ...prev };
    const lines: string[] = [];
    const failed: string[] = [];
    const seen = new Set<string>();
    const queue: Job[] = [];
    function enqueue(job: Job) {
      if (!job.name || seen.has(job.name)) return;
      seen.add(job.name);
      queue.push(job);
    }
    for (const j of seed) enqueue(j);

    async function process(job: Job) {
      if (Object.keys(lock).length >= MAX_PACKAGES) return;
      const resolved = resolveDepSpec(job.name, job.want || "*", ctx);
      if (resolved.kind === "workspace-missing") {
        failed.push(`${job.name}: workspace sem pacote local`);
        return;
      }
      if (resolved.kind === "workspace") {
        lock[job.name] = `workspace:${resolved.want}`;
        lines.push(`ws ${job.name}@${resolved.want}`);
        if (!job.recurse) return;
        const deps = { ...resolved.local.dependencies, ...resolved.local.peerDependencies };
        for (const [dep, range] of Object.entries(deps)) {
          enqueue({ name: dep, want: range, recurse: !isToolPkg(dep), top: false });
        }
        return;
      }
      if (resolved.kind === "file") {
        lock[job.name] = resolved.want;
        lines.push(`file ${job.name} ${resolved.want}`);
        return;
      }
      onNote?.(`resolvendo ${job.name}…`);
      let info: NpmInfo;
      try {
        info = await lookup(job.name, resolved.want === "*" ? undefined : resolved.want);
      } catch (e) {
        failed.push(`${job.name}: ${e instanceof Error ? e.message : "falhou"}`);
        return;
      }
      lock[info.name] = info.version;
      if (job.top && requested.length) {
        const bucket = saveDev ? pkg.devDependencies! : pkg.dependencies!;
        bucket[info.name] = `^${info.version}`;
      }
      lines.push(`${job.recurse ? "+" : "tool"} ${info.name}@${info.version}`);
      if (!job.recurse) return;
      for (const [dep, range] of Object.entries(info.dependencies ?? {})) {
        enqueue({ name: dep, want: range, recurse: !isToolPkg(dep), top: false });
      }
      for (const [dep, range] of Object.entries(info.peerDependencies ?? {})) {
        enqueue({ name: dep, want: range, recurse: !isToolPkg(dep), top: false });
      }
    }

    const inflightMax = CONCURRENCY;
    await new Promise<void>((resolve, reject) => {
      let inflight = 0;
      const next = () => {
        if (!queue.length && inflight === 0) return resolve();
        while (inflight < inflightMax && queue.length) {
          if (Object.keys(lock).length >= MAX_PACKAGES) {
            if (inflight === 0) return resolve();
            break;
          }
          const job = queue.shift()!;
          inflight += 1;
          process(job).then(
            () => {
              inflight -= 1;
              next();
            },
            (e) => reject(e),
          );
        }
      };
      next();
    });

    if (!pkg.name) pkg.name = w.projectName || "colo-app";
    const ws = useWorkspace.getState();
    ws.writeFile("package.json", JSON.stringify(pkg, null, 2) + "\n");
    ws.writeFile("package-lock.colo.json", JSON.stringify({ lock, at: Date.now() }, null, 2) + "\n");
    const stack = detectStack(pkg);
    const extra = unknown.length ? `\nflag ignorada: ${unknown.join(" ")}` : "";
    const miss = failed.length ? `\nfalhou:\n${failed.slice(0, 12).join("\n")}` : "";
    const cap = Object.keys(lock).length >= MAX_PACKAGES ? `\nparou em ${MAX_PACKAGES} pacotes` : "";
    const wsN = ctx.packages.filter((p) => p.dir).length;
    const wsLine = wsN ? `\nworkspace ${wsN} pacote${wsN > 1 ? "s" : ""} · catalog ${Object.keys(ctx.catalog).length}` : "";
    return `added ${lines.length} · lock ${Object.keys(lock).length}  (${stack.label})${wsLine}\n${lines.slice(0, 40).join("\n")}${lines.length > 40 ? `\n… +${lines.length - 40}` : ""}\n${stackHint(stack)}\nnode_modules não entra no editor (quota). Preview usa esm.sh + JSX/TS do Colo.${extra}${miss}${cap}`;
  } finally {
    resumeSync(useWorkspace.getState().files, useWorkspace.getState().projectId);
  }
}

export function npmRunScript(name: string | undefined): { out: string; openPreview: boolean; boot?: string } {
  const w = useWorkspace.getState();
  const pkg = parsePkg(w.readFile("package.json"));
  const scripts = pkg.scripts ?? {};
  if (!name) {
    const keys = Object.keys(scripts);
    return {
      out: keys.length ? keys.map((k) => `${k}\n  ${scripts[k]}`).join("\n") : "sem scripts em package.json",
      openPreview: false,
    };
  }
  const cmd = scripts[name];
  const stack = detectStack(pkg);
  const isDev =
    /^(dev|start|preview|serve)$/.test(name) || /\b(vite|astro|next|remix|nuxt)\b/.test(cmd || name);
  const isBuild =
    /^(build|test|lint|typecheck|tsc|format)$/.test(name) ||
    /\b(tsc|eslint|vitest|jest|playwright)\b/.test(cmd || "");
  if (!cmd && name !== "dev" && name !== "start") {
    return {
      out: `npm run ${name}: script não existe\n${Object.keys(scripts).join("  ") || "(nenhum)"}`,
      openPreview: false,
    };
  }
  if (isBuild) {
    return {
      out: `npm run ${name} — ${cmd || name}\neste iPad não executa ${name} (tsc/eslint/next build). Preview e \`node arquivo.js\` usam o runtime do Colo.`,
      openPreview: false,
    };
  }
  if (stack.kind !== "spa" && isDev) {
    return { out: `npm run ${name} — ${cmd || name}\n${stackHint(stack)}`, openPreview: true, boot: stack.id };
  }
  return {
    out: `npm run ${name} — ${cmd || "preview"}\n${stackHint(stack)}\nabri o Preview.`,
    openPreview: true,
    boot: stack.id,
  };
}
