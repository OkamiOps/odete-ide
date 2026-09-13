import { useWorkspace } from "./store";
import { untarGz } from "./zip";
import { BIN_PREFIX } from "@/lib/github/api";

type NpmInfo = { name: string; version: string; main?: string };

async function lookup(name: string): Promise<NpmInfo> {
  const local = await fetch(`/api/npm?name=${encodeURIComponent(name)}`);
  if (local.ok) {
    const j = (await local.json()) as NpmInfo & { error?: string };
    if (j.name && j.version) return j;
  }
  const r = await fetch(`https://cdn.jsdelivr.net/npm/${name}/package.json`);
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
  const res = await fetch(`/api/npm?name=${encodeURIComponent(info.name)}&pack=1`);
  if (!res.ok) throw new Error(`tarball ${info.name}: ${res.status}`);
  const tar = await untarGz(await res.arrayBuffer());
  for (const [full, bytes] of Object.entries(tar)) {
    const rel = full.replace(/^package\//, "");
    if (!rel || rel.endsWith("/") || rel.includes("/node_modules/")) continue;
    if (rel.endsWith(".node") || /\.(exe|dylib|so)$/i.test(rel)) {
      native.push(rel);
      continue;
    }
    if (bytes.length > 800_000) continue;
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

const MAX_PACKAGES = 40;
const MAX_DEPTH = 3;

export async function npmInstall(args: string[], onNote?: (s: string) => void): Promise<string> {
  const w = useWorkspace.getState();
  const pkg = parsePkg(w.readFile("package.json"));
  pkg.dependencies = pkg.dependencies ?? {};
  const requested = args.filter((a) => a && !a.startsWith("-"));
  const names = requested.length
    ? requested.map((s) => s.replace(/@[\^~>=<\d].*$/, ""))
    : Object.keys({ ...pkg.dependencies, ...pkg.devDependencies });
  if (!names.length) return "package.json sem dependências. use: npm i lodash";
  const lock: Record<string, string> = {};
  const lines: string[] = [];
  const native: string[] = [];
  const failed: string[] = [];

  async function collect(name: string, depth: number, top: boolean) {
    if (!name || lock[name] || Object.keys(lock).length >= MAX_PACKAGES) return;
    onNote?.(`baixando ${name}…`);
    let info: NpmInfo;
    try {
      info = await lookup(name);
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
    lines.push(`${depth ? "  ".repeat(depth) : ""}+ ${info.name}@${info.version}`);
    if (depth >= MAX_DEPTH) return;
    const nested = parsePkg(useWorkspace.getState().readFile(`node_modules/${info.name}/package.json`));
    for (const dep of Object.keys(nested.dependencies ?? {})) {
      await collect(dep, depth + 1, false);
    }
  }

  for (const name of names) await collect(name, 0, true);
  if (!pkg.name) pkg.name = w.projectName || "colo-app";
  w.writeFile("package.json", JSON.stringify(pkg, null, 2) + "\n");
  w.writeFile("package-lock.colo.json", JSON.stringify({ lock, at: Date.now() }, null, 2) + "\n");
  const html = w.readFile("index.html");
  if (html) w.writeFile("index.html", injectImportMap(html, lock));
  const extra = native.length
    ? `\nbinários nativos ignorados (não rodam no iPad):\n${native.slice(0, 8).join("\n")}`
    : "";
  const miss = failed.length ? `\nfalhou:\n${failed.slice(0, 8).join("\n")}` : "";
  const cap = Object.keys(lock).length >= MAX_PACKAGES ? `\nparou em ${MAX_PACKAGES} pacotes` : "";
  return `added ${Object.keys(lock).length} packages (deps até ${MAX_DEPTH} níveis)\n${lines.join("\n")}\npreview usa esm.sh + node_modules${extra}${miss}${cap}`;
}
