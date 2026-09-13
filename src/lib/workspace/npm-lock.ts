const TOOL = new Set([
  "vite",
  "webpack",
  "webpack-cli",
  "esbuild",
  "rollup",
  "parcel",
  "turbo",
  "nx",
  "typescript",
  "eslint",
  "prettier",
  "vitest",
  "jsdom",
  "tsx",
  "ts-node",
  "nodemon",
  "tailwindcss",
  "postcss",
  "autoprefixer",
  "@vitejs/plugin-react",
  "@vitejs/plugin-react-swc",
  "@vitejs/plugin-vue",
  "next",
  "astro",
  "nuxt",
  "nitropack",
  "remix",
  "@remix-run/dev",
  "@remix-run/node",
  "@remix-run/serve",
  "@nestjs/cli",
  "@nestjs/core",
  "vite-node",
  "@tanstack/react-start",
  "@tanstack/start",
  "lefthook",
  "husky",
  "lint-staged",
  "fsevents",
  "node-gyp",
]);

export function isToolPkg(name: string) {
  return TOOL.has(name) || name.startsWith("@types/") || name.startsWith("@eslint/") || name.startsWith("eslint-");
}

export function parseLock(raw?: string) {
  try {
    const j = JSON.parse(raw || "{}") as { lock?: Record<string, string> };
    return j.lock ?? {};
  } catch {
    return {};
  }
}

export function lockOfFiles(files: Record<string, string>) {
  return parseLock(files["package-lock.colo.json"]);
}

export function esmImports(lock: Record<string, string>) {
  const imports: Record<string, string> = {};
  for (const [name, ver] of Object.entries(lock)) {
    if (!ver || isToolPkg(name) || /^(workspace|file|link|catalog):/.test(ver)) continue;
    imports[name] = `https://esm.sh/${name}@${ver}`;
    imports[`${name}/`] = `https://esm.sh/${name}@${ver}/`;
  }
  return imports;
}

export function virtualNpmFile(path: string, files: Record<string, string>): string | undefined {
  const m = path.match(/^node_modules\/((?:@[^/]+\/)?[^/]+)\/package\.json$/);
  if (!m) return undefined;
  const lock = lockOfFiles(files);
  const ver = lock[m[1]!];
  if (!ver) return undefined;
  return `${JSON.stringify({ name: m[1], version: ver }, null, 2)}\n`;
}

export function virtualNpmNames(prefix: string, files: Record<string, string>): string[] {
  const lock = lockOfFiles(files);
  const names = Object.keys(lock);
  if (!names.length) return [];
  if (!prefix) return ["node_modules"];
  if (prefix === "node_modules") {
    const top = new Set<string>();
    for (const n of names) top.add(n.startsWith("@") ? n.split("/")[0]! : n);
    return [...top].sort();
  }
  if (prefix.startsWith("node_modules/")) {
    const rest = prefix.slice("node_modules/".length);
    if (rest.startsWith("@") && !rest.includes("/")) {
      return names.filter((n) => n.startsWith(`${rest}/`)).map((n) => n.slice(rest.length + 1).split("/")[0]!);
    }
  }
  return [];
}
