// Tailwind CSS no motor do esbuild, sem o @tailwindcss/vite.
//
// O projeto faz do jeito oficial — `npm i -D tailwindcss @tailwindcss/vite`,
// `plugins: [tailwindcss()]` no vite.config e `@import "tailwindcss";` no CSS — e o
// plugin do Vite não sobe aqui: ele depende do @tailwindcss/oxide (o scanner, em Rust) e do
// lightningcss, que são binários nativos. Mas o coração do pacote `tailwindcss` v4, o
// `compile()`, é JS puro e sem dependência nenhuma. Então este arquivo faz o papel do
// plugin, como o @tailwindcss/node e o @tailwindcss/browser fazem:
//   - `compile()` do CSS de entrada, com um `loadStylesheet` que resolve `@import` com a
//     condição `style` (o `@import "tailwindcss"` é o index.css do pacote) e reescreve os
//     `url()` dos arquivos importados de outra pasta, e um `loadModule` que empacota com o
//     esbuild o `@plugin` e o `@config` (JS, TS ou ESM, com as dependências deles);
//   - os candidatos (nomes de classe) saem de um extrator em JS no lugar do oxide: os
//     arquivos do projeto (menos node_modules, o que o .gitignore esconde, CSS, lockfile e
//     binário), mais os `@source`, menos os `@source not`;
//   - o compilador fica guardado entre rebuilds: com o mesmo CSS, cada rebuild só lê de
//     novo o arquivo cuja data mudou e passa ao `build()` só os candidatos novos — o
//     compilador acumula, como no Vite, e sem candidato novo devolve o CSS que já tinha.
//
// O que fica de fora é o lightningcss: sem prefixos de navegador e sem as transformações
// dele. O `vite build` achata o CSS aninhado pelo esbuild (`supported: { nesting: false }`
// no bundler.js) e minifica pelo esbuild; o resto sai como o `compile()` escreve.
//
// Tailwind v3 (tailwind.config.js + PostCSS): o pacote `tailwindcss` v3 é um plugin do
// PostCSS em JS puro. Ele e o `postcss` do projeto são empacotados juntos pelo esbuild (uma
// vez por versão) e rodam com a config, também empacotada pelo esbuild.
(function () {
  const fs = require("fs"), path = require("path"), H = globalThis.__odete;
  const texto = (k, ...a) => globalThis.__odeteTexto(k, ...a);

  // Features do compile() (lib.d.mts): AtApply | JsPluginCompat | ThemeFunction |
  // Utilities | Variants. Sem nenhuma delas o CSS sai como entrou, igual ao plugin do Vite.
  const PRECISA_GERAR = 1 | 4 | 8 | 16 | 32;
  const UTILITIES = 16;

  // O que denuncia um CSS do Tailwind. Procura por texto (indexOf é nativo): o CSS comum
  // do projeto não paga o compile().
  const MARCAS = ['@import "tailwindcss', "@import 'tailwindcss", "@tailwind", "@apply", "@theme", "@utility",
    "@custom-variant", "@variant", "@plugin", "@config", "@source", "@reference", "theme(", "--spacing(", "--alpha("];
  function ehDoTailwind(css) {
    for (const m of MARCAS) if (css.indexOf(m) >= 0) return true;
    return false;
  }

  // ---- o pacote ----
  // O `tailwindcss` que o CSS enxerga, pelo `require` do motor (condição `require`, o
  // dist/lib.js do v4). Guardado pela versão no package.json: um `npm i` que troca de
  // versão troca de compilador.
  const pacotes = new Map(); // package.json → { versao, mod }
  function pacoteTailwind(de) {
    const r = H.resolve("tailwindcss/package.json", path.join(de, "_.css"));
    if (!r || typeof r !== "string") return null;
    let versao = "";
    try { versao = JSON.parse(fs.readFileSync(r, "utf8")).version || ""; } catch (e) { return null; }
    const guardado = pacotes.get(r);
    if (guardado && guardado.versao === versao) return guardado;
    // O v4 é um arquivo só (dist/lib.js), sem dependência: vai pelo `require` do motor. O
    // v3 é carregado só quando usado (`motorV3`).
    const v4 = Number(versao.split(".")[0]) >= 4;
    const mod = v4 ? globalThis.__odete_makeRequire(path.join(de, "_.css"))("tailwindcss") : null;
    const p = { versao, mod, v4, dir: path.dirname(r) };
    pacotes.set(r, p);
    return p;
  }

  // ---- candidatos ----
  // O extrator: toda sequência sem espaço, aspas, `<`, `>`, `{`, `}` e `;`, e — para valores
  // arbitrários com aspas ou `>` dentro dos colchetes (`content-['oi']`, `[&>*]:p-4`,
  // `bg-[url('/a.png')]`) — as sequências com colchetes. Sobra lixo (`className=`,
  // `useState`), e tudo bem: o `build()` descarta o que não é classe e lembra o que já
  // descartou. Faltar é que seria ruim — a classe some da tela.
  const PALAVRA = /[^\s"'`\\<>{};]+/g;
  const COLCHETE = /[^\s"'`\\<>{};]*\[[^\s\]]*\][^\s"'`\\<>{};[]*(?:\[[^\s\]]*\][^\s"'`\\<>{};[]*)*/g;
  function candidatosDe(conteudo, saida) {
    let m;
    PALAVRA.lastIndex = 0;
    while ((m = PALAVRA.exec(conteudo))) adiciona(m[0], saida);
    if (conteudo.indexOf("[") >= 0) {
      COLCHETE.lastIndex = 0;
      while ((m = COLCHETE.exec(conteudo))) adiciona(m[0], saida);
    }
    return saida;
  }
  function adiciona(t, saida) {
    if (t.length > 200) return;
    saida.add(t);
    const ultimo = t.charCodeAt(t.length - 1);
    // Pontuação colada no fim (`flex,` numa lista, `p-4.` numa frase, `hidden:` num objeto).
    if (ultimo === 44 || ultimo === 46 || ultimo === 59 || ultimo === 58) saida.add(t.slice(0, -1));
    // `class=flex` sem aspas; `data-[a=b]:x` não é isso.
    const eq = t.indexOf("=");
    if (eq > 0 && t.lastIndexOf("[", eq) < 0 && eq < t.length - 1) adiciona(t.slice(eq + 1), saida);
    // `class:bg-red-500` do Svelte.
    if (t.startsWith("class:") && t.length > 6) saida.add(t.slice(6));
    const c0 = t.charCodeAt(0);
    if ((c0 === 40 || c0 === 44) && t.length > 1) adiciona(t.slice(1), saida);
    if (ultimo === 41 && t.indexOf("(") < 0) saida.add(t.slice(0, -1));
    // `div.flex.px-5` (Pug, Slim): cada pedaço, menos o número de `px-1.5`.
    if (t.indexOf(".") > 0 && t.indexOf("[") < 0) {
      const partes = t.split(".");
      for (let i = 0; i < partes.length; i++) {
        if (i < partes.length - 1 && /^\d/.test(partes[i + 1])) { i++; continue; }
        if (partes[i]) saida.add(partes[i]);
      }
    }
  }

  // ---- o que varrer ----
  // Como o oxide: binário, CSS, lockfile e mapa não têm classe. Arquivo grande demais é
  // gerado (um JSON de dados, um bundle), e sem JIT custaria mais do que vale.
  const PULA_EXT = new Set(["png", "jpg", "jpeg", "gif", "webp", "avif", "ico", "bmp", "tif", "tiff", "heic", "woff", "woff2",
    "ttf", "otf", "eot", "mp3", "mp4", "m4a", "webm", "ogg", "wav", "mov", "avi", "pdf", "zip", "gz", "tgz", "br", "7z", "rar",
    "wasm", "node", "exe", "dll", "so", "dylib", "psd", "sketch", "fig", "css", "scss", "sass", "less", "styl", "map", "lock",
    "lockb", "tsbuildinfo", "log", "DS_Store"]);
  const PULA_NOME = new Set(["package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", ".DS_Store"]);
  // Pastas que a detecção automática não desce: pacotes, controle de versão, metadado.
  const PULA_PASTA = new Set(["node_modules", "node_modules.nosync", ".git", ".hg", ".svn", ".odete", ".next", ".turbo", ".vercel", ".svelte-kit"]);
  const TETO_DE_BYTES = 1024 * 1024;

  function deveLer(nome) {
    if (PULA_NOME.has(nome)) return false;
    const i = nome.lastIndexOf(".");
    return !(i >= 0 && PULA_EXT.has(nome.slice(i + 1).toLowerCase()));
  }

  // Listagem de pasta guardada pela data dela: nascer ou sumir arquivo muda a data da
  // pasta, editar arquivo não. Um rebuild que não criou nada relê só datas.
  const listagens = new Map(); // pasta → { mt, itens: [[nome, ehPasta]] }
  function lista(dir) {
    let st;
    try { st = fs.statSync(dir); } catch (e) { listagens.delete(dir); return []; }
    const g = listagens.get(dir);
    if (g && g.mt === st.mtimeMs) return g.itens;
    let entradas = [];
    try { entradas = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return []; }
    const itens = entradas.map((d) => [d.name, d.isDirectory()]);
    listagens.set(dir, { mt: st.mtimeMs, itens });
    return itens;
  }

  // Candidatos de um arquivo, guardados pela data e pelo tamanho.
  const porArquivo = new Map(); // arquivo → { mt, tam, lista }
  function candidatosDoArquivo(f) {
    let st;
    try { st = fs.statSync(f); } catch (e) { porArquivo.delete(f); return null; }
    const g = porArquivo.get(f);
    if (g && g.mt === st.mtimeMs && g.tam === st.size) return g;
    if (st.size > TETO_DE_BYTES) { const vazio = { mt: st.mtimeMs, tam: st.size, lista: [] }; porArquivo.set(f, vazio); return vazio; }
    let conteudo;
    try { conteudo = fs.readFileSync(f, "utf8"); } catch (e) { return null; }
    const novo = { mt: st.mtimeMs, tam: st.size, lista: [...candidatosDe(conteudo, new Set())] };
    porArquivo.set(f, novo);
    return novo;
  }

  // ---- glob ----
  // `**`, `*`, `?`, `{a,b}` e `[...]`; o resto é literal.
  function globParaRegex(glob) {
    let r = "", i = 0, chaves = 0;
    while (i < glob.length) {
      const c = glob[i];
      if (c === "*") {
        if (glob[i + 1] === "*") {
          if (glob[i + 2] === "/") { r += "(?:.*/)?"; i += 3; continue; }
          r += ".*"; i += 2; continue;
        }
        r += "[^/]*";
      } else if (c === "?") r += "[^/]";
      else if (c === "{") { r += "(?:"; chaves++; }
      else if (c === "}" && chaves) { r += ")"; chaves--; }
      else if (c === "," && chaves) r += "|";
      else if (c === "[") { const f = glob.indexOf("]", i); if (f > i) { r += glob.slice(i, f + 1); i = f + 1; continue; } r += "\\["; }
      else r += c.replace(/[.+^$()|\\\]]/g, "\\$&");
      i++;
    }
    return new RegExp("^" + r + "$");
  }
  const temGlob = (s) => /[*?{[]/.test(s);

  // Base + padrão → a pasta onde começar e, se houver curinga, o teste do resto.
  function fonteDe(base, padrao) {
    const abs = path.resolve(base, padrao);
    if (!temGlob(abs)) return { pasta: abs, teste: null };
    const partes = abs.split("/");
    const fixas = [];
    for (const p of partes) { if (temGlob(p)) break; fixas.push(p); }
    const pasta = fixas.join("/") || "/";
    return { pasta, teste: globParaRegex(partes.slice(fixas.length).join("/")) };
  }

  // ---- .gitignore ----
  // O suficiente do formato: comentário, `!`, `/` no fim só para pasta, `/` no começo ou no
  // meio ancora na pasta do arquivo; sem `/`, o nome vale em qualquer profundidade.
  const gitignores = new Map(); // pasta → { mt, regras } (regras vazias se não há arquivo)
  function regrasDe(dir) {
    const f = path.join(dir, ".gitignore");
    let st;
    try { st = fs.statSync(f); } catch (e) { return null; }
    const g = gitignores.get(f);
    if (g && g.mt === st.mtimeMs) return g.regras;
    const regras = [];
    let conteudo = "";
    try { conteudo = fs.readFileSync(f, "utf8"); } catch (e) { /* sem permissão */ }
    for (let linha of conteudo.split("\n")) {
      linha = linha.replace(/\r$/, "").replace(/(?<!\\)\s+$/, "");
      if (!linha || linha[0] === "#") continue;
      let nega = false;
      if (linha[0] === "!") { nega = true; linha = linha.slice(1); }
      let soPasta = false;
      if (linha.endsWith("/")) { soPasta = true; linha = linha.slice(0, -1); }
      const ancorada = linha.indexOf("/") >= 0;
      if (linha[0] === "/") linha = linha.slice(1);
      const re = globParaRegex(ancorada ? linha : "**/" + linha);
      regras.push({ re, nega, soPasta, ancorada });
    }
    gitignores.set(f, { mt: st.mtimeMs, regras });
    return regras;
  }

  // Cada .gitignore vale a partir da pasta dele; o de dentro vem depois e ganha.
  function ignorado(pilha, abs, ehPasta) {
    let fora = false;
    for (const { dir, regras } of pilha) {
      const rel = path.relative(dir, abs);
      for (const r of regras) {
        if (r.soPasta && !ehPasta) continue;
        if (r.re.test(rel) || (!r.ancorada && r.re.test(path.basename(abs)))) fora = !r.nega;
      }
    }
    return fora;
  }

  // Anda pela pasta e chama `cada(arquivo)`. `auto`: a detecção automática, que respeita
  // o .gitignore e pula as pastas de sempre; um `@source` explícito não respeita — ele é
  // justamente o jeito de pedir um pacote de node_modules.
  function anda(raiz, teste, auto, negados, cada, pastas) {
    const visitar = (dir, pilha) => {
      pastas.add(dir);
      let atual = pilha;
      if (auto) { const r = regrasDe(dir); if (r && r.length) atual = pilha.concat([{ dir, regras: r }]); }
      for (const [nome, ehPasta] of lista(dir)) {
        const abs = path.join(dir, nome);
        if (ehPasta) {
          if (auto && (PULA_PASTA.has(nome) || (dir === raiz && nome === "dist"))) continue;
          if (!auto && (nome === ".git" || ((nome === "node_modules" || nome === "node_modules.nosync") && raiz.indexOf("/node_modules") < 0))) continue;
          if (auto && ignorado(atual, abs, true)) continue;
          visitar(abs, atual);
          continue;
        }
        if (!deveLer(nome)) continue;
        if (auto && ignorado(atual, abs, false)) continue;
        if (teste && !teste.test(path.relative(raiz, abs))) continue;
        if (negados.some((n) => n(abs))) continue;
        cada(abs);
      }
    };
    let st;
    try { st = fs.statSync(raiz); } catch (e) { return; }
    if (st.isDirectory()) visitar(raiz, []);
    else if (!negados.some((n) => n(raiz))) { pastas.add(path.dirname(raiz)); cada(raiz); }
  }

  // ---- compiladores ----
  // Um por arquivo CSS. Vale enquanto o CSS e tudo o que ele puxou (os `@import`, os
  // `@plugin`, o `@config`) tiverem a mesma data.
  const compiladores = new Map(); // css → { texto, deps: Map(arquivo → mt), c, vistos: Set }

  function mtimeDe(f) { try { return fs.statSync(f).mtimeMs; } catch (e) { return null; } }

  function aindaVale(g, conteudo) {
    if (!g || g.texto !== conteudo) return false;
    for (const [f, mt] of g.deps) if (mtimeDe(f) !== mt) return false;
    return true;
  }

  // `url(./fonte.woff2)` de um arquivo importado de outra pasta, visto da pasta do CSS de
  // entrada — é de lá que o esbuild vai resolver, depois que tudo virou um arquivo só.
  const URL_CSS = /url\(\s*(['"]?)([^'")]+)\1\s*\)/g;
  function reescreveUrls(css, deOnde, paraOnde) {
    if (deOnde === paraOnde || css.indexOf("url(") < 0) return css;
    return css.replace(URL_CSS, (tudo, aspas, u) => {
      if (/^(?:[a-z]+:|\/|#|data:|var\()/i.test(u.trim())) return tudo;
      let rel = path.relative(paraOnde, path.resolve(deOnde, u.trim()));
      if (!rel.startsWith(".")) rel = "./" + rel;
      return "url(" + aspas + rel + aspas + ")";
    });
  }

  function resolveEstilo(id, base, ctx) {
    if (id.startsWith("./") || id.startsWith("../") || id.startsWith("/")) {
      const abs = path.resolve(base, id);
      for (const c of [abs, abs + ".css", path.join(abs, "index.css")]) {
        try { if (fs.statSync(c).isFile()) return c; } catch (e) { /* tenta o próximo */ }
      }
      // `/src/x.css`: da raiz do projeto, como no Vite.
      if (id.startsWith("/") && ctx.root) return resolveEstilo("." + id, ctx.root, Object.assign({}, ctx, { root: null }));
      return null;
    }
    const alias = globalThis.__odeteAlias ? globalThis.__odeteAlias.aplica(ctx.root, id, ctx.vigiados) : null;
    if (alias) return resolveEstilo(alias, base, ctx);
    const r = H.resolveNavegador(id, path.join(base, "_.css"), "style");
    return typeof r === "string" ? r : null;
  }

  function resolveModulo(id, base) {
    if (id.startsWith("./") || id.startsWith("../") || id.startsWith("/")) {
      const abs = path.resolve(base, id);
      for (const e of ["", ".js", ".cjs", ".mjs", ".ts", ".mts", ".cts"]) {
        try { if (fs.statSync(abs + e).isFile()) return abs + e; } catch (err) { /* próximo */ }
      }
      return null;
    }
    const r = H.resolve(id, path.join(base, "_.js"));
    return typeof r === "string" ? r : null;
  }

  // `@plugin` e `@config`: JS, TS ou ESM, com o que eles importam, num CommonJS só feito
  // pelo esbuild — o `require` do motor não transforma TypeScript nem ESM. Os módulos do
  // Node ficam de fora e vêm do runtime.
  async function carregaModulo(arquivo, ctx, deps) {
    const r = await globalThis.__buildBruto({
      root: ctx.root, entries: [arquivo], format: "cjs", platform: "node", dev: true,
      outdir: "__odete_tailwind", metafile: true, pacoteFaltandoFora: true,
    });
    if (!r.ok) throw new Error((r.errors[0] && r.errors[0].text) || texto("tailwindModulo", arquivo));
    for (const f of r.entradas || []) if (f.indexOf("/node_modules/") < 0) deps.set(f, mtimeDe(f));
    const saida = r.saidas.find((s) => s.path.endsWith(".js"));
    const mod = { exports: {} };
    const fn = (0, eval)("(function (module, exports, require, __filename, __dirname) {" + saida.text + "\n})\n//# sourceURL=" + arquivo);
    fn(mod, mod.exports, globalThis.__odete_makeRequire(arquivo), arquivo, path.dirname(arquivo));
    const e = mod.exports;
    return e && e.__esModule && "default" in e ? e.default : e;
  }

  async function compilador(p, arquivo, conteudo, ctx) {
    const g = compiladores.get(arquivo);
    if (!ctx.novo && aindaVale(g, conteudo)) return g;
    const deps = new Map([[arquivo, mtimeDe(arquivo)]]);
    const dirCSS = path.dirname(arquivo);
    const t0 = Date.now();
    const c = await p.mod.compile(conteudo, {
      base: dirCSS, from: arquivo,
      loadStylesheet: async (id, base) => {
        const f = resolveEstilo(id, base, ctx);
        if (!f) throw new Error(texto("tailwindImport", id, path.relative(ctx.root, base) || "."));
        deps.set(f, mtimeDe(f));
        const dir = path.dirname(f);
        return { path: f, base: dir, content: reescreveUrls(fs.readFileSync(f, "utf8"), dir, dirCSS) };
      },
      loadModule: async (id, base) => {
        const f = resolveModulo(id, base);
        if (!f) throw new Error(texto("tailwindImport", id, path.relative(ctx.root, base) || "."));
        deps.set(f, mtimeDe(f));
        return { path: f, base: path.dirname(f), module: await carregaModulo(f, ctx, deps) };
      },
    });
    medicoes.compile = { arquivo, ms: Date.now() - t0 };
    const novo = { texto: conteudo, deps, c, vistos: new Set() };
    // Um build de produção é feito uma vez: não fica para o próximo.
    if (!ctx.novo) compiladores.set(arquivo, novo);
    return novo;
  }

  // Os candidatos que o compilador ainda não viu, de todos os arquivos das fontes.
  function candidatosNovos(g, ctx) {
    const { c } = g;
    const raizAuto = c.root === "none" ? null : c.root === null ? { base: ctx.root, pattern: "**/*" } : c.root;
    const negados = [];
    for (const s of c.sources || []) {
      if (!s.negated) continue;
      const { pasta, teste } = fonteDe(s.base, s.pattern);
      negados.push((abs) => teste ? abs.startsWith(pasta + "/") && teste.test(path.relative(pasta, abs)) : abs === pasta || abs.startsWith(pasta + "/"));
    }
    const novos = [];
    const lidos = new Set();
    const cada = (f) => {
      if (lidos.has(f)) return;
      lidos.add(f);
      const r = candidatosDoArquivo(f);
      if (!r) return;
      for (const x of r.lista) if (!g.vistos.has(x)) { g.vistos.add(x); novos.push(x); }
    };
    if (raizAuto) {
      const { pasta, teste } = fonteDe(raizAuto.base, raizAuto.pattern === "**/*" ? "." : raizAuto.pattern);
      anda(pasta, teste, true, negados, cada, ctx.pastas);
    }
    for (const s of c.sources || []) {
      if (s.negated) continue;
      const { pasta, teste } = fonteDe(s.base, s.pattern);
      anda(pasta, teste, false, negados, cada, ctx.pastas);
    }
    for (const f of lidos) ctx.vigiados.add(f);
    return novos;
  }

  // O CSS pronto de um arquivo com Tailwind. `ctx`: { root, vigiados (Set), pastas (Set),
  // novo (build de produção: compilador sem memória) }.
  async function processa(arquivo, conteudo, ctx) {
    const p = pacoteTailwind(path.dirname(arquivo));
    if (!p) return null;
    if (!p.v4) return await processaV3(p, arquivo, conteudo, ctx);
    const g = await compilador(p, arquivo, conteudo, ctx);
    for (const f of g.deps.keys()) ctx.vigiados.add(f);
    if (!(g.c.features & PRECISA_GERAR)) return conteudo;
    const t0 = Date.now();
    const novos = g.c.features & UTILITIES ? candidatosNovos(g, ctx) : [];
    const css = g.c.build(novos);
    medicoes.ultima = { arquivo, novos: novos.length, vistos: g.vistos.size, ms: Date.now() - t0 };
    return css;
  }

  // ---- Tailwind v3 ----
  // O v3 e o PostCSS num CommonJS só, feito pelo esbuild uma vez por versão: são centenas de
  // arquivos que se importam em roda, e um `eval` só custa menos, sem JIT, do que o
  // `require` do motor andando arquivo por arquivo.
  async function motorV3(p, ctx) {
    if (p.v3) return p.v3;
    const tw = H.resolve(p.dir, path.join(p.dir, "_.js"));
    const pc = H.resolve("postcss", path.join(p.dir, "_.js"));
    if (typeof pc !== "string") throw new Error(texto("tailwindV3SemPostcss"));
    const entrada = "__odete_tailwind3.js";
    const r = await globalThis.__buildBruto({
      root: ctx.root, entries: [entrada], format: "cjs", platform: "node", dev: true, outdir: "__odete_tailwind3", pacoteFaltandoFora: true,
      virtuais: { [entrada]: `module.exports = { tailwind: require(${JSON.stringify(path.resolve(tw))}), postcss: require(${JSON.stringify(path.resolve(pc))}) };\n` },
    });
    if (!r.ok) throw new Error((r.errors[0] && r.errors[0].text) || texto("tailwindModulo", "tailwindcss"));
    const saida = r.saidas.find((s) => s.path.endsWith(".js"));
    const mod = { exports: {} };
    const fn = (0, eval)("(function (module, exports, require, __filename, __dirname) {" + saida.text + "\n})\n//# sourceURL=tailwindcss-3.js");
    const arquivo = path.join(p.dir, "lib", "index.js");
    fn(mod, mod.exports, globalThis.__odete_makeRequire(arquivo), arquivo, path.dirname(arquivo));
    p.v3 = mod.exports;
    return p.v3;
  }

  // `postcss([tailwindcss(config)])`, com a config empacotada pelo esbuild (pode ser TS
  // ou ESM) e o `content` dela resolvido a partir da pasta da config — o v3 resolveria a
  // partir do diretório de trabalho, que aqui não é o do projeto.
  async function processaV3(p, arquivo, conteudo, ctx) {
    const { tailwind, postcss } = await motorV3(p, ctx);
    let config = {};
    for (const n of ["tailwind.config.js", "tailwind.config.cjs", "tailwind.config.mjs", "tailwind.config.ts", "tailwind.config.mts", "tailwind.config.cts"]) {
      const f = path.join(ctx.root, n);
      if (!fs.existsSync(f)) continue;
      const deps = new Map();
      config = await carregaModulo(f, ctx, deps);
      for (const d of deps.keys()) ctx.vigiados.add(d);
      ctx.vigiados.add(f);
      const base = path.dirname(f);
      const content = Array.isArray(config.content) ? config.content : config.content && config.content.files;
      if (Array.isArray(content)) {
        const absolutos = content.map((c) => typeof c === "string" ? (c.startsWith("!") ? "!" + path.resolve(base, c.slice(1)) : path.resolve(base, c)) : c);
        config = Object.assign({}, config, { content: Array.isArray(config.content) ? absolutos : Object.assign({}, config.content, { files: absolutos }) });
        // O v3 vigia os arquivos do `content` pelo sistema dele; aqui é o observador do
        // dev server que precisa saber deles.
        for (const c of absolutos) {
          if (typeof c !== "string" || c.startsWith("!")) continue;
          const { pasta, teste } = fonteDe("/", c);
          anda(pasta, teste, false, [], (f2) => ctx.vigiados.add(f2), ctx.pastas);
        }
      }
      break;
    }
    const r = await postcss([tailwind(config)]).process(conteudo, { from: arquivo });
    return r.css;
  }

  // O que mudou no disco: os candidatos e as listagens do arquivo vão embora (a data
  // cuidaria disso, mas o salvamento no mesmo milissegundo não mudaria a data).
  function esquece(caminhos) {
    for (const c of caminhos || []) { porArquivo.delete(c); listagens.delete(path.dirname(c)); listagens.delete(c); }
  }
  function esqueceTudo() { porArquivo.clear(); listagens.clear(); gitignores.clear(); compiladores.clear(); pacotes.clear(); }

  // O tempo do último `compile()` e da última geração (varredura + `build()`), para medir.
  const medicoes = { compile: null, ultima: null };

  globalThis.__odeteTailwind = { ehDoTailwind, processa, candidatosDe: (t) => [...candidatosDe(t, new Set())], esquece, esqueceTudo, medicoes, globParaRegex };
})();
