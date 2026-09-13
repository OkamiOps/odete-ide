import { useWorkspace } from "./store";
import { untarGz } from "./zip";
import { BIN_PREFIX } from "@/lib/github/api";
import { pauseSync, resumeSync } from "./folder";

type NpmInfo = { name: string; version: string; main?: string };

function encName(name: string) {
  return name.startsWith("@") ? name.replace("/", "%2F") : encodeURIComponent(name);
}

async function lookup(name: string, want?: string): Promise<NpmInfo> {
  const q = want ? `&ver=${encodeURIComponent(want)}` : "";
  const local = await fetch(`/api/npm?name=${encName(name)}${q}`);
  if (local.ok) {
    const j = (await local.json()) as NpmInfo & { error?: string };
    if (j.name && j.version) return j;
  }
  const spec = want && /^\d/.test(want.replace(/^[vV]/, "")) ? `@${want.replace(/^[vV]/, "")}` : "";
  const r = await fetch(`https://cdn.jsdelivr.net/npm/${name}${spec}/package.json`);
  if (!r.ok) throw new Error(`${name}: ${r.status}`);
  const pkg = (await r.json()) as { name?: string; version?: string; main?: string };
  if (!pkg.version) throw new Error(`${name}: sem versão`);
  return { name: pkg.name || name, version: pkg.version, main: pkg.main };
}

function parsePkg(raw?: string) {
  try {
    return JSON.parse(raw || "{}") as {
      name?: string;
      dependencies?: Record<string, string>;
      devDependencies?: Record<string, string>;
    };
  } catch {
    return {};
  }
}

function parseLock(raw?: string) {
  try {
    const j = JSON.parse(raw || "{}") as { lock?: Record<string, string> };
    return j.lock ?? {};
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

function injectImportMap(html: string, lock: Record<string, string>) {
  let prev: Record<string, string> = {};
  const hit = html.match(/<script type=["']importmap["']>([\s\S]*?)<\/script>/);
  if (hit) {
    try {
      prev = ((JSON.parse(hit[1]!) as { imports?: Record<string, string> }).imports ?? {});
    } catch {
      prev = {};
    }
  }
  const imports: Record<string, string> = { ...prev };
  for (const [name, ver] of Object.entries(lock)) {
    imports[name] = `https://esm.sh/${name}@${ver}`;
    imports[`${name}/`] = `https://esm.sh/${name}@${ver}/`;
  }
  const block = `<script type="importmap">${JSON.stringify({ imports }, null, 2)}</script>`;
  if (hit) return html.replace(/<script type=["']importmap["']>[\s\S]*?<\/script>/, block);
  if (/<head[^>]*>/i.test(html)) return html.replace(/<head[^>]*>/i, (h) => `${h}\n${block}`);
  return `${block}\n${html}`;
}

function isTextBytes(bytes: Uint8Array) {
  const n = Math.min(bytes.length, 800);
  for (let i = 0; i < n; i++) if (bytes[i] === 0) return false;
  return true;
}

async function unpackPackage(info: NpmInfo, onNote?: (s: string) => void) {
  const w = useWorkspace.getState();
  const native: string[] = [];
  let files = 0;
  const res = await fetch(`/api/npm?name=${encName(info.name)}&ver=${encodeURIComponent(info.version)}&pack=1`);
  if (!res.ok) throw new Error(`tarball ${info.name}: ${res.status}`);
  const tar = await untarGz(await res.arrayBuffer());
  for (const [full, bytes] of Object.entries(tar)) {
    const rel = full.replace(/^package\//, "");
    if (!rel || rel.endsWith("/") || rel.includes("/node_modules/")) continue;
    if (rel.endsWith(".node") || /\.(exe|dylib|so)$/i.test(rel)) {
      native.push(rel);
      continue;
    }
    if (bytes.length > 1_200_000) continue;
    const dest = `node_modules/${info.name}/${rel}`;
    if (isTextBytes(bytes)) {
      w.writeFile(dest, new TextDecoder("utf-8", { fatal: false }).decode(bytes));
    } else {
      let bin = "";
      bytes.forEach((b) => {
        bin += String.fromCharCode(b);
      });
      w.writeFile(dest, `${BIN_PREFIX}application/octet-stream;${btoa(bin)}`);
    }
    files += 1;
  }
  onNote?.(`${info.name}@${info.version}  ${files} arquivos`);
  return native;
}

const MAX_PACKAGES = 250;

export async function npmInstall(args: string[], onNote?: (s: string) => void): Promise<string> {
  const w = useWorkspace.getState();
  pauseSync();
  try {
    const pkg = parsePkg(w.readFile("package.json"));
    pkg.dependencies = pkg.dependencies ?? {};
    const requested = args.filter((a) => a && !a.startsWith("-"));
    const names = requested.length
      ? requested.map(specName)
      : Object.keys({ ...pkg.dependencies, ...pkg.devDependencies }).map((name) => ({
          name,
          ver: (pkg.dependencies?.[name] || pkg.devDependencies?.[name] || "").replace(/^[\^~>=<]+/, ""),
        }));
    if (!names.length) return "package.json sem dependências. use: npm i lodash";
    const lock: Record<string, string> = { ...parseLock(w.readFile("package-lock.colo.json")) };
    const lines: string[] = [];
    const native: string[] = [];
    const failed: string[] = [];

    async function collect(name: string, want: string, top: boolean) {
      if (!name || lock[name] || Object.keys(lock).length >= MAX_PACKAGES) return;
      onNote?.(`baixando ${name}…`);
      let info: NpmInfo;
      try {
        info = await lookup(name, want);
      } catch (e) {
        failed.push(`${name}: ${e instanceof Error ? e.message : "falhou"}`);
        return;
      }
      lock[info.name] = info.version;
      if (top) {
        pkg.dependencies = pkg.dependencies ?? {};
        pkg.dependencies[info.name] = `^${info.version}`;
      }
      const n = await unpackPackage(info, onNote);
      native.push(...n.map((f) => `${info.name}/${f}`));
      lines.push(`+ ${info.name}@${info.version}`);
      const nested = parsePkg(useWorkspace.getState().readFile(`node_modules/${info.name}/package.json`));
      for (const dep of Object.keys(nested.dependencies ?? {})) {
        await collect(dep, "", false);
      }
    }

    for (const n of names) await collect(n.name, n.ver, true);
    if (!pkg.name) pkg.name = w.projectName || "colo-app";
    const ws = useWorkspace.getState();
    ws.writeFile("package.json", JSON.stringify(pkg, null, 2) + "\n");
    ws.writeFile("package-lock.colo.json", JSON.stringify({ lock, at: Date.now() }, null, 2) + "\n");
    const html = ws.readFile("index.html");
    if (html) ws.writeFile("index.html", injectImportMap(html, lock));
    const extra = native.length
      ? `\nbinários nativos ignorados (não rodam no iPad):\n${native.slice(0, 8).join("\n")}`
      : "";
    const miss = failed.length ? `\nfalhou:\n${failed.slice(0, 12).join("\n")}` : "";
    const cap = Object.keys(lock).length >= MAX_PACKAGES ? `\nparou em ${MAX_PACKAGES} pacotes (quota do iPad)` : "";
    return `added ${lines.length} packages · lock ${Object.keys(lock).length}\n${lines.join("\n")}\npreview usa esm.sh + node_modules${extra}${miss}${cap}`;
  } finally {
    resumeSync(useWorkspace.getState().files, useWorkspace.getState().projectId);
  }
}