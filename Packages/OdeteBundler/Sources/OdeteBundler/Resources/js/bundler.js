// esbuild-wasm dentro do JSC + plugin de sistema de arquivos + dev server.
(function () {
  const fs = require("fs"), path = require("path"), H = globalThis.__odete;
  let ready = null;

  globalThis.__esbuildInit = (browserJsPath, wasmPath) => {
    if (ready) return ready;
    ready = (async () => {
      const src = fs.readFileSync(browserJsPath, "utf8");
      (0, eval)(src + "\n//# sourceURL=esbuild-browser.js"); // define globalThis.esbuild (UMD)
      const bytes = fs.readFileSync(wasmPath);
      const mod = new WebAssembly.Module(bytes);
      await globalThis.esbuild.initialize({ wasmModule: mod, worker: false });
      return globalThis.esbuild.version;
    })();
    return ready;
  };

  const LOADERS = { ".js": "js", ".mjs": "js", ".cjs": "js", ".jsx": "jsx", ".ts": "ts", ".mts": "ts", ".cts": "ts", ".tsx": "tsx", ".json": "json", ".css": "css", ".txt": "text", ".md": "text", ".svg": "dataurl", ".png": "dataurl", ".jpg": "dataurl", ".jpeg": "dataurl", ".gif": "dataurl", ".webp": "dataurl", ".woff": "dataurl", ".woff2": "dataurl", ".ttf": "dataurl", ".wasm": "binary" };
  const loaderFor = (p) => LOADERS[path.extname(p).toLowerCase()] || "file";

  // plugin: resolve via o loader Node do host (node_modules, exports) e lê do disco
  const fsPlugin = (root, opts = {}) => ({
    name: "odete-fs",
    setup(build) {
      build.onResolve({ filter: /.*/ }, (args) => {
        // O arquivo real por trás de uma ilha. Precisa ser tratado aqui, e não num
        // `onResolve` próprio: o genérico é registrado primeiro e engoliria o prefixo.
        if (args.path.startsWith("odete-real:")) {
          return { path: args.path.slice("odete-real:".length), namespace: "odete-real" };
        }
        // Módulos que só existem em memória: a entrada das ilhas e o mapa delas são
        // gerados por rota, e não faz sentido escrever isso no projeto de quem usa.
        // O ponto de entrada chega como caminho absoluto, porque o esbuild junta com a
        // raiz antes de resolver; os imports de dentro chegam como foram escritos.
        if (opts.virtuais) {
          const chave = Object.prototype.hasOwnProperty.call(opts.virtuais, args.path)
            ? args.path
            : path.relative(root, args.path);
          if (Object.prototype.hasOwnProperty.call(opts.virtuais, chave)) {
            return { path: chave, namespace: "odete-virtual" };
          }
        }
        if (/^(https?:|data:|node:)/.test(args.path)) return { path: args.path, external: true };
        // Externos pedidos por quem chamou: no render do Next o React precisa ser o
        // mesmo do servidor, e `next/*` é atendido por substitutos nossos. Empacotar
        // uma segunda cópia do React quebra hooks e contexto.
        if (opts.external && opts.external.some((e) => e.endsWith("/*") ? args.path.startsWith(e.slice(0, -1)) : args.path === e)) {
          return { path: args.path, external: true };
        }
        if (args.path.startsWith("virtual:") ) return { path: args.path, namespace: "virtual" };
        const importer = args.importer || path.join(root, "index.js");
        // condição browser: tenta "browser"/"import" antes de "require"
        const r = H.resolve(args.path, importer);
        if (r && typeof r === "object") {
          const bare = !args.path.startsWith(".") && !args.path.startsWith("/");
          if (opts.externalMissing && bare) return { path: args.path, external: true }; // vai pelo import map (esm.sh)
          return { errors: [{ text: bare ? `Não achei o pacote "${args.path}" (importado por ${path.relative(root, importer)}). Rode npm install.` : `Não achei "${args.path}" importado por ${path.relative(root, importer)}.` }] };
        }
        if (r.startsWith("node:")) return { path: r, external: true };
        return { path: r, namespace: "file" };
      });
      // Fronteira de cliente: um módulo que começa com "use client" roda nos dois lados.
      // No servidor ele vira uma ilha — o componente real renderiza dentro de uma marca
      // que diz ao navegador qual módulo montar ali e com que props. Sem isso o Preview
      // mostra a página certa e ela não responde a clique nenhum.
      build.onLoad({ filter: /.*/, namespace: "odete-virtual" }, (args) => ({
        contents: opts.virtuais[args.path], loader: "js", resolveDir: root,
      }));
      build.onLoad({ filter: /.*/, namespace: "odete-real" }, (args) => ({
        contents: fs.readFileSync(args.path, "utf8"), loader: loaderFor(args.path), resolveDir: path.dirname(args.path),
      }));
      build.onLoad({ filter: /.*/, namespace: "file" }, (args) => {
        if ((opts.ilhas || opts.acoes) && /\.(tsx|jsx|ts|js|mjs)$/i.test(args.path)) {
          const src = fs.readFileSync(args.path, "utf8");
          const rel = path.relative(root, args.path);
          if (opts.ilhas && /^\s*(["'])use client\1\s*;?/.test(src)) {
            const nomes = exportadosDe(src);
            opts.ilhas[rel] = nomes;
            const linhas = [`import * as __real from ${JSON.stringify("odete-real:" + args.path)};`];
            for (const n of nomes) {
              const alvo = `__real[${JSON.stringify(n)}]`;
              const marca = `globalThis.__odeteIlha(${JSON.stringify(rel)}, ${JSON.stringify(n)}, ${alvo})`;
              linhas.push(n === "default" ? `export default ${marca};` : `export const ${n} = ${marca};`);
            }
            return { contents: linhas.join("\n"), loader: "js", resolveDir: path.dirname(args.path) };
          }
          // Fronteira de servidor: "use server" marca funções que só rodam aqui. No
          // pacote do servidor elas continuam sendo elas mesmas, com uma identidade
          // pendurada para o formulário poder dizer qual chamar; no pacote do navegador
          // viram um talão que chama a de cá pela rede, porque o corpo delas não pode
          // descer para o navegador.
          if (opts.acoes && /^\s*(["'])use server\1\s*;?/.test(src)) {
            const nomes = exportadosDe(src);
            const linhas = [];
            if (opts.acoes === "cliente") {
              // O talão é escrito inteiro aqui, e não apoiado num global: um módulo ESM
              // roda antes de quem o importa, então um global posto pela entrada ainda
              // não existiria na hora em que este corpo é avaliado.
              linhas.push(TALAO);
              for (const n of nomes) {
                const talao = `__odeteChama(${JSON.stringify(rel + "#" + n)})`;
                linhas.push(n === "default" ? `export default ${talao};` : `export const ${n} = ${talao};`);
              }
            } else {
              linhas.push(`import * as __real from ${JSON.stringify("odete-real:" + args.path)};`);
              for (const n of nomes) {
                const alvo = `__real[${JSON.stringify(n)}]`;
                const marca = `globalThis.__odeteAcaoServidor(${JSON.stringify(rel)}, ${JSON.stringify(n)}, ${alvo})`;
                linhas.push(n === "default" ? `export default ${marca};` : `export const ${n} = ${marca};`);
              }
            }
            return { contents: linhas.join("\n"), loader: "js", resolveDir: path.dirname(args.path) };
          }
        }
        return carregaArquivo(args);
      });
      const carregaArquivo = (args) => {
        const loader = loaderFor(args.path);
        if (loader === "dataurl" || loader === "binary" || loader === "file") return { contents: fs.readFileSync(args.path), loader: loader === "file" ? "dataurl" : loader, resolveDir: path.dirname(args.path) };
        return { contents: fs.readFileSync(args.path, "utf8"), loader, resolveDir: path.dirname(args.path) };
      };
    },
  });


  // O talão que o navegador recebe no lugar de uma Server Action: a função de verdade
  // fica no servidor, e daqui vai uma chamada pela rede com os argumentos em JSON.
  const TALAO = `
const __odeteSerializa = (v) => {
  if (typeof FormData !== "undefined" && v instanceof FormData) {
    const pares = [];
    v.forEach((x, k) => { if (typeof x === "string") pares.push([k, x]); });
    return { __odeteFormData: pares };
  }
  return v;
};
const __odeteChama = (id) => async (...args) => {
  const r = await fetch("/@odete/acao/" + encodeURIComponent(id), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(args.map(__odeteSerializa)),
  });
  const t = await r.text();
  let j = null;
  try { j = JSON.parse(t); } catch (e) { throw new Error(t || ("acao " + id + " falhou")); }
  if (!r.ok || j.erro) throw new Error(j && j.erro ? j.erro : "acao " + id + " falhou");
  if (j.redireciona) { location.assign(j.redireciona); return undefined; }
  return j.valor;
};
`;

  // Nomes exportados, para a ilha reexportar os mesmos. Cobre o que um componente de
  // cliente usa: `export default`, `export function X`, `export const X`.
  function exportadosDe(src) {
    const nomes = new Set();
    if (/^\s*export\s+default\b/m.test(src)) nomes.add("default");
    for (const m of src.matchAll(/^\s*export\s+(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/gm)) nomes.add(m[1]);
    for (const m of src.matchAll(/^\s*export\s+(?:const|let|var)\s+([A-Za-z_$][\w$]*)/gm)) nomes.add(m[1]);
    for (const m of src.matchAll(/^\s*export\s*\{([^}]*)\}/gm)) {
      for (const parte of m[1].split(",")) {
        const nome = parte.trim().split(/\s+as\s+/).pop().trim();
        if (nome) nomes.add(nome);
      }
    }
    return [...nomes];
  }

  globalThis.__transform = async (code, options) => {
    await ready;
    const r = await globalThis.esbuild.transform(code, options);
    return { code: r.code, map: r.map, warnings: r.warnings.map(fmtMsg) };
  };

  // só checa sintaxe: erros do esbuild sem gerar código útil
  globalThis.__lint = async (code, loader, file) => {
    await ready;
    try {
      const r = await globalThis.esbuild.transform(code, { loader, sourcefile: file, logLevel: "silent" });
      return { errors: [], warnings: r.warnings.map(fmtMsg) };
    } catch (e) {
      return { errors: (e.errors || [{ text: e.message }]).map(fmtMsg), warnings: (e.warnings || []).map(fmtMsg) };
    }
  };

  // transforma TS/ESM → CJS para o require do runtime
  globalThis.__transformCJS = async (code, file) => {
    await ready;
    const ext = path.extname(file).toLowerCase();
    const loader = { ".ts": "ts", ".tsx": "tsx", ".jsx": "jsx", ".mts": "ts", ".cts": "ts" }[ext] || "js";
    const r = await globalThis.esbuild.transform(code, { loader, format: "cjs", target: "es2022", sourcefile: file, platform: "node", supported: { "dynamic-import": true }, define: { "import.meta.url": JSON.stringify("file://" + file), "import.meta.dirname": JSON.stringify(path.dirname(file)), "import.meta.filename": JSON.stringify(file) } });
    return r.code;
  };

  const fmtMsg = (m) => ({ text: m.text, file: m.location ? m.location.file : null, line: m.location ? m.location.line : null, column: m.location ? m.location.column : null, lineText: m.location ? m.location.lineText : null });

  globalThis.__build = async (opts) => {
    await ready;
    const root = opts.root;
    try {
      const r = await globalThis.esbuild.build({
        entryPoints: opts.entries.map((e) => (path.isAbsolute(e) ? e : path.join(root, e))),
        bundle: true, write: false, format: opts.format || "esm", platform: opts.platform || "browser", target: opts.target || "es2022",
        sourcemap: opts.sourcemap === false ? false : "inline", outdir: path.join(root, opts.outdir || "dist"), outbase: root,
        jsx: "automatic", jsxDev: opts.dev !== false, minify: !!opts.minify, splitting: false, metafile: false, logLevel: "silent", absWorkingDir: root,
        define: Object.assign({ "process.env.NODE_ENV": JSON.stringify(opts.dev === false ? "production" : "development"), "import.meta.env.DEV": String(opts.dev !== false), "import.meta.env.PROD": String(opts.dev === false), "import.meta.env.MODE": JSON.stringify(opts.dev === false ? "production" : "development"), "import.meta.env.BASE_URL": '"/"', "import.meta.env.SSR": "false", "import.meta.hot": "undefined", "global": "globalThis" }, envDefines(root, opts.dev === false), opts.define || {}),
        loader: { ".png": "dataurl", ".jpg": "dataurl", ".svg": "dataurl", ".gif": "dataurl", ".webp": "dataurl", ".woff": "dataurl", ".woff2": "dataurl", ".ttf": "dataurl" },
        plugins: [fsPlugin(root, opts)], nodePaths: [path.join(root, "node_modules")], resolveExtensions: [".tsx", ".ts", ".jsx", ".js", ".mjs", ".cjs", ".json", ".css"], mainFields: opts.platform === "node" ? ["module", "main"] : ["browser", "module", "main"], conditions: opts.platform === "node" ? ["node", "import", "default"] : ["browser", "import", "default"],
      });
      return { ok: true, files: r.outputFiles.map((f) => ({ path: path.relative(root, f.path), text: f.text })), warnings: r.warnings.map(fmtMsg), errors: [] };
    } catch (e) {
      return { ok: false, files: [], warnings: (e.warnings || []).map(fmtMsg), errors: (e.errors || [{ text: e.message }]).map(fmtMsg) };
    }
  };

  function envDefines(root, prod) {
    const out = {};
    for (const f of [".env", prod ? ".env.production" : ".env.development", ".env.local"]) {
      const p = path.join(root, f);
      if (!fs.existsSync(p)) continue;
      for (const line of fs.readFileSync(p, "utf8").split("\n")) {
        const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
        if (!m) continue;
        const v = m[2].trim().replace(/^["']|["']$/g, "");
        if (m[1].startsWith("VITE_") || m[1].startsWith("PUBLIC_") || m[1].startsWith("NEXT_PUBLIC_")) { out[`import.meta.env.${m[1]}`] = JSON.stringify(v); out[`process.env.${m[1]}`] = JSON.stringify(v); }
      }
    }
    return out;
  }
})();
