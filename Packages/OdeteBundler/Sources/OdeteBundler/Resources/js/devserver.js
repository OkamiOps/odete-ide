// Dev server: serve index.html, bundles do esbuild, estáticos e reload por WebSocket.
//
// Um motor de esbuild por projeto, e nele pode haver mais de um servidor (o `vite` e o
// `vite preview`, por exemplo). Por isso isto é uma fábrica: cada servidor tem o próprio
// estado, e o arquivo pode ser avaliado de novo sem derrubar quem já está no ar.
//
// O custo que importa aqui é o de um iPad sem JIT: JS interpretado e esbuild em wasm
// interpretado. Um build do zero de um projeto React pequeno passa de seis segundos de
// CPU, e o salvamento automático regrava o arquivo a cada pausa na digitação. Então:
//   - nada é refeito sem mudança de conteúdo num arquivo que o build leu (quem decide é o
//     observador do lado nativo, que compara conteúdo, e `mudou` aqui, que confere o grafo);
//   - o que é refeito usa o contexto incremental do esbuild;
//   - o navegador só recarrega se a saída mudou, e CSS sozinho troca sem recarregar.
globalThis.__devCria = function () {
  const http = require("http"), fs = require("fs"), path = require("path");
  const MIME = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp", ".ico": "image/x-icon", ".txt": "text/plain; charset=utf-8", ".map": "application/json", ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf", ".wasm": "application/wasm", ".md": "text/markdown; charset=utf-8" };
  // O cliente do Preview. "reload" recarrega; "css" troca só as folhas de estilo do
  // bundle, que é o que o `<link>` de `html()` aponta — sem esse link na página (Astro,
  // Next), não há o que trocar e a página recarrega. A folha nova entra antes de a velha
  // sair, para a tela não piscar sem estilo.
  const CLIENT = `<script>(function(){var p=location.protocol==="https:"?"wss":"ws";var s=new WebSocket(p+"://"+location.host+"/@odete/ws");function css(){var ls=document.querySelectorAll('link[rel="stylesheet"][href^="/@odete/css/"]');if(!ls.length){location.reload();return;}ls.forEach(function(l){var n=l.cloneNode();n.href=l.getAttribute("href").split("?")[0]+"?t="+Date.now();n.onload=function(){l.remove();};n.onerror=function(){location.reload();};l.parentNode.insertBefore(n,l.nextSibling);});}s.onmessage=function(e){if(e.data==="reload")location.reload();else if(e.data==="css")css();};s.onclose=function(){setTimeout(function(){location.reload()},1500)};})();</script>`;
  // Onde moram os pacotes. Em projeto do iCloud a pasta de verdade é `node_modules.nosync`
  // (o iCloud não sincroniza o que termina em .nosync) e `node_modules` é um atalho para
  // ela: as duas são tratadas igual — fora do grafo vigiado, e mexer nelas refaz tudo.
  const PASTAS_DE_PACOTES = ["node_modules", "node_modules.nosync"];
  const ehDePacote = (f) => PASTAS_DE_PACOTES.some((n) => f.indexOf("/" + n + "/") >= 0);
  const state = {
    id: 0, root: "", server: null, port: 0, diagnostics: [], preset: "plain", sockets: new Set(),
    // Um por entrada servida (`src/main.tsx`): o build mais recente e a assinatura do que saiu.
    entradas: new Map(),
    // Quem consome o quê: "b:<entrada>" (bundle), "next:<arquivo>", "ilhas:<rota>",
    // "astro:<arquivo>", "est:<arquivo>" (estático e index.html) → caminhos absolutos lidos.
    deps: new Map(),
    // Pastas onde um import que falhou procuraria o arquivo, por consumidor.
    faltando: new Map(),
    // Data de modificação vista ao ler (estáticos e .astro; os do esbuild vêm do bundler.js).
    mtimes: new Map(),
    // Versão do retrato (dependências + diagnósticos) e quem espera a próxima.
    versao: 0, esperas: [], retratoJSON: "",
    fila: Promise.resolve(), parado: false,
    // Contadores, para os testes provarem o que não aconteceu.
    stats: { builds: 0, reload: 0, css: 0 },
  };

  // ---- bundles ----
  function bundle(entryRel) {
    let e = state.entradas.get(entryRel);
    if (!e) {
      e = { ultimo: null };
      state.entradas.set(entryRel, e);
      e.ultimo = constroi(entryRel);
    }
    return e.ultimo;
  }

  // Um build de uma entrada. Incremental: o contexto do esbuild guarda a análise de quem
  // não mudou. A saída fica em bytes, do jeito que o esbuild entregou — não precisa virar
  // texto para ir ao navegador.
  async function constroi(entryRel) {
    const key = entryRel;
    state.stats.builds++;
    const r = await globalThis.__rebuild("dev" + state.id + ":" + entryRel, { root: state.root, entries: [entryRel], format: "esm", platform: "browser", dev: true, outdir: "__odete", externalMissing: true });
    state.diagnostics = state.diagnostics.filter((d) => d.entry !== key).concat(r.errors.map((e) => ({ ...e, kind: "error", entry: key })), r.warnings.map((w) => ({ ...w, kind: "warning", entry: key })));
    defineDeps("b:" + key, r.entradas || lidosNaFalha("b:" + key, path.resolve(state.root, entryRel), r.errors));
    defineFaltando("b:" + key, r.faltando);
    const js = r.saidas.find((f) => f.path.endsWith(".js")), css = r.saidas.find((f) => f.path.endsWith(".css"));
    const overlay = js ? null : errorOverlay(r.errors);
    anuncia();
    return {
      ok: r.ok,
      js: js ? js.contents : overlay, jsHash: js ? js.hash : "erro:" + overlay,
      css: css ? css.contents : "", cssHash: css ? css.hash : "",
    };
  }

  // Refaz uma entrada e diz o que mudou na saída, comparando os hashes que o próprio
  // esbuild calcula — igual é igual, e o navegador não precisa saber de nada.
  async function refaz(entryRel) {
    const e = state.entradas.get(entryRel);
    const antes = await e.ultimo.catch(() => null);
    e.ultimo = constroi(entryRel);
    const depois = await e.ultimo;
    return { js: !antes || antes.jsHash !== depois.jsHash, css: !antes || antes.cssHash !== depois.cssHash, ok: depois.ok };
  }

  // ---- dependências ----
  function iguais(a, b) {
    if (!a || a.size !== b.size) return false;
    for (const x of b) if (!a.has(x)) return false;
    return true;
  }

  function defineDeps(consumidor, lista) {
    const novo = new Set(lista);
    if (iguais(state.deps.get(consumidor), novo)) return;
    state.deps.set(consumidor, novo);
    // A memória de leituras é do motor, e o motor pode ter outro servidor: quem decide o
    // que continua guardado é a união dos grafos de todos.
    globalThis.__devGuardaVivos();
  }

  function vivos() {
    const todos = new Set();
    for (const s of state.deps.values()) for (const f of s) todos.add(f);
    return todos;
  }

  // Build que falha não tem metafile. O grafo fica o que era, mais a entrada e os
  // arquivos onde os erros apontam — senão o erro de sintaxe do primeiro build deixaria o
  // arquivo sem vigia, e consertá-lo não refaria nada.
  function lidosNaFalha(consumidor, entrada, erros) {
    const lidos = new Set(state.deps.get(consumidor) || []);
    lidos.add(entrada);
    for (const e of erros || []) if (e.file && !/^[a-z][a-z0-9-]*:/i.test(e.file)) lidos.add(path.resolve(state.root, e.file));
    return [...lidos];
  }

  function defineFaltando(consumidor, lista) {
    if (lista && lista.length) state.faltando.set(consumidor, new Set(lista));
    else state.faltando.delete(consumidor);
  }

  function registraLido(consumidor, arquivo) {
    try { state.mtimes.set(arquivo, fs.statSync(arquivo).mtimeMs); } catch (e) { /* sumiu entre servir e anotar */ }
    const atual = state.deps.get(consumidor);
    if (atual && atual.size === 1 && atual.has(arquivo)) return;
    state.deps.set(consumidor, new Set([arquivo]));
    anuncia();
  }

  // O que o observador nativo precisa vigiar: tudo o que foi lido fora de node_modules,
  // mais o que muda o build inteiro (package.json, .env). node_modules é olhado só pela
  // pasta de cima — instalar ou remover pacote mexe nela.
  function retrato() {
    const arquivos = new Map();
    for (const s of state.deps.values()) {
      for (const f of s) {
        if (ehDePacote(f) || arquivos.has(f)) continue;
        const m = state.mtimes.has(f) ? state.mtimes.get(f) : globalThis.__mtimeLido(f);
        arquivos.set(f, m);
      }
    }
    for (const n of ["package.json", ".env", ".env.local", ".env.development"]) {
      const f = path.join(state.root, n);
      if (!arquivos.has(f)) arquivos.set(f, null);
    }
    const pastas = new Set([state.root, ...PASTAS_DE_PACOTES.map((n) => path.join(state.root, n))]);
    for (const s of state.faltando.values()) for (const d of s) pastas.add(d);
    return { versao: state.versao, arquivos: [...arquivos].map(([f, m]) => [f, m]), pastas: [...pastas], diagnostics: state.diagnostics };
  }

  // Acorda quem espera o próximo retrato — mas só se ele mudou. Servir o mesmo estático
  // cem vezes não pode virar cem idas e voltas ao nativo.
  function anuncia() {
    const r = retrato();
    const json = JSON.stringify([r.arquivos, r.pastas, r.diagnostics]);
    if (json === state.retratoJSON) return;
    state.retratoJSON = json;
    state.versao++;
    r.versao = state.versao;
    const w = state.esperas;
    state.esperas = [];
    for (const f of w) f(r);
  }

  // Espera longa: o nativo pergunta "o que há depois da versão N?" e a resposta só vem
  // quando houver algo. Sem relógio e sem ida e volta à toa.
  function espera(versao) {
    if (state.parado) return Promise.resolve(null);
    if (state.versao !== versao) return Promise.resolve(retrato());
    return new Promise((resolve) => state.esperas.push(resolve));
  }

  // ---- mudanças ----
  const ehAmbiente = (f) =>
    PASTAS_DE_PACOTES.some((n) => f === path.join(state.root, n) || f.startsWith(path.join(state.root, n) + "/")) ||
    (path.dirname(f) === state.root && (/^package(-lock)?\.json$/.test(path.basename(f)) || path.basename(f).startsWith(".env")));

  const tronco = (f) => path.join(path.dirname(f), path.basename(f, path.extname(f)));

  // O observador nativo já filtrou regravação com o mesmo conteúdo; o que chega aqui
  // mudou de verdade. Falta saber se importa: só o que está no grafo de alguém importa,
  // e arquivo novo só quando um import quebrado pode passar a achar ele (ou quando ele
  // tem o mesmo nome de um que já era lido, com outra extensão — a resolução pode mudar).
  function mudou(alterados, criados) {
    const vez = state.fila.then(() => processaMudanca(alterados, criados));
    state.fila = vez.catch(() => {});
    return vez;
  }

  async function processaMudanca(alterados, criados) {
    if (state.parado) return { acao: "nada", refeitos: 0 };
    if (alterados.concat(criados).some(ehAmbiente)) { await invalida(); return { acao: "reload", refeitos: 0, tudo: true }; }
    const afetados = new Set();
    // Resolução de import só muda se sumiu um arquivo que alguém lia, ou se nasceu um com
    // o mesmo nome e outra extensão (`App.tsx` ao lado do `App.jsx` que era lido).
    let estrutura = false;
    for (const f of alterados) {
      for (const [c, s] of state.deps) {
        if (!s.has(f)) continue;
        afetados.add(c);
        if (!fs.existsSync(f)) estrutura = true;
      }
    }
    if (criados.length) {
      const troncos = new Set(criados.map(tronco));
      const pastasNovas = new Set(criados.map((f) => path.dirname(f)));
      for (const [c, s] of state.faltando) for (const d of s) if (pastasNovas.has(d)) afetados.add(c);
      for (const [c, s] of state.deps) for (const f of s) if (troncos.has(tronco(f))) { afetados.add(c); estrutura = true; }
      for (const [k, e] of state.entradas) {
        const r = await e.ultimo.catch(() => null);
        if (r && !r.ok) afetados.add("b:" + k);
      }
    }
    globalThis.__esqueceArquivos(alterados, estrutura);
    if (!afetados.size) return { acao: "nada", refeitos: 0 };
    let recarrega = false, estilo = false, refeitos = 0;
    for (const c of afetados) {
      if (c.startsWith("b:")) {
        if (!state.entradas.has(c.slice(2))) continue;
        const d = await refaz(c.slice(2));
        refeitos++;
        if (d.js) recarrega = true; else if (d.css) estilo = true;
      } else {
        // Página do Next, ilhas, .astro, estático: a saída deles só existe no próximo
        // pedido, então o navegador pede de novo. O cache da página vai embora aqui — a
        // data do arquivo da página não muda quando é o componente importado que muda.
        if (c.startsWith("next:")) pacoteNext.delete(c.slice(5));
        if (c.startsWith("astro:")) modAstro.clear();
        recarrega = true;
      }
    }
    const acao = recarrega ? "reload" : estilo ? "css" : "nada";
    avisa(acao);
    return { acao, refeitos };
  }

  function avisa(acao) {
    if (acao === "nada") return;
    state.stats[acao]++;
    for (const s of state.sockets) s.send(acao);
  }

  // Tudo do zero: package.json, .env ou node_modules mudaram, ou alguém pediu Rebuild.
  // Os defines do .env entram nas opções do contexto, então os contextos vão embora.
  async function invalida() {
    state.entradas.clear();
    pacoteNext.clear();
    modAstro.clear();
    ctxNext = null;
    for (const k of [...state.deps.keys()]) if (!k.startsWith("est:")) state.deps.delete(k);
    state.faltando.clear();
    globalThis.__esqueceTudo();
    await globalThis.__descartaContextos("dev" + state.id + ":");
    anuncia();
    avisa("reload");
    return state.sockets.size;
  }

  function errorOverlay(errors) {
    const msg = errors.map((e) => `${e.file ? e.file + ":" + e.line + ": " : ""}${e.text}`).join("\\n");
    return `console.error(${JSON.stringify(msg)}); document.body.innerHTML = '<pre style="white-space:pre-wrap;padding:16px;color:#e25d5d;background:#111;font:13px ui-monospace,monospace;margin:0;min-height:100vh">' + ${JSON.stringify(msg.replace(/</g, "&lt;"))} + '</pre>';`;
  }

  // Pacotes do package.json que não têm pasta em node_modules vão para o esm.sh.
  // Sem isto o navegador recebe `import "react"` cru e responde
  // "Module name, 'react' does not resolve to a valid URL".
  function importMap() {
    try {
      const arq = path.join(state.root, "package.json");
      if (!fs.existsSync(arq)) return "";
      const pkg = JSON.parse(fs.readFileSync(arq, "utf8"));
      const deps = Object.assign({}, pkg.dependencies || {}, pkg.devDependencies || {});
      const faltando = {};
      for (const nome of Object.keys(deps)) {
        if (fs.existsSync(path.join(state.root, "node_modules", nome, "package.json"))) continue;
        faltando[nome] = String(deps[nome]).replace(/^[\^~=v\s]+/, "") || "latest";
      }
      const nomes = Object.keys(faltando);
      if (!nomes.length) return "";
      // Tudo que depende de react precisa apontar para a mesma cópia, senão o esm.sh
      // entrega duas e os hooks quebram.
      const react = faltando.react ? `react@${faltando.react}` : "";
      const imports = {};
      for (const nome of nomes) {
        const base = `https://esm.sh/${nome}@${faltando[nome]}`;
        const extra = react && nome !== "react" ? `&deps=${react}` : "";
        imports[nome] = `${base}?dev${extra}`;
        imports[nome + "/"] = `${base}/`;
      }
      return `<script type="importmap">${JSON.stringify({ imports })}</script>`;
    } catch (e) {
      return "";
    }
  }

  function html(file) {
    let src = fs.readFileSync(file, "utf8");
    // <script type="module" src="/src/main.tsx"> → bundle + css
    const entries = [];
    src = src.replace(/<script\s+type="module"\s+src="([^"]+)"\s*><\/script>/g, (m, s) => {
      const rel = s.replace(/^\//, "");
      entries.push(rel);
      return `<link rel="stylesheet" href="/@odete/css/${rel}"><script type="module" src="/@odete/js/${rel}"></script>`;
    });
    const head = importMap() + CLIENT;
    src = src.includes("</head>") ? src.replace("</head>", head + "</head>") : head + src;
    return src;
  }

  // Um 404 seco não diz nada a quem acabou de subir o servidor e vê a tela em branco.
  // A Odete serve estáticos e bundles; ela ainda não compila páginas de framework, e o
  // caso mais comum de bater aqui é justamente um projeto Astro ou Next, onde a rota
  // mora em src/pages ou app/ em vez de um arquivo na raiz.
  function recado404(p) {
    const tem = (r) => { try { return fs.existsSync(path.join(state.root, r)); } catch (e) { return false; } };
    let extra = "";
    if (state.preset === "astro" || tem("src/pages")) {
      extra = "\n\nEste é um projeto Astro: a rota " + p + " sai de src/pages" +
        (p === "/" ? "/index.astro" : p + ".astro") + ", e esse arquivo não existe.";
    } else if (state.preset === "next" || tem("app") || tem("pages")) {
      extra = "\n\nEste é um projeto Next: a rota " + p + " sai de app" +
        (p === "/" ? "/page" : p + "/page") + " ou de pages" + (p === "/" ? "/index" : p) +
        " (.tsx, .jsx, .ts ou .js), e nenhum desses arquivos existe.";
    } else if (!tem("index.html")) {
      extra = "\n\nNão há index.html na raiz nem em public/. O Preview serve os arquivos do projeto;" +
        "\ncrie um index.html para ter uma página.";
    }
    return "não encontrado: " + p + extra;
  }

  // ---- páginas do Next ----
  // O `require` do runtime resolve node_modules e transpila TSX, então a página do
  // projeto e o React dele são carregados direto, a partir da raiz do projeto.
  let ctxNext = null;
  function contextoNext() {
    if (ctxNext) return ctxNext;
    const req = globalThis.__odete_makeRequire(path.join(state.root, "__odete_next__.js"));
    const React = req("react");
    const servidor = req("react-dom/server");
    ctxNext = { React, servidor, req, carrega: carregaNext };
    return ctxNext;
  }

  // Cada página vira um pacote CJS só, com React e `next/*` de fora.
  //
  // Transpilar arquivo a arquivo não fecha: `__transformCJS` é assíncrono e o `require`
  // dentro do módulo é síncrono. Empacotando, tudo o que é relativo já entra junto e o
  // `__req` só precisa atender o que ficou de fora — e é aí que o React continua sendo
  // um só, o do servidor, senão hook e contexto quebram com duas cópias.
  const pacoteNext = new Map();
  // Mapa da rota para os módulos de cliente que ela usa, preenchido no render e lido
  // quando o navegador pede o pacote de hidratação.
  const ilhasDaRota = new Map();
  const ilhasDoBuild = {};
  async function carregaNext(arquivo) {
    const mt = fs.statSync(arquivo).mtimeMs;
    const cache = pacoteNext.get(arquivo);
    if (cache && cache.mt === mt) return cache.exports;
    const r = await globalThis.__buildBruto({
      root: state.root, entries: [path.relative(state.root, arquivo)],
      format: "cjs", platform: "node", dev: true, outdir: "__odete_next",
      external: ["react", "react-dom", "react/jsx-runtime", "react/jsx-dev-runtime", "next/*"],
      ilhas: ilhasDoBuild, acoes: "servidor", metafile: true,
    });
    // O que a página importa entra no grafo: mexer num componente dela tem de derrubar o
    // cache da página, e a data do arquivo da página não muda quando é o componente.
    defineDeps("next:" + arquivo, r.entradas || lidosNaFalha("next:" + arquivo, arquivo, r.errors));
    defineFaltando("next:" + arquivo, r.faltando);
    anuncia();
    if (!r.ok) throw new Error((r.errors[0] && r.errors[0].text) || "build da página falhou");
    const saida = r.saidas.find((f) => f.path.endsWith(".js"));
    if (!saida) throw new Error("build da página não produziu JS");
    const mod = { exports: {} };
    const ctx = contextoNext();
    const req = (spec) => {
      if (spec.startsWith("next/")) return substitutoNext(spec, ctx.React);
      return ctx.req(spec);
    };
    const fn = (0, eval)("(function (module, exports, require) {" + saida.text + "\n})\n//# sourceURL=" + arquivo);
    fn(mod, mod.exports, req);
    pacoteNext.set(arquivo, { mt, exports: mod.exports });
    return mod.exports;
  }

  // O pacote que o navegador baixa para hidratar: só os componentes de cliente daquela
  // rota, não a página inteira. O servidor já mandou o HTML pronto.
  async function pacoteDeIlhas(rota) {
    const ids = ilhasDaRota.get(rota) || [];
    if (!ids.length) return "// sem ilhas nesta rota";
    const entradas = ids.map((id) => {
      const [modulo, exportado] = id.split("#");
      const abs = path.join(state.root, modulo);
      const nome = exportado === "default" ? "default" : exportado;
      return { id, abs, nome };
    });
    const importa = entradas.map((e, i) =>
      `import { ${e.nome} as __c${i} } from ${JSON.stringify("odete-real:" + e.abs)};`).join("\n");
    const mapa = entradas.map((e, i) => `  ${JSON.stringify(e.id)}: __c${i},`).join("\n");
    const virtual = `${importa}\nexport const MODULOS = {\n${mapa}\n};\n`;
    const r = await globalThis.__buildBruto({
      root: state.root, entries: ["__odete_ilhas_entrada.js"], format: "esm", platform: "browser",
      dev: true, outdir: "__odete_ilhas", externalMissing: true, acoes: "cliente", metafile: true,
      virtuais: {
        "__odete_ilhas_entrada.js": globalThis.__ilhasClienteJS,
        "virtual:odete-ilhas": virtual,
      },
    });
    if (r.entradas) { defineDeps("ilhas:" + rota, r.entradas); anuncia(); }
    if (!r.ok) throw new Error((r.errors[0] && r.errors[0].text) || "build das ilhas falhou");
    const saida = r.saidas.find((f) => f.path.endsWith(".js"));
    return saida ? saida.contents : "// build das ilhas não produziu JS";
  }

  // `next/link` e `next/image` existem para o roteador e o otimizador do Next, que aqui
  // não existem: viram a marcação que eles produziriam.
  function substitutoNext(spec, React) {
    const nome = spec.slice("next/".length);
    if (nome === "server") return globalThis.__next.moduloNextServer();
    if (nome === "navigation") return globalThis.__next.moduloNavegacao();
    if (nome === "cache") return globalThis.__next.moduloCache();
    if (nome === "font/google") return globalThis.__next.moduloFonteGoogle();
    if (nome === "font/local") return globalThis.__next.moduloFonteLocal();
    if (nome === "link") {
      const Link = (props) => {
        const { href, children, prefetch, replace, scroll, shallow, locale, ...resto } = props || {};
        return React.createElement("a", Object.assign({ href: typeof href === "string" ? href : "#" }, resto), children);
      };
      return { __esModule: true, default: Link };
    }
    if (nome === "image") {
      const Img = (props) => {
        const { src, alt, width, height, priority, quality, fill, loader, placeholder, ...resto } = props || {};
        return React.createElement("img", Object.assign({
          src: typeof src === "object" && src ? src.src : src, alt: alt || "", width, height,
        }, resto));
      };
      return { __esModule: true, default: Img };
    }
    if (nome === "head") {
      const Head = (props) => React.createElement(React.Fragment, null, props && props.children);
      return { __esModule: true, default: Head };
    }
    throw new Error("Odete ainda não tem substituto para " + spec);
  }

  // `localFont({ src: "./Inter.woff2" })` é relativo ao arquivo que chamou, e depois de
  // empacotar não existe mais "arquivo que chamou". Então procura-se: os lugares óbvios
  // primeiro, e só então o arquivo pelo nome, dentro do projeto e fora de node_modules.
  function achaArquivoDeFonte(spec) {
    const limpo = String(spec).replace(/^\.\//, "").replace(/^\/+/, "");
    const diretos = ["", "public", "app", "src", "src/app", "styles", "fonts", "assets"];
    for (const d of diretos) {
      const f = path.join(state.root, d, limpo);
      if (f.startsWith(state.root) && fs.existsSync(f) && fs.statSync(f).isFile()) return f;
    }
    const alvo = limpo.split("/").pop();
    const fila = [state.root];
    for (let n = 0; fila.length && n < 4000; n++) {
      const dir = fila.shift();
      let itens = [];
      try { itens = fs.readdirSync(dir); } catch (e) { continue; }
      for (const item of itens) {
        if (PASTAS_DE_PACOTES.includes(item) || item[0] === ".") continue;
        const f = path.join(dir, item);
        let st;
        try { st = fs.statSync(f); } catch (e) { continue; }
        if (st.isDirectory()) fila.push(f);
        else if (item === alvo) return f;
      }
    }
    return null;
  }

  // A URL pela qual o navegador pega a fonte: os estáticos saem de public/ e da raiz,
  // então basta o caminho relativo — sem o "public/" quando ela mora lá.
  globalThis.__odeteArquivoDeFonte = (spec) => {
    const f = achaArquivoDeFonte(spec);
    if (!f) return null;
    let rel = path.relative(state.root, f);
    if (rel.startsWith("public/")) rel = rel.slice("public/".length);
    return "/" + rel.split(path.sep).join("/");
  };

  // ---- middleware ----
  // Roda antes de qualquer rota: pode responder, redirecionar, reescrever o caminho ou
  // só deixar passar (acrescentando cabeçalhos ao que vier depois).
  function ehProjetoNext() {
    if (state.preset === "next") return true;
    for (const d of ["app", "pages"]) {
      try { if (fs.statSync(path.join(state.root, d)).isDirectory()) return true; } catch (e) { /* segue */ }
    }
    return false;
  }

  // Só em projeto Next: um `src/middleware.ts` num projeto Vite é código da pessoa, não
  // um gancho do servidor, e rodá-lo em toda requisição seria surpresa ruim.
  function arquivoMiddleware() {
    if (!ehProjetoNext()) return null;
    for (const base of [state.root, path.join(state.root, "src")]) {
      for (const e of [".ts", ".tsx", ".js", ".mjs"]) {
        const f = path.join(base, "middleware" + e);
        try { if (fs.existsSync(f) && fs.statSync(f).isFile()) return f; } catch (err) { /* segue */ }
      }
    }
    return null;
  }

  async function rodaMiddleware(arquivo, req, url) {
    const mod = await carregaNext(arquivo);
    const fn = mod.middleware || mod.default;
    if (typeof fn !== "function") return null;
    if (!globalThis.__next.casaMatcher(mod.config, url.pathname)) return null;
    const host = (req.headers && req.headers.host) || "localhost:" + state.port;
    const pedido = globalThis.__next.pedidoNext("http://" + host + req.url, req.method, req.headers || {});
    return globalThis.__next.leResposta(await fn(pedido));
  }

  function enviaDoMiddleware(res, r) {
    const h = { "cache-control": "no-store" };
    for (const [k, v] of r.cabecalhos) h[k] = v;
    if (r.biscoitos.length) h["set-cookie"] = r.biscoitos;
    if (r.corpo != null && !h["content-type"]) h["content-type"] = "text/plain; charset=utf-8";
    res.writeHead(r.status, h);
    res.end(r.corpo == null ? "" : r.corpo);
  }

  // ---- Server Actions ----
  // O corpo só pode ser lido uma vez: o fluxo termina e a segunda leitura esperaria
  // para sempre por um "end" que já passou. Quem pedir de novo recebe o mesmo texto.
  function corpoDoPedido(req) {
    if (req.__odeteCorpo) return req.__odeteCorpo;
    req.__odeteCorpo = new Promise((resolve) => {
      const partes = [];
      req.on("data", (c) => partes.push(Buffer.from(c)));
      req.on("end", () => resolve(Buffer.concat(partes).toString("utf8")));
      req.on("error", () => resolve(""));
      req.resume();
    });
    return req.__odeteCorpo;
  }

  // O formulário chega urlencoded, e o `<input type="file">` não atravessa isso. Quem
  // precisa de arquivo hoje usa fetch da ilha, que vai em JSON.
  function camposDoCorpo(texto) {
    const mapa = new Map();
    for (const parte of String(texto).split("&")) {
      if (!parte) continue;
      const i = parte.indexOf("=");
      const k = decodeURIComponent((i < 0 ? parte : parte.slice(0, i)).replace(/\+/g, " "));
      const v = i < 0 ? "" : decodeURIComponent(parte.slice(i + 1).replace(/\+/g, " "));
      if (mapa.has(k)) mapa.get(k).push(v); else mapa.set(k, [v]);
    }
    return camposDeMapa(mapa);
  }

  function camposDeMapa(mapa) {
    return {
      get: (k) => (mapa.has(k) ? mapa.get(k)[0] : null),
      getAll: (k) => (mapa.get(k) || []).slice(),
      has: (k) => mapa.has(k),
      forEach: (f, t) => { for (const [k, vs] of mapa) for (const v of vs) f.call(t, v, k); },
      entries: function* () { for (const [k, vs] of mapa) for (const v of vs) yield [k, v]; },
      keys: () => mapa.keys(),
      append: () => {},
      set: () => {},
      delete: () => {},
    };
  }

  // FormData não atravessa JSON: a ilha manda os pares e aqui vira de novo algo que a
  // ação lê com `.get(...)`, que é como toda Server Action recebe um formulário.
  function argumentoDaIlha(v) {
    if (!v || typeof v !== "object" || !Array.isArray(v.__odeteFormData)) return v;
    const mapa = new Map();
    for (const [k, x] of v.__odeteFormData) {
      if (mapa.has(k)) mapa.get(k).push(String(x)); else mapa.set(k, [String(x)]);
    }
    return camposDeMapa(mapa);
  }

  // A ação pode estar num módulo que esta execução ainda não carregou (o navegador
  // guardou a página e o servidor reiniciou). O id diz o arquivo: carrega e procura.
  async function achaAcao(id) {
    let fn = globalThis.__next.acaoPorId(id);
    if (fn) return fn;
    const arquivo = path.join(state.root, id.split("#")[0]);
    if (!arquivo.startsWith(state.root) || !fs.existsSync(arquivo)) return null;
    await carregaNext(arquivo);
    return globalThis.__next.acaoPorId(id);
  }

  async function rodaAcao(id, args) {
    const fn = await achaAcao(id);
    if (!fn) return { erro: "ação desconhecida: " + id };
    try {
      return { valor: await fn.apply(null, args) };
    } catch (e) {
      const nav = globalThis.__next.leErroDeNavegacao(e);
      if (nav && nav.acao === "redireciona") return { redireciona: nav.destino, status: nav.status };
      if (nav) return { naoachou: true };
      return { erro: String((e && e.message) || e) };
    }
  }

  // Monta o documento de uma rota do Next: corpo renderizado, metadata, fontes e o
  // script das ilhas quando a rota tem alguma.
  async function paginaNext(rotaNext, p, url) {
    const usadas = new Set();
    globalThis.__next.instalaIlhas(contextoNext().React, usadas);
    const { corpo, cabeca } = await globalThis.__next.renderiza(contextoNext(), rotaNext, url);
    ilhasDaRota.set(p, [...usadas]);
    const hidrata = usadas.size
      ? '<script type="module" src="/@odete/ilhas' + encodeURI(p) + '"></script>'
      : "";
    return "<!doctype html><html><head>" + cabeca + importMap() +
      globalThis.__next.cabecalhoDeFontes() + CLIENT +
      "</head><body>" + corpo + hidrata + "</body></html>";
  }

  // `not-found.tsx` e `error.tsx` são páginas do projeto: se existirem, é o que a
  // pessoa quer ver. Se não, sobra o recado da Odete, que pelo menos diz o que faltou.
  async function enviaEspecial(res, p, url, nome, status, extras, erro) {
    const alvo = globalThis.__next.especial(fs, path, state.root, p, nome);
    if (alvo) {
      try {
        if (erro) alvo.props = { error: erro, reset: () => {} };
        return send(res, status, MIME[".html"], await paginaNext(alvo, p, url), extras);
      } catch (e) { /* a página de erro também falhou: cai no recado */ }
    }
    const texto = nome === "not-found"
      ? recado404(p)
      : String((erro && erro.message) || erro || "erro") + "\n\n" + String((erro && erro.stack) || "");
    return send(res, status, "text/plain; charset=utf-8", texto, extras);
  }

  function faltaReact(e) {
    return /Cannot find module '(react|react-dom)/.test(String(e && e.message));
  }

  // ---- páginas .astro ----
  // Carrega um .astro como módulo, compilando na hora e resolvendo os imports dele —
  // inclusive outros .astro, que são componentes e layouts. Cache por mtime, para
  // editar um componente refletir sem reiniciar o servidor.
  const modAstro = new Map();
  function carregaAstro(arquivo) {
    const mt = fs.statSync(arquivo).mtimeMs;
    registraLido("astro:" + arquivo, arquivo);
    const cache = modAstro.get(arquivo);
    if (cache && cache.mt === mt) return cache.exports;
    const js = globalThis.__astroCompila(fs.readFileSync(arquivo, "utf8"), arquivo);
    const mod = { exports: {} };
    const daPasta = path.dirname(arquivo);
    const req = (spec) => {
      const alvo = spec.startsWith(".") ? path.resolve(daPasta, spec) : spec;
      if (typeof alvo === "string" && alvo.endsWith(".astro")) return carregaAstro(alvo);
      // CSS e afins importados só por efeito não existem no servidor.
      if (/\.(css|scss|sass|less|svg|png|jpe?g|webp|gif)$/i.test(spec)) return {};
      return require(alvo);
    };
    const fn = (0, eval)("(function (module, __req, __astroRuntime) {" + js + "\n})\n//# sourceURL=" + arquivo);
    fn(mod, req, globalThis.__astroRuntime);
    modAstro.set(arquivo, { mt, exports: mod.exports });
    return mod.exports;
  }

  // A rota vem do nome do arquivo: / → src/pages/index.astro, /a → src/pages/a.astro
  // ou src/pages/a/index.astro.
  function paginaAstro(p) {
    const base = path.join(state.root, "src", "pages");
    if (!fs.existsSync(base)) return null;
    const rel = p.replace(/^\/+|\/+$/g, "");
    const nomes = rel === "" ? ["index.astro"] : [rel + ".astro", path.join(rel, "index.astro")];
    for (const n of nomes) {
      const f = path.join(base, n);
      if (!f.startsWith(base)) continue;
      if (fs.existsSync(f) && fs.statSync(f).isFile()) return f;
    }
    return null;
  }

  async function renderizaAstro(arquivo) {
    const mod = carregaAstro(arquivo);
    if (typeof mod.render !== "function") throw new Error(arquivo + " não exporta uma página");
    const html = await mod.render({ props: {}, url: new URL("http://localhost/") }, {});
    const head = importMap() + CLIENT;
    return html.includes("</head>") ? html.replace("</head>", head + "</head>") : head + html;
  }

  function send(res, status, type, body, extras) {
    const h = { "content-type": type, "cache-control": "no-store", "access-control-allow-origin": "*" };
    if (extras) for (const [k, v] of extras) h[k] = v;
    res.writeHead(status, h);
    res.end(body);
  }

  async function handle(req, res) {
    let url = new URL(req.url, "http://x");
    let p = decodeURIComponent(url.pathname);
    try {
      if (p.startsWith("/@odete/js/")) { const b = await bundle(p.slice(11)); return send(res, 200, MIME[".js"], b.js); }
      if (p.startsWith("/@odete/css/")) { const b = await bundle(p.slice(12)); return send(res, 200, MIME[".css"], b.css); }
      if (p === "/@odete/diag") return send(res, 200, "application/json", JSON.stringify(state.diagnostics));

      // O middleware vem antes de tudo que é do projeto — e depois do que é da Odete,
      // porque recarregar a página não pode depender de passar pelo middleware.
      let extras = null;
      const mw = globalThis.__next && !p.startsWith("/@odete/") && arquivoMiddleware();
      if (mw) {
        const r = await rodaMiddleware(mw, req, url);
        if (r && (r.acao === "resposta" || r.acao === "redireciona")) return enviaDoMiddleware(res, r);
        if (r && r.acao === "reescreve" && r.destino) {
          url = new URL(r.destino, "http://x");
          p = decodeURIComponent(url.pathname);
        }
        if (r) {
          extras = r.cabecalhos.filter(([k]) => k !== "location");
          for (const c of r.biscoitos) extras.push(["set-cookie", c]);
          if (!extras.length) extras = null;
        }
      }

      // estáticos: public/ primeiro, depois raiz
      for (const base of [path.join(state.root, "public"), state.root]) {
        let f = path.join(base, p);
        if (!f.startsWith(base)) continue;
        if (fs.existsSync(f) && fs.statSync(f).isDirectory()) f = path.join(f, "index.html");
        if (!fs.existsSync(f)) continue;
        const ext = path.extname(f).toLowerCase();
        if ([".ts", ".tsx", ".jsx", ".mts"].includes(ext)) { const b = await bundle(path.relative(state.root, f)); return send(res, 200, MIME[".js"], b.js, extras); }
        // O que foi servido entra no grafo: mudar o index.html ou uma imagem de public/
        // que a página mostra tem de recarregar; mudar o que ninguém pediu, não.
        registraLido("est:" + f, f);
        if (ext === ".html") return send(res, 200, MIME[".html"], html(f), extras);
        return send(res, 200, MIME[ext] || "application/octet-stream", fs.readFileSync(f), extras);
      }
      // páginas de framework, antes do fallback: nem Astro nem Next têm index.html
      const pagina = paginaAstro(p);
      if (pagina) return send(res, 200, MIME[".html"], await renderizaAstro(pagina), extras);
      if (p.startsWith("/@odete/ilhas/")) {
        const rota = decodeURIComponent(p.slice("/@odete/ilhas".length)) || "/";
        const js = await pacoteDeIlhas(rota);
        return send(res, 200, MIME[".js"], js);
      }
      // A ilha chama a ação pela rede, em JSON, e recebe o valor de volta.
      if (p.startsWith("/@odete/acao/") && req.method === "POST") {
        const id = decodeURIComponent(p.slice("/@odete/acao/".length));
        let args = [];
        try { args = JSON.parse(await corpoDoPedido(req)) || []; } catch (e) { args = []; }
        const r = await rodaAcao(id, (Array.isArray(args) ? args : [args]).map(argumentoDaIlha));
        return send(res, r.erro ? 500 : 200, "application/json", JSON.stringify(r));
      }

      const rotaNext = globalThis.__next && globalThis.__next.rota(fs, path, state.root, p);
      if (rotaNext) {
        try {
          globalThis.__next.instalaAcoes();
          globalThis.__next.rotaDasAcoes(p);

          // Route Handler não é página: devolve o que a função devolveu.
          if (rotaNext.tipo === "handler") {
            const host = (req.headers && req.headers.host) || "localhost:" + state.port;
            const pedido = globalThis.__next.pedidoNext(
              "http://" + host + req.url, req.method, req.headers || {}
            );
            pedido.text = async () => await corpoDoPedido(req);
            pedido.json = async () => JSON.parse(await pedido.text());
            pedido.formData = async () => camposDoCorpo(await pedido.text());
            const r = await globalThis.__next.rodaHandler(contextoNext(), rotaNext, pedido);
            const cab = (extras || []).concat(r.cabecalhos);
            if (!r.cabecalhos.some(([k]) => k === "content-type")) {
              cab.push(["content-type", "application/json; charset=utf-8"]);
            }
            res.writeHead(r.status, Object.fromEntries(
              cab.concat([["cache-control", "no-store"]]).map(([k, v]) => [k, v])
            ));
            return res.end(r.corpo);
          }


          // `<form action={acaoDeServidor}>` posta para a própria rota, com a
          // identidade da ação num campo oculto que o React escreveu no render. Roda a
          // ação antes e devolve a página já com o efeito dela.
          if (req.method === "POST") {
            const campos = camposDoCorpo(await corpoDoPedido(req));
            const id = campos.get(globalThis.__next.CAMPO);
            if (id) {
              let ligados = [];
              const bruto = campos.get(globalThis.__next.CAMPO_LIGADOS);
              if (bruto) { try { ligados = JSON.parse(bruto) || []; } catch (e) { ligados = []; } }
              const r = await rodaAcao(id, ligados.concat([campos]));
              // 303 e não o 307 do `redirect()`: 307 e 308 preservam o método, e o
              // navegador postaria o mesmo formulário no destino — a ação rodaria de
              // novo, em laço. Depois de um POST o que se quer é um GET no destino.
              if (r.redireciona) {
                return send(res, 303, "text/plain; charset=utf-8", "",
                  (extras || []).concat([["location", r.redireciona]]));
              }
              if (r.naoachou) return await enviaEspecial(res, p, url, "not-found", 404, extras, null);
              if (r.erro) return send(res, 500, "text/plain; charset=utf-8", r.erro, extras);
            }
          }

          return send(res, 200, MIME[".html"], await paginaNext(rotaNext, p, url), extras);
        } catch (e) {
          // `redirect()` e `notFound()` do Next chegam aqui lançados, de dentro do render.
          const nav = globalThis.__next.leErroDeNavegacao(e);
          if (nav && nav.acao === "redireciona") {
            return send(res, nav.status, "text/plain; charset=utf-8", "",
              (extras || []).concat([["location", nav.destino]]));
          }
          if (nav) return await enviaEspecial(res, p, url, "not-found", 404, extras, e);
          if (faltaReact(e)) {
            return send(res, 500, "text/plain; charset=utf-8",
              "O projeto é Next mas react e react-dom não estão instalados.\nRode npm install no terminal.");
          }
          return await enviaEspecial(res, p, url, "error", 500, extras, e);
        }
      }
      // SPA fallback
      const index = path.join(state.root, "index.html");
      if (!path.extname(p) && fs.existsSync(index)) {
        registraLido("est:" + index, index);
        return send(res, 200, MIME[".html"], html(index), extras);
      }
      if (!path.extname(p) && ehProjetoNext()) {
        return await enviaEspecial(res, p, url, "not-found", 404, extras, null);
      }
      send(res, 404, "text/plain; charset=utf-8", recado404(p));
    } catch (e) {
      send(res, 500, "text/plain; charset=utf-8", String((e && e.message) || e) + "\n\n" + String((e && e.stack) || ""));
    }
  }

  function inicia(id, root, port, preset) {
    return new Promise((resolve, reject) => {
      state.id = id; state.root = root; state.preset = preset || "plain";
      const srv = http.createServer(handle);
      srv.on("odete:ws", (sock) => { state.sockets.add(sock); sock.on("close", () => state.sockets.delete(sock)); });
      srv.on("error", reject);
      srv.listen(port || 5173, () => { state.server = srv; state.port = srv.address().port; resolve({ port: state.port }); });
    });
  }

  // Fecha a porta, acorda quem espera com `null` (o laço do nativo termina) e descarta
  // os contextos — o motor continua vivo para o lint e para o próximo servidor.
  //
  // A resposta não espera o Go soltar a memória dos contextos: fechar o projeto logo
  // depois para o motor, e uma chamada pendurada numa resposta que não vem mais
  // seguraria o motor inteiro vivo. Os contextos saem da lista na hora; o descarte segue
  // sozinho.
  function para() {
    state.parado = true;
    if (state.server) state.server.close();
    state.server = null;
    const w = state.esperas;
    state.esperas = [];
    for (const f of w) f(null);
    state.fila.catch(() => {}).then(() => globalThis.__descartaContextos("dev" + state.id + ":"));
    return true;
  }

  function naFila(fn) {
    const vez = state.fila.then(fn);
    state.fila = vez.catch(() => {});
    return vez;
  }

  return {
    inicia, para, mudou, espera, vivos,
    invalida: () => naFila(invalida),
    diagnosticos: () => state.diagnostics,
    estatisticas: () => Object.assign({ contextos: globalThis.__contextosVivos(), sockets: state.sockets.size }, state.stats),
  };
};

// O que o Swift chama. Cada servidor tem um id; as chamadas antigas, sem id, valem para
// todos (é assim que o botão Rebuild e o código de antes continuam funcionando).
(function () {
  const servidores = globalThis.__devServidores || (globalThis.__devServidores = new Map());
  const um = (id) => {
    const s = servidores.get(id);
    if (!s) throw new Error("dev server " + id + " não está no ar");
    return s;
  };
  const todos = (id) => (id == null ? [...servidores.values()] : [um(id)]);

  globalThis.__devGuardaVivos = () => {
    const uniao = new Set();
    for (const s of servidores.values()) for (const f of s.vivos()) uniao.add(f);
    globalThis.__guardaSo(uniao);
  };

  globalThis.__devStart = async (root, port, preset) => {
    const id = (globalThis.__devProximoId = (globalThis.__devProximoId || 0) + 1);
    const s = globalThis.__devCria();
    servidores.set(id, s);
    try {
      const r = await s.inicia(id, root, port, preset);
      return { id, port: r.port };
    } catch (e) {
      servidores.delete(id);
      throw e;
    }
  };
  globalThis.__devMudou = (id, alterados, criados) => um(id).mudou(alterados || [], criados || []);
  globalThis.__devInvalidate = async (id) => {
    let n = 0;
    for (const s of todos(id)) n += await s.invalida();
    return n;
  };
  globalThis.__devStop = async (id) => {
    const alvos = id == null ? [...servidores.keys()] : [id];
    for (const k of alvos) {
      const s = servidores.get(k);
      servidores.delete(k);
      if (s) await s.para();
    }
    return true;
  };
  globalThis.__devDiagnostics = (id) => todos(id).flatMap((s) => s.diagnosticos());
  globalThis.__devEspera = (id, versao) => {
    const s = servidores.get(id);
    return s ? s.espera(versao) : null;
  };
  globalThis.__devEstatisticas = (id) => um(id).estatisticas();
})();
