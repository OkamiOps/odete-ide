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

  // ---- memória entre builds ----
  // O rebuild incremental do esbuild só pula a análise de quem chegou igual: o plugin
  // continua sendo chamado para cada import e cada arquivo, a cada build. Sem memória
  // aqui, todo rebuild relia o react-dom inteiro do disco e o recodificava em UTF-8 no
  // JS interpretado, só para o esbuild descobrir que era o mesmo texto. Os bytes ficam
  // guardados até alguém dizer que o arquivo mudou (`__esqueceArquivos`, que o dev
  // server chama com o que o observador viu).
  const leituras = new Map(); // caminho → bytes lidos
  // Data de modificação de cada arquivo do projeto quando um build o leu. O observador do
  // lado nativo compara com a do disco ao começar a vigiar: se mudou entre o build ler e
  // o observador armar, a mudança não se perde.
  const mtimes = new Map();
  // Resolução de import muda quando arquivo nasce ou some. Em vez de achar cada cache,
  // quem guarda confere esta geração e se esvazia sozinho quando ela anda.
  let geracaoDeResolucao = 0;
  // `node_modules.nosync` é onde os pacotes moram de verdade em projeto do iCloud.
  const ehDoProjeto = (p) => p.indexOf("/node_modules/") < 0 && p.indexOf("/node_modules.nosync/") < 0;

  globalThis.__esqueceArquivos = (caminhos, estrutura) => {
    for (const c of caminhos || []) { leituras.delete(c); mtimes.delete(c); }
    if (estrutura) geracaoDeResolucao++;
  };
  globalThis.__esqueceTudo = () => { leituras.clear(); mtimes.clear(); geracaoDeResolucao++; };
  // Só o que ainda é dependência de alguém fica: um arquivo que saiu do grafo deixa de
  // ser vigiado, e bytes guardados dele ficariam velhos sem ninguém avisar.
  globalThis.__guardaSo = (vivos) => {
    for (const c of [...leituras.keys()]) if (!vivos.has(c)) leituras.delete(c);
  };
  globalThis.__mtimeLido = (p) => (mtimes.has(p) ? mtimes.get(p) : null);

  function anotaMtime(p) {
    if (!ehDoProjeto(p)) return;
    try { mtimes.set(p, fs.statSync(p).mtimeMs); } catch (e) { mtimes.delete(p); }
  }

  // ---- dependências pré-empacotadas ----
  // No dev server, o que um import de pacote resolve (`react`, `react-dom/client`) sai do
  // bundle do app e vai para um pacote de dependências à parte, feito uma vez e guardado
  // em disco (dependencias.js). O bundle do app fica só com o código do projeto: o
  // rebuild depois de editar o App.tsx liga e imprime só isso, e não o react-dom inteiro.
  //
  // No lugar do pacote, o app recebe dois módulos pequenos:
  //   - um CommonJS que pega o módulo no registro que o pacote de dependências preenche
  //     (`globalThis.__odeteDep`), igual a um `require` — então o `import` do app passa
  //     pela mesma interoperação CJS↔ESM do esbuild que teria se o pacote estivesse junto;
  //   - um ESM na frente dele (`export *` e `export default`), para que `default` siga o
  //     `__esModule` como no Vite (e num pacote ESM seja o default de verdade): direto, num
  //     projeto `"type": "module"` o esbuild usaria a regra do Node e daria o objeto inteiro.
  // Os caminhos virtuais não podem terminar em `.mjs`: a extensão decide o formato mesmo
  // fora do disco. Por isso o sufixo.
  const SUFIXO_DEP = "?odete", SUFIXO_DEP_CJS = "?odete.cjs";
  const CODIGO_DE_PACOTE = /\.([mc]?[jt]s|[jt]sx)$/i;
  const TIPOS_DE_IMPORT = new Set(["import-statement", "require-call", "dynamic-import"]);
  const dentroDePacote = (p) => p.indexOf("/node_modules/") >= 0 || p.indexOf("/node_modules.nosync/") >= 0;

  // Só código de pacote instalado entra: CSS e JSON de pacote seguem no bundle do app (a
  // folha dele sai junto com a do app), e um pacote ligado (`npm link`, workspace) é
  // código que a pessoa edita, então continua no app e é refeito como o resto.
  function vaiParaAsDependencias(abs, kind) {
    if (!TIPOS_DE_IMPORT.has(kind) || !CODIGO_DE_PACOTE.test(abs) || !dentroDePacote(abs)) return false;
    try { return dentroDePacote(fs.realpathSync(abs)); } catch (e) { return false; }
  }

  // O que o bundle do app pediu ao pacote de dependências, a partir do metafile.
  function dependenciasDe(metafile) {
    if (!metafile) return null;
    const out = [];
    for (const k of Object.keys(metafile.inputs)) {
      if (k.startsWith("odete-dep:")) out.push(k.slice("odete-dep:".length, -SUFIXO_DEP.length));
    }
    return out;
  }

  // plugin: resolve via o loader Node do host (node_modules, exports) e lê do disco
  const fsPlugin = (root, opts = {}) => ({
    name: "odete-fs",
    setup(build) {
      // Com memória, a resolução de cada import também fica guardada entre rebuilds: são
      // centenas de idas ao nativo por build num projeto de verdade, para a mesma resposta.
      let resolvidos = new Map(), geracao = geracaoDeResolucao;
      build.onResolve({ filter: /.*/ }, (args) => {
        if (!opts.memoria) return resolve(args);
        if (geracao !== geracaoDeResolucao) { resolvidos = new Map(); geracao = geracaoDeResolucao; }
        const chave = args.importer + "\0" + args.path;
        const guardado = resolvidos.get(chave);
        if (guardado) return guardado;
        const r = resolve(args);
        if (r && !r.errors) resolvidos.set(chave, r);
        return r;
      });
      const resolve = (args) => {
        // O arquivo real por trás de uma ilha. Precisa ser tratado aqui, e não num
        // `onResolve` próprio: o genérico é registrado primeiro e engoliria o prefixo.
        if (args.path.startsWith("odete-real:")) {
          return { path: args.path.slice("odete-real:".length), namespace: "odete-real" };
        }
        if (args.path.startsWith("odete-dep-cjs:")) {
          return { path: args.path.slice("odete-dep-cjs:".length), namespace: "odete-dep-cjs" };
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
        const bare = !args.path.startsWith(".") && !args.path.startsWith("/");
        if (r && typeof r === "object") {
          if (opts.externalMissing && bare) return { path: args.path, external: true }; // vai pelo import map (esm.sh)
          // A pasta onde o arquivo que falta nasceria: o observador passa a olhar lá, e o
          // import quebrado se conserta sozinho quando o arquivo aparece.
          if (!bare && opts.faltando) opts.faltando.add(path.dirname(path.resolve(path.dirname(importer), args.path)));
          return { errors: [{ text: bare ? `Não achei o pacote "${args.path}" (importado por ${path.relative(root, importer)}). Rode npm install.` : `Não achei "${args.path}" importado por ${path.relative(root, importer)}.` }] };
        }
        if (r.startsWith("node:")) return { path: r, external: true };
        // O resolvedor do runtime devolve `src/./App.tsx` para `./App`. Normalizado, o
        // caminho é o mesmo que o metafile e o observador usam — senão a memória de
        // leituras guardava por uma chave e era esquecida por outra, e o rebuild servia o
        // arquivo velho. E um mesmo arquivo importado por dois caminhos não vira dois módulos.
        const abs = path.resolve(r);
        // A chave no registro é o arquivo resolvido, não o nome importado: dois nomes que
        // chegam ao mesmo arquivo são o mesmo módulo, e o pacote de dependências o carrega
        // pelo mesmo caminho que o react-dom usa por dentro — uma cópia só do React.
        if (opts.preempacota && bare && vaiParaAsDependencias(abs, args.kind)) {
          return { path: path.relative(root, abs) + SUFIXO_DEP, namespace: "odete-dep" };
        }
        return { path: abs, namespace: "file" };
      };
      build.onLoad({ filter: /.*/, namespace: "odete-dep" }, (args) => {
        const cjs = JSON.stringify("odete-dep-cjs:" + args.path.slice(0, -SUFIXO_DEP.length) + SUFIXO_DEP_CJS);
        return { contents: `export * from ${cjs};\nexport { default } from ${cjs};\n`, loader: "js", resolveDir: root };
      });
      build.onLoad({ filter: /.*/, namespace: "odete-dep-cjs" }, (args) => {
        const chave = JSON.stringify(args.path.slice(0, -SUFIXO_DEP_CJS.length));
        return { contents: `module.exports = globalThis.__odeteDep(${chave});\n`, loader: "js" };
      });
      // Fronteira de cliente: um módulo que começa com "use client" roda nos dois lados.
      // No servidor ele vira uma ilha — o componente real renderiza dentro de uma marca
      // que diz ao navegador qual módulo montar ali e com que props. Sem isso o Preview
      // mostra a página certa e ela não responde a clique nenhum.
      build.onLoad({ filter: /.*/, namespace: "odete-virtual" }, (args) => ({
        contents: opts.virtuais[args.path], loader: "js", resolveDir: root,
      }));
      build.onLoad({ filter: /.*/, namespace: "odete-real" }, (args) => {
        anotaMtime(args.path);
        return { contents: fs.readFileSync(args.path, "utf8"), loader: loaderFor(args.path), resolveDir: path.dirname(args.path) };
      });
      build.onLoad({ filter: /.*/, namespace: "file" }, (args) => {
        if ((opts.ilhas || opts.acoes) && /\.(tsx|jsx|ts|js|mjs)$/i.test(args.path)) {
          anotaMtime(args.path);
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
        const final = loader === "file" ? "dataurl" : loader;
        // Com memória, o que vai ao esbuild são bytes: texto seria recodificado em UTF-8 a
        // cada build, e bytes atravessam para o wasm como estão.
        if (opts.memoria) {
          let bytes = leituras.get(args.path);
          if (!bytes) {
            anotaMtime(args.path);
            bytes = fs.readFileSync(args.path);
            leituras.set(args.path, bytes);
          }
          return { contents: bytes, loader: final, resolveDir: path.dirname(args.path) };
        }
        // Bytes sem guardar: o pacote de dependências lê o react-dom inteiro, e raramente.
        // Guardar seria segurar um megabyte que nenhum rebuild do app vai pedir.
        if (opts.bytes) {
          anotaMtime(args.path);
          return { contents: fs.readFileSync(args.path), loader: final, resolveDir: path.dirname(args.path) };
        }
        anotaMtime(args.path);
        if (loader === "dataurl" || loader === "binary" || loader === "file") return { contents: fs.readFileSync(args.path), loader: final, resolveDir: path.dirname(args.path) };
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

  // Só checa sintaxe. O esbuild não tem modo "só analisar": a transformação sempre
  // imprime código. Então ela imprime o mínimo — sem espaço, sem comentário legal, sem
  // mapa — porque esse texto atravessa do wasm para o JS e é decodificado a cada pausa na
  // digitação, para ser jogado fora. Daqui para o Swift só vão os diagnósticos.
  globalThis.__lint = async (code, loader, file) => {
    await ready;
    try {
      const r = await globalThis.esbuild.transform(code, { loader, sourcefile: file, logLevel: "silent", minifyWhitespace: true, legalComments: "none", sourcemap: false });
      return { errors: [], warnings: r.warnings.map(fmtMsg) };
    } catch (e) {
      return { errors: (e.errors || [{ text: e.message }]).map(fmtMsg), warnings: (e.warnings || []).map(fmtMsg) };
    }
  };

  // transforma TS/ESM → CJS para o require do runtime
  //
  // `import()` vira `Promise.resolve().then(() => require(…))`: o JSContext do runtime não
  // tem carregador de módulos, e o `import()` nativo rejeita com "No module loader
  // provided". Deixado como estava, a CLI do vitest (que carrega tudo por `import()`)
  // rejeitava, a rejeição não aparecia em lugar nenhum e o processo saía com 0, mudo.
  globalThis.__transformCJS = async (code, file) => {
    await ready;
    const ext = path.extname(file).toLowerCase();
    const loader = { ".ts": "ts", ".tsx": "tsx", ".jsx": "jsx", ".mts": "ts", ".cts": "ts" }[ext] || "js";
    const r = await globalThis.esbuild.transform(code, { loader, format: "cjs", target: "es2022", sourcefile: file, platform: "node", supported: { "dynamic-import": false }, define: { "import.meta.url": JSON.stringify("file://" + file), "import.meta.dirname": JSON.stringify(path.dirname(file)), "import.meta.filename": JSON.stringify(file) } });
    return r.code;
  };

  const fmtMsg = (m) => ({ text: m.text, file: m.location ? m.location.file : null, line: m.location ? m.location.line : null, column: m.location ? m.location.column : null, lineText: m.location ? m.location.lineText : null });

  // As opções do esbuild para um pedido de build, iguais no build avulso e no contexto.
  //
  // Sourcemap só quando pedido. O padrão era `inline` para tudo: o `vite build` saía com
  // o mapa embutido no JS de produção, e o dev server gerava, codificava em base64 e
  // decodificava no JS interpretado um mapa que dobrava o tamanho do bundle — para
  // ninguém ler: o console do Preview pega arquivo e linha do evento de erro do WebKit,
  // que não passa por sourcemap.
  function opcoes(opts) {
    const root = opts.root;
    const o = {
      entryPoints: opts.entries.map((e) => (path.isAbsolute(e) ? e : path.join(root, e))),
      bundle: true, write: false, format: opts.format || "esm", platform: opts.platform || "browser", target: opts.target || "es2022",
      sourcemap: opts.sourcemap || false, outdir: path.join(root, opts.outdir || "dist"), outbase: root,
      jsx: "automatic", jsxDev: opts.dev !== false, minify: !!opts.minify, splitting: false, metafile: !!opts.metafile, logLevel: "silent", absWorkingDir: root,
      define: Object.assign({ "process.env.NODE_ENV": JSON.stringify(opts.dev === false ? "production" : "development"), "import.meta.env.DEV": String(opts.dev !== false), "import.meta.env.PROD": String(opts.dev === false), "import.meta.env.MODE": JSON.stringify(opts.dev === false ? "production" : "development"), "import.meta.env.BASE_URL": '"/"', "import.meta.env.SSR": "false", "import.meta.hot": "undefined", "global": "globalThis" }, envDefines(root, opts.dev === false), opts.define || {}),
      loader: { ".png": "dataurl", ".jpg": "dataurl", ".svg": "dataurl", ".gif": "dataurl", ".webp": "dataurl", ".woff": "dataurl", ".woff2": "dataurl", ".ttf": "dataurl" },
      plugins: [fsPlugin(root, opts)], nodePaths: [path.join(root, "node_modules")], resolveExtensions: [".tsx", ".ts", ".jsx", ".js", ".mjs", ".cjs", ".json", ".css"], mainFields: opts.platform === "node" ? ["module", "main"] : ["browser", "module", "main"], conditions: opts.platform === "node" ? ["node", "import", "default"] : ["browser", "import", "default"],
    };
    // O bundle do app com dependências pré-empacotadas começa importando o pacote delas:
    // pela regra do ESM, ele roda antes de qualquer linha do app.
    if (opts.banner) o.banner = { js: opts.banner };
    return o;
  }

  // O que, nas opções, muda o que sai do esbuild: entra na chave do cache do pacote de
  // dependências. Um `.env` com VITE_X novo, por exemplo, muda os defines e a chave.
  globalThis.__opcoesQueMudamASaida = (opts) => {
    const o = opcoes(opts);
    return JSON.stringify([o.format, o.platform, o.target, o.jsx, o.jsxDev, o.minify, o.define, o.loader, o.resolveExtensions, o.mainFields, o.conditions, !!opts.externalMissing]);
  };

  // Os arquivos que o build leu, em caminho absoluto, a partir do metafile. Módulos que
  // só existem em memória (as entradas virtuais das ilhas) não são arquivo e ficam de fora.
  function entradasDe(root, metafile) {
    if (!metafile) return null;
    const out = [];
    for (const k of Object.keys(metafile.inputs)) {
      if (k.startsWith("odete-real:")) { out.push(k.slice("odete-real:".length)); continue; }
      if (k.startsWith("file:")) { out.push(path.resolve(root, k.slice(5))); continue; }
      if (/^[a-z][a-z0-9-]*:/i.test(k)) continue;
      out.push(path.resolve(root, k));
    }
    return out;
  }

  // Resultado cru, para quem está no JS: as saídas continuam sendo os objetos do esbuild,
  // com `contents` (bytes), `hash` e o `text` preguiçoso. Comparar o hash diz se a saída
  // mudou sem decodificar nada; servir os bytes evita decodificar e recodificar o bundle.
  const sucesso = (r, opts) => ({
    ok: true, saidas: r.outputFiles || [], warnings: r.warnings.map(fmtMsg), errors: [],
    entradas: entradasDe(opts.root, r.metafile), faltando: opts.faltando ? [...opts.faltando] : [],
    dependencias: opts.preempacota ? dependenciasDe(r.metafile) : null,
  });
  const falha = (e, opts) => ({
    ok: false, saidas: [], warnings: (e.warnings || []).map(fmtMsg), errors: (e.errors || [{ text: e.message }]).map(fmtMsg),
    entradas: null, faltando: opts.faltando ? [...opts.faltando] : [], dependencias: null,
  });

  globalThis.__buildBruto = async (opts) => {
    await ready;
    if (opts.metafile) opts.faltando = new Set();
    try {
      return sucesso(await globalThis.esbuild.build(opcoes(opts)), opts);
    } catch (e) {
      return falha(e, opts);
    }
  };

  // Para o Swift (`Esbuild.build`): texto, que é o que o `vite build` grava em dist/.
  globalThis.__build = async (opts) => {
    const r = await globalThis.__buildBruto(opts);
    return { ok: r.ok, files: r.saidas.map((f) => ({ path: path.relative(opts.root, f.path), text: f.text })), warnings: r.warnings, errors: r.errors };
  };

  // ---- contextos incrementais ----
  // Um contexto do esbuild por chave (o dev server usa um por entrada servida). O
  // `rebuild()` reaproveita a análise de todo módulo cujo conteúdo não mudou, e é isso
  // que faz o rebuild depois de editar o App.tsx não reanalisar o react-dom inteiro.
  //
  // Um rebuild por vez em cada contexto, em fila: pedir outro enquanto um corre devolve
  // o resultado do que já estava correndo — que pode ter lido o arquivo antes da mudança.
  const contextos = new Map(); // chave → { ctx, opts, fila }

  // Com memória por padrão; quem não quer guardar leituras diz `memoria: false`. Os
  // módulos virtuais podem mudar entre rebuilds (a entrada do pacote de dependências
  // ganha um pacote novo): os de agora substituem os da criação.
  globalThis.__rebuild = (chave, opts) => {
    let c = contextos.get(chave);
    if (!c) {
      const o = Object.assign({ memoria: true }, opts, { metafile: true });
      const ctx = (async () => { await ready; return globalThis.esbuild.context(opcoes(o)); })();
      ctx.catch(() => {});
      c = { opts: o, fila: Promise.resolve(), ctx };
      contextos.set(chave, c);
    } else if (opts && opts.virtuais) {
      c.opts.virtuais = opts.virtuais;
    }
    const vez = c.fila.then(async () => {
      c.opts.faltando = new Set();
      try {
        const ctx = await c.ctx;
        return sucesso(await ctx.rebuild(), c.opts);
      } catch (e) {
        return falha(e, c.opts);
      }
    });
    c.fila = vez.catch(() => {});
    return vez;
  };

  // Descarta os contextos cujas chaves começam com o prefixo. Contexto vivo segura a
  // memória de tudo o que analisou; servidor que para não pode deixá-los para trás.
  globalThis.__descartaContextos = async (prefixo) => {
    const alvos = [];
    for (const [k, c] of contextos) if (k.startsWith(prefixo)) { contextos.delete(k); alvos.push(c); }
    for (const c of alvos) {
      try { await c.fila; const ctx = await c.ctx; await ctx.dispose(); } catch (e) { /* já era */ }
    }
    return alvos.length;
  };
  globalThis.__contextosVivos = () => contextos.size;

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
