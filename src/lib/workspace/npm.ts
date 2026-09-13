import { useWorkspace } from "./store";

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
  const imports: Record<string, string> = {};
  for (const [name, ver] of Object.entries(lock)) {
    imports[name] = `https://esm.sh/${name}@${ver}`;
  }
  const block = `<script type="importmap">${JSON.stringify({ imports }, null, 2)}</script>`;
  if (/type=["']importmap["']/.test(html)) {
    return html.replace(/<script type=["']importmap["']>[\s\S]*?<\/script>/, block);
  }
  if (/<head[^>]*>/i.test(html)) return html.replace(/<head[^>]*>/i, (h) => `${h}\n${block}`);
  return `${block}\n${html}`;
}

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
  for (const name of names) {
    onNote?.(`baixando ${name}…`);
    const info = await lookup(name);
    lock[info.name] = info.version;
    pkg.dependencies[info.name] = `^${info.version}`;
    w.writeFile(
      `node_modules/${info.name}/package.json`,
      JSON.stringify({ name: info.name, version: info.version, main: info.main || "index.js", type: "module" }, null, 2) + "\n",
    );
    lines.push(`+ ${info.name}@${info.version}`);
  }
  if (!pkg.name) pkg.name = w.projectName || "colo-app";
  w.writeFile("package.json", JSON.stringify(pkg, null, 2) + "\n");
  w.writeFile("package-lock.colo.json", JSON.stringify({ lock, at: Date.now() }, null, 2) + "\n");
  const html = w.readFile("index.html");
  if (html) w.writeFile("index.html", injectImportMap(html, lock));
  return `added ${lines.length} packages\n${lines.join("\n")}\npreview usa esm.sh via importmap`;
}
