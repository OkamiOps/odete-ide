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
//   - os pacotes de node_modules ficam num pacote de dependências à parte, feito uma vez e
//     guardado em disco (dependencias.js): o rebuild liga e imprime só o código do app;
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
  // Os locks de cada gerenciador: mudar qualquer um é mudar os pacotes.
  const TRAVAS = ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb"];
  const ehDePacote = (f) => PASTAS_DE_PACOTES.some((n) => f.indexOf("/" + n + "/") >= 0);
  const state = {
    id: 0, root: "", server: null, port: 0, diagnostics: [], preset: "plain", base: "/", sockets: new Set(),
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
    // O pacote de dependências (criado em `inicia`). `ligado` cai se ele falhar: aí o
    // bundle do app volta a levar os pacotes junto, como antes, até o próximo Rebuild.
    pre: { ligado: true, deps: null },
    // Contadores, para os testes provarem o que não aconteceu. `lidosDePacote` é quantos
    // arquivos de node_modules o último bundle de app leu.
    stats: { builds: 0, reload: 0, css: 0, lidosDePacote: 0 },
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

  // Com o pacote de dependências, os pacotes ficam de fora e o bundle começa importando
  // ele. Os dois jeitos têm contextos separados: um não serve de cache para o outro.
  function opcoesDoBundle(entryRel, pre) {
    const o = { root: state.root, entries: [entryRel], format: "esm", platform: "browser", dev: true, outdir: "__odete", externalMissing: true };
    // Sem o pacote de dependências, a fachada do `vite build` mantém o `default` de um
    // CommonJS igual ao que o app recebia com ele (bundler.js, `fachada`).
    if (pre) { o.preempacota = true; o.banner = 'import "/@odete/deps.js";'; } else o.fachadas = true;
    return o;
  }
  const contextoDoBundle = (entryRel, pre) => "dev" + state.id + ":" + (pre ? "pre:" : "") + entryRel;

  // Um build de uma entrada. Incremental: o contexto do esbuild guarda a análise de quem
  // não mudou. A saída fica em bytes, do jeito que o esbuild entregou — não precisa virar
  // texto para ir ao navegador.
  //
  // O bundle só volta depois de o pacote de dependências ter tudo o que ele pede: o
  // navegador pede /@odete/deps.js ao rodar o bundle, e a resposta já é a certa.
  async function constroi(entryRel) {
    const key = entryRel;
    state.stats.builds++;
    let pre = state.pre.ligado;
    let r = await globalThis.__rebuild(contextoDoBundle(entryRel, pre), opcoesDoBundle(entryRel, pre));
    if (pre && r.ok && r.dependencias && r.dependencias.length) {
      const d = await state.pre.deps.garante(r.dependencias);
      if (!d.ok) {
        await desligaPreEmpacotamento(entryRel, d);
        pre = false;
        r = await globalThis.__rebuild(contextoDoBundle(entryRel, false), opcoesDoBundle(entryRel, false));
      }
    }
    // Os avisos do pacote de dependências são os que o bundle inteiro daria sobre os pacotes.
    const avisosDosPacotes = state.pre.ligado ? state.pre.deps.avisos().map((w) => ({ ...w, kind: "warning", entry: "@deps" })) : [];
    state.diagnostics = state.diagnostics.filter((d) => d.entry !== key && d.entry !== "@deps").concat(r.errors.map((e) => ({ ...e, kind: "error", entry: key })), r.warnings.map((w) => ({ ...w, kind: "warning", entry: key })), avisosDosPacotes);
    if (r.entradas) state.stats.lidosDePacote = r.entradas.filter(ehDePacote).length;
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

  // O pacote de dependências não saiu (um pacote ESM com `await` no topo, por exemplo,
  // não pode virar fábrica). Os pacotes voltam para dentro do bundle do app — mais lento,
  // mas o que funcionava antes continua funcionando. Erro de verdade num pacote aparece
  // no build inteiro, com o overlay de sempre. O próximo Rebuild tenta de novo.
  async function desligaPreEmpacotamento(entryRel, d) {
    if (!state.pre.ligado) return;
    state.pre.ligado = false;
    const motivo = (d.errors && d.errors[0] && d.errors[0].text) || "erro desconhecido";
    console.warn("[odete] o pacote de dependências falhou (" + motivo + "); os pacotes voltam para dentro do bundle do app.");
    // Os outros bundles apontam para um registro que não vai existir: refeitos no próximo pedido.
    for (const k of [...state.entradas.keys()]) if (k !== entryRel) state.entradas.delete(k);
    await state.pre.deps.esquece();
    await globalThis.__descartaContextos("dev" + state.id + ":pre:");
    await globalThis.__descartaContextos("dev" + state.id + ":@deps");
  }

  // O pacote de dependências e a folha dele. A folha é pedida pelo `<link>`, que o
  // navegador busca antes de rodar o bundle: espera o bundle da entrada (`?de=`), que é
  // quem diz de quais pacotes precisa. Com ETag, recarregar a página vira um 304 e o
  // megabyte do react-dom não passa de novo pelo servidor.
  async function enviaDeps(req, res, p, url) {
    const de = url.searchParams.get("de");
    if (de && state.pre.ligado) await bundle(de).catch(() => null);
    for (const e of [...state.entradas.values()]) await e.ultimo.catch(() => null);
    await state.pre.deps.pronto();
    const js = p.endsWith(".js");
    const etag = state.pre.deps.etag();
    const h = { "content-type": js ? MIME[".js"] : MIME[".css"], "cache-control": "no-cache", "access-control-allow-origin": "*", etag };
    if (req.headers && req.headers["if-none-match"] === etag) {
      res.writeHead(304, h);
      return res.end();
    }
    res.writeHead(200, h);
    res.end(js ? state.pre.deps.js() : state.pre.deps.css());
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
    // Os locks entram também: um `git pull` que só muda o package-lock.json, seguido de
    // `npm install`, trocava os pacotes sem mudar o package.json nem a lista de pastas de
    // node_modules — e o servidor seguia servindo o pacote velho. O
    // `node_modules/.package-lock.json` é o lock escondido que todo install regrava.
    for (const n of ["package.json", ".env", ".env.local", ".env.development", ".env.development.local", ...TRAVAS,
      path.join("node_modules", ".package-lock.json")]) {
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
    (path.dirname(f) === state.root &&
      (path.basename(f) === "package.json" || TRAVAS.includes(path.basename(f)) || path.basename(f).startsWith(".env")));

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
    const soEstilo = alterados.length > 0 && alterados.every((f) => /\.(css|scss|sass|less)$/i.test(f));
    for (const c of afetados) {
      if (c.startsWith("b:")) {
        if (!state.entradas.has(c.slice(2))) continue;
        const d = await refaz(c.slice(2));
        refeitos++;
        if (d.js) recarrega = true; else if (d.css) estilo = true;
      } else if (c.startsWith("next:") || c.startsWith("astro:")) {
        // Página do Next ou do Astro: o cache vai embora aqui — a data do arquivo da
        // página não muda quando é o componente importado que muda. Se só CSS mudou, a
        // página é refeita agora e comparada: JS igual quer dizer que só a folha troca,
        // no lugar e sem recarregar, como no Vite.
        const refeita = c.startsWith("next:") ? refazNext(c.slice(5), soEstilo) : refazAstro(c.slice(6), soEstilo);
        const d = await refeita;
        if (d.refeito) refeitos++;
        if (d.js) recarrega = true; else if (d.css) estilo = true;
      } else if (c.startsWith("ilhas:")) {
        // O pacote das ilhas não leva CSS (a folha sai do build do servidor): CSS sozinho
        // não muda o que ele entrega.
        if (!soEstilo) recarrega = true;
      } else {
        // Estático e index.html: a saída deles só existe no próximo pedido, então o
        // navegador pede de novo.
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
  //
  // O pacote de dependências sai da memória, mas não do disco: o próximo bundle confere o
  // cache, e só o refaz se o lockfile, o .env ou algum arquivo de pacote mudou.
  async function invalida() {
    state.entradas.clear();
    pacoteNext.clear();
    modAstro.clear();
    configCache = null; definesAstroCache = null; colecoesCache = null; entradasCache.clear();
    tsconfigCache = null; zodCache = null; jsYaml = undefined;
    ctxNext = null;
    for (const k of [...state.deps.keys()]) if (!k.startsWith("est:")) state.deps.delete(k);
    state.faltando.clear();
    globalThis.__esqueceTudo();
    state.pre.ligado = true;
    await state.pre.deps.esquece();
    await globalThis.__descartaContextos("dev" + state.id + ":");
    anuncia();
    avisa("reload");
    return state.sockets.size;
  }

  function errorOverlay(errors) {
    const msg = errors.map((e) => `${e.file ? e.file + ":" + e.line + ": " : ""}${e.text}`).join("\\n");
    return `console.error(${JSON.stringify(msg)}); document.body.innerHTML = '<pre style="white-space:pre-wrap;padding:16px;color:#e25d5d;background:#111;font:13px ui-monospace,monospace;margin:0;min-height:100vh">' + ${JSON.stringify(msg.replace(/</g, "&lt;"))} + '</pre>';`;
  }

  // Pacotes do package.json sem pasta em node_modules.
  //
  // Iam para o esm.sh, por um import map. Com node_modules pela metade isso misturava as
  // duas origens: o `react-dom` do esm.sh trazia o React de lá, o app usava o daqui, e com
  // duas cópias do React todo hook quebrava ("Invalid hook call" e o Preview preto). Sem
  // rede o esm.sh também não responde, então nem o caso offline ele salvava. Agora o
  // `npm run dev` instala o que falta antes de subir o servidor; se ainda faltar (a
  // instalação falhou, o servidor subiu por outro caminho), a página diz o que falta em
  // vez de ficar preta com um "does not resolve to a valid URL" no console.
  function importMap() {
    try {
      const arq = path.join(state.root, "package.json");
      if (!fs.existsSync(arq)) return "";
      const pkg = JSON.parse(fs.readFileSync(arq, "utf8"));
      const nomes = Object.keys(pkg.dependencies || {})
        .filter((nome) => !fs.existsSync(path.join(state.root, "node_modules", nome, "package.json")));
      if (!nomes.length) return "";
      const msg = "Faltam pacotes em node_modules: " + nomes.join(", ") +
        ". Rode npm install no terminal (o npm run dev já instala antes de subir).";
      return "<script>console.error(" + JSON.stringify("[odete] " + msg) + ");" +
        "addEventListener(\"DOMContentLoaded\",function(){var d=document.createElement(\"div\");d.textContent=" +
        JSON.stringify(msg) + ";d.style.cssText=\"position:fixed;left:0;right:0;top:0;z-index:2147483647;" +
        "padding:12px 16px;background:#3a1d1d;color:#ffb4b4;font:13px ui-monospace,monospace;white-space:pre-wrap\";" +
        "document.body.appendChild(d);});</script>";
    } catch (e) {
      return "";
    }
  }

  function html(file) {
    let src = fs.readFileSync(file, "utf8");
    // `%VITE_TITULO%` e `%MODE%` no HTML viram o valor, como no Vite (e no `vite build`).
    // Só o que existe em `import.meta.env`: um `100%` solto fica como está.
    const env = globalThis.__envDoVite(state.root, "development", "/", true);
    src = src.replace(/%(\S+?)%/g, (tudo, k) => (Object.prototype.hasOwnProperty.call(env, k) ? String(env[k]) : tudo));
    // <script type="module" src="/src/main.tsx"> → bundle + css
    const entries = [];
    // A folha dos pacotes vem antes da do app, na ordem em que o bundle inteiro as juntaria.
    src = src.replace(/<script\s+type="module"\s+src="([^"]+)"\s*><\/script>/g, (m, s) => {
      const rel = s.replace(/^\//, "");
      entries.push(rel);
      const pacotes = state.pre.ligado ? `<link rel="stylesheet" href="/@odete/deps.css?de=${encodeURIComponent(rel)}">` : "";
      return `${pacotes}<link rel="stylesheet" href="/@odete/css/${rel}"><script type="module" src="/@odete/js/${rel}"></script>`;
    });
    src = src.replace(/<link\b[^>]*>/g, folhaDoProjeto);
    const head = importMap() + CLIENT;
    src = src.includes("</head>") ? src.replace("</head>", head + "</head>") : head + src;
    return src;
  }

  // `<link rel="stylesheet" href="/src/style.css">`, o jeito do guia do Tailwind com Vite:
  // servida crua, a folha chegava com o `@import "tailwindcss"` sem processar. Ela passa
  // pelo mesmo build que o CSS importado do JS (Tailwind, Sass, Less) e, em /@odete/css/,
  // troca sem recarregar a página. Folha de fora ou de public/ fica como está.
  function folhaDoProjeto(tag) {
    if (!/rel\s*=\s*["']?stylesheet/i.test(tag)) return tag;
    const m = /href\s*=\s*["']([^"']+)["']/i.exec(tag);
    if (!m || /^(?:[a-z]+:)?\/\//i.test(m[1]) || m[1].startsWith("/@odete/")) return tag;
    const rel = m[1].split("?")[0].replace(/^\.?\//, "");
    if (!/\.(css|scss|sass|less)$/i.test(rel)) return tag;
    const f = path.join(state.root, rel);
    if (!f.startsWith(state.root + "/") || f.startsWith(path.join(state.root, "public") + "/") || !fs.existsSync(f)) return tag;
    return tag.replace(m[0], `href="/@odete/css/${rel}"`);
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
    // O embrulho das ilhas precisa existir antes de o primeiro módulo "use client" ser
    // avaliado — e isso pode ser o middleware ou uma Server Action, não só uma página.
    globalThis.__next.instalaIlhas(React);
    ctxNext = { React, servidor, req, carrega: carregaNext, carregaRota };
    return ctxNext;
  }

  // Cada página vira um pacote CJS só, com React e `next/*` de fora.
  //
  // Transpilar arquivo a arquivo não fecha: `__transformCJS` é assíncrono e o `require`
  // dentro do módulo é síncrono. Empacotando, tudo o que é relativo já entra junto e o
  // `__req` só precisa atender o que ficou de fora — e é aí que o React continua sendo
  // um só, o do servidor, senão hook e contexto quebram com duas cópias.
  //
  // Uma rota (layouts e página) é um pacote só: um módulo que os dois importam — o
  // contexto de um provider, uma store, um cliente de banco — tem de ser o mesmo objeto
  // para os dois, e em pacotes separados cada um levava a sua cópia. Middleware, route
  // handler e o módulo de uma Server Action continuam sendo um arquivo cada.
  //
  // O CSS que a rota importa (globals.css, page.module.css, o do Tailwind) sai do mesmo
  // build, pelo mesmo pipeline do bundler, numa folha à parte, na ordem do documento: é
  // ela que `/@odete/css/@next/<rota>` serve.
  const pacoteNext = new Map();
  // O último build de cada pacote, mesmo depois de o cache cair: se o JS saiu igual, os
  // exports de antes continuam valendo, e trocar só o CSS não reavalia a página.
  const ultimoNext = new Map();
  // Mapa da rota para os módulos de cliente que ela usa, preenchido no render e lido
  // quando o navegador pede o pacote de hidratação.
  const ilhasDaRota = new Map();
  const ilhasDoBuild = {};
  // Os arquivos (layouts, página) do pacote de cada rota servida, para a folha dela.
  const folhasDaRota = new Map();
  async function carregaNext(arquivo) {
    return (await pacoteDoNext(arquivo)).exports;
  }
  // Os exports de cada arquivo da lista, na mesma ordem.
  async function carregaRota(arquivos) {
    return (await pacoteDoNext(arquivos)).exports;
  }

  const ENTRADA_DA_ROTA = "__odete_rota_next.js";

  async function pacoteDoNext(alvo) {
    const lista = [].concat(alvo);
    const chave = Array.isArray(alvo) ? "rota:" + lista.join("|") : alvo;
    const mt = lista.map((a) => fs.statSync(a).mtimeMs).join(",");
    const cache = pacoteNext.get(chave);
    if (cache && cache.mt === mt) return cache;
    const opcoes = {
      root: state.root, format: "cjs", platform: "node", dev: true, outdir: "__odete_next",
      external: ["react", "react-dom", "react/jsx-runtime", "react/jsx-dev-runtime", "next/*"],
      ilhas: ilhasDoBuild, acoes: "servidor",
    };
    if (Array.isArray(alvo)) {
      opcoes.entries = [ENTRADA_DA_ROTA];
      opcoes.virtuais = { [ENTRADA_DA_ROTA]: lista.map((a, i) => "export * as m" + i + " from " + JSON.stringify(a) + ";").join("\n") };
    } else {
      opcoes.entries = [path.relative(state.root, alvo)];
    }
    const r = await globalThis.__rebuild("dev" + state.id + ":next:" + chave, opcoes);
    // O que a página importa entra no grafo: mexer num componente dela tem de derrubar o
    // cache da página, e a data do arquivo da página não muda quando é o componente.
    const principal = lista[lista.length - 1];
    defineDeps("next:" + chave, r.entradas ? r.entradas.concat(lista) : lidosNaFalha("next:" + chave, principal, r.errors));
    defineFaltando("next:" + chave, r.faltando);
    anuncia();
    if (!r.ok) throw new Error((r.errors[0] && r.errors[0].text) || "build da página falhou");
    const saida = r.saidas.find((f) => f.path.endsWith(".js"));
    if (!saida) throw new Error("build da página não produziu JS");
    const folha = r.saidas.find((f) => f.path.endsWith(".css"));
    const css = folha ? folha.text : "", cssHash = folha ? folha.hash : "";
    const antes = ultimoNext.get(chave);
    let exports;
    if (antes && antes.jsHash === saida.hash) {
      exports = antes.exports;
    } else {
      const mod = { exports: {} };
      const ctx = contextoNext();
      const req = (spec) => {
        if (spec.startsWith("next/")) return globalThis.__next.substituto(spec, ctx.React);
        return ctx.req(spec);
      };
      const fn = (0, eval)("(function (module, exports, require) {" + saida.text + "\n})\n//# sourceURL=" + principal);
      fn(mod, mod.exports, req);
      exports = Array.isArray(alvo) ? lista.map((_, i) => mod.exports["m" + i]) : mod.exports;
    }
    const pronto = { alvo, mt, exports, jsHash: saida.hash, css, cssHash };
    pacoteNext.set(chave, pronto);
    ultimoNext.set(chave, pronto);
    return pronto;
  }

  // A folha de uma rota: o CSS dos layouts e da página, de fora para dentro. O esbuild
  // já junta numa folha só o que dois deles importam (o globals.css do layout e da
  // página sai uma vez).
  async function folhaDaRota(p) {
    const arquivos = folhasDaRota.get(p);
    if (!arquivos) return "";
    try { return (await pacoteDoNext(arquivos)).css; } catch (e) { return ""; }
  }

  // Depois de uma mudança no grafo de um pacote do Next. Com `soEstilo` (só CSS mudou)
  // vale refazer já, para saber se a página pode ficar e só a folha trocar.
  async function refazNext(chave, soEstilo) {
    const antes = pacoteNext.get(chave) || ultimoNext.get(chave);
    pacoteNext.delete(chave);
    if (!antes || !soEstilo) return { js: true, css: false, refeito: false };
    try {
      const depois = await pacoteDoNext(antes.alvo);
      return { js: depois.jsHash !== antes.jsHash, css: depois.cssHash !== antes.cssHash, refeito: true };
    } catch (e) {
      return { js: true, css: false, refeito: true };
    }
  }

  // `next/*` no navegador: a mesma fábrica que o servidor usa (next-cliente.js), mais um
  // módulo pequeno por especificador. Sem isto, `next/link` numa ilha resolvia para o
  // pacote `next` instalado, que espera o roteador de verdade e quebra a hidratação.
  //
  // Os módulos virtuais que importam pacote (`react`) moram num caminho absoluto dentro
  // do projeto: o resolvedor procura node_modules a partir da pasta de quem importa, e um
  // nome solto ("odete-next-cliente") não tem pasta — o `react` ficava sem resolver e o
  // navegador parava em "Module name 'react' does not resolve to a valid URL".
  function substitutosNextDoCliente() {
    const fabrica = path.join(state.root, "__odete_next_cliente.js");
    const m = "import m from " + JSON.stringify(fabrica) + ";\n";
    return {
      [fabrica]: globalThis.__nextClienteJS +
        '\nimport * as __R from "react";\nimport * as __RD from "react-dom";\n' +
        'export default globalThis.__odeteNextFabrica(__R.default || __R, __RD.default || __RD, "cliente");\n',
      "next/link": m + "export default m.Link;\nexport const useLinkStatus = m.useLinkStatus;\n",
      "next/image": m + "export default m.Image;\nexport const getImageProps = m.getImageProps;\n",
      "next/navigation": m + ["useRouter", "usePathname", "useSearchParams", "useParams", "useSelectedLayoutSegment",
        "useSelectedLayoutSegments", "useServerInsertedHTML", "redirect", "permanentRedirect", "notFound", "forbidden",
        "unauthorized", "unstable_rethrow", "RedirectType", "ReadonlyURLSearchParams"]
        .map((n) => "export const " + n + " = m.navegacao." + n + ";").join("\n") + "\n",
      // CommonJS de propósito: o nome da família é o do import, e só um módulo dinâmico
      // atende qualquer nome (ver `moduloGoogle` na fábrica).
      "next/font/google": "module.exports = require(" + JSON.stringify(fabrica) + ").default.fontes(null).moduloGoogle;\n",
      "next/font/local": m + "export default m.fontes(null).local;\n",
      "next/dynamic": m + "export default m.dynamic;\n",
      "next/script": m + "export default m.Script;\n",
      "next/head": m + "export default m.Head;\n",
      "next/router": m + "export const useRouter = m.useRouterPages;\nexport default m.roteador;\n",
    };
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
    // Caminho absoluto pelo mesmo motivo dos substitutos: a entrada importa `react`.
    const entrada = path.join(state.root, "__odete_ilhas_entrada.js");
    const opcoes = {
      root: state.root, entries: [entrada], format: "esm", platform: "browser",
      dev: true, outdir: "__odete_ilhas", externalMissing: true, acoes: "cliente", metafile: true,
      virtuais: Object.assign(substitutosNextDoCliente(), {
        [entrada]: globalThis.__ilhasClienteJS,
        "virtual:odete-ilhas": virtual,
      }),
    };
    // Este build é avulso (sem contexto) e roda a cada página: com o React e o react-dom
    // dentro, cada navegação reanalisava o react-dom do zero. Com o pacote de
    // dependências, o React vem de /@odete/deps.js e aqui fica só o código das ilhas.
    const pre = state.pre.ligado;
    if (pre) { opcoes.preempacota = true; opcoes.banner = 'import "/@odete/deps.js";'; }
    let r = await globalThis.__buildBruto(opcoes);
    if (pre && r.ok && r.dependencias && r.dependencias.length) {
      const d = await state.pre.deps.garante(r.dependencias);
      if (!d.ok) {
        await desligaPreEmpacotamento(null, d);
        delete opcoes.preempacota; delete opcoes.banner; opcoes.fachadas = true;
        r = await globalThis.__buildBruto(opcoes);
      }
    }
    if (r.entradas) { defineDeps("ilhas:" + rota, r.entradas); anuncia(); }
    if (!r.ok) throw new Error((r.errors[0] && r.errors[0].text) || "build das ilhas falhou");
    const saida = r.saidas.find((f) => f.path.endsWith(".js"));
    return saida ? saida.contents : "// build das ilhas não produziu JS";
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

  // Projeto Astro: o preset, o astro.config ou o pacote no package.json. Só `src/pages`
  // não basta — um app Vite com React também tem, e os .ts de lá não são endpoints.
  function ehProjetoAstro() {
    if (!fs.existsSync(path.join(state.root, "src", "pages"))) return false;
    if (state.preset === "astro") return true;
    if (["astro.config.mjs", "astro.config.ts", "astro.config.js", "astro.config.mts"].some((n) => fs.existsSync(path.join(state.root, n)))) return true;
    try {
      const pkg = JSON.parse(fs.readFileSync(path.join(state.root, "package.json"), "utf8"));
      return !!((pkg.dependencies || {}).astro || (pkg.devDependencies || {}).astro);
    } catch (e) {
      return false;
    }
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

  // `<odete-ilha>` e `<odete-filhos>` são embrulhos e não podem ocupar lugar: sem isto um
  // componente de cliente dentro de um flex ou de um grid vira um item inline a mais, e o
  // layout muda só por ter virado ilha.
  const ESTILO_DAS_ILHAS = "<style>odete-ilha,odete-filhos{display:contents}</style>";

  // Monta o documento de uma rota do Next: corpo renderizado, metadata, a folha da rota,
  // fontes e o script das ilhas quando a rota tem alguma.
  //
  // O layout raiz do App Router escreve `<html>` e `<body>`, e o React devolve o
  // documento inteiro: o que é da Odete entra no `<head>` dele. Sem `<html>` (Pages
  // Router, ou um layout que não o escreve), o documento é montado em volta.
  async function paginaNext(rotaNext, p, url) {
    const usadas = new Set();
    const ctx = contextoNext();
    folhasDaRota.set(p, rotaNext.layouts.concat(rotaNext.carregando ? [rotaNext.carregando] : [], [rotaNext.pagina]));
    const r = await globalThis.__next.renderiza(ctx, rotaNext, url, usadas);
    ilhasDaRota.set(p, [...usadas]);
    const folha = (await folhaDaRota(p))
      ? '<link rel="stylesheet" href="/@odete/css/@next' + encodeURI(p) + '">'
      : "";
    const cabeca = r.cabeca + folha + ESTILO_DAS_ILHAS + importMap() + globalThis.__next.cabecalhoDeFontes() + CLIENT;
    // Os parâmetros da rota vão junto para o `useParams()` das ilhas; `<` escapado para o
    // valor não fechar o script.
    const hidrata = usadas.size
      ? "<script>self.__odeteRota=" + JSON.stringify({ params: rotaNext.params || {} }).replace(/</g, "\\u003c") + "</script>" +
        '<script type="module" src="/@odete/ilhas' + encodeURI(p) + '"></script>'
      : "";
    if (!r.documento) {
      return "<!doctype html><html><head>" + cabeca + "</head><body>" + r.corpo + hidrata + "</body></html>";
    }
    let html = r.corpo;
    const abre = /<head(\s[^>]*)?>/i.exec(html);
    if (abre) {
      const i = abre.index + abre[0].length;
      html = html.slice(0, i) + cabeca + html.slice(i);
    } else {
      html = html.replace(/<html(\s[^>]*)?>/i, (t) => t + "<head>" + cabeca + "</head>");
    }
    const fim = html.lastIndexOf("</body>");
    return fim >= 0 ? html.slice(0, fim) + hidrata + html.slice(fim) : html + hidrata;
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
  // Carrega um .astro como módulo, compilando na hora (astro.js) e resolvendo os imports
  // dele: outros .astro (componentes e layouts), os módulos do projeto (.ts, .js, .json,
  // CSS) — empacotados pelo esbuild, como o Next —, imagens, markdown e os módulos
  // virtuais do Astro (`astro:content`, `astro:assets`). Cache por data do arquivo; o que
  // o esbuild leu entra no grafo, então editar um .ts importado refaz a página.
  const modAstro = new Map();
  const carregandoAstro = new Map();
  const EXT_IMAGEM = /\.(png|jpe?g|gif|webp|avif|svg|ico|bmp|tiff?)$/i;
  const EXT_ESTILO = /\.(css|scss|sass|less|styl|stylus|pcss|postcss)$/i;
  const EXT_CODIGO_DE_PAGINA = /\.(ts|js|mjs|mts|cjs|cts)$/i;

  let reqProjetoAstro = null;
  function requireDoProjeto() {
    if (!reqProjetoAstro) reqProjetoAstro = globalThis.__odete_makeRequire(path.join(state.root, "__odete_astro__.js"));
    return reqProjetoAstro;
  }

  // `import.meta.env` do Astro: o do Vite, mais `SITE`.
  let definesAstroCache = null;
  function definesAstro() {
    if (definesAstroCache) return definesAstroCache;
    const env = Object.assign({}, globalThis.__envDoVite(state.root, "development", "/", true));
    const site = configDoAstro().site;
    if (site) env.SITE = String(site);
    env.ASSETS_PREFIX = undefined;
    const d = { "import.meta.env": JSON.stringify(env) };
    for (const k of Object.keys(env)) d["import.meta.env." + k] = env[k] === undefined ? "undefined" : JSON.stringify(env[k]);
    definesAstroCache = d;
    return d;
  }

  // Um id de escopo por arquivo, relativo à raiz: o mesmo em qualquer aparelho.
  function cidDoAstro(arquivo) {
    const rel = path.relative(state.root, arquivo);
    let h = 0x811c9dc5;
    for (let i = 0; i < rel.length; i++) { h ^= rel.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
    return "data-astro-cid-" + h.toString(36);
  }

  function hashTexto(s) {
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
    return h.toString(36) + ":" + s.length;
  }

  // Os pacotes do package.json ficam de fora dos pacotes do esbuild: o `require` do
  // runtime os carrega de node_modules, uma cópia só. Os módulos virtuais do Astro também,
  // e quem os atende é `requireAstro`.
  const VIRTUAIS_DO_ASTRO = ["astro:content", "astro:assets", "astro:env/client", "astro:env/server", "astro:transitions",
    "astro:transitions/client", "astro:middleware", "astro:actions", "astro:i18n", "astro:schema", "astro:config/client",
    "astro:config/server", "astro:components", "astro:prefetch", "astro:container"];
  //
  // Os outros pacotes entram no pacote do esbuild, convertidos para CommonJS: o `require`
  // deste motor não transforma ESM, e pacote de Astro é quase sempre ESM (`@astrojs/rss`).
  // Ficam de fora o `astro` (atendido por substitutos) e o `zod`, que precisa ser uma cópia
  // só entre o schema do projeto e o `image()` daqui.
  function externosDoAstro() {
    return VIRTUAIS_DO_ASTRO.concat(["astro", "astro/*", "zod"]);
  }

  // Os do config: todo pacote do package.json fica de fora (as integrações nem precisam
  // estar instaladas; ver `carregaConfigDoAstro`).
  function externosDoConfig() {
    const lista = externosDoAstro();
    try {
      const pkg = JSON.parse(fs.readFileSync(path.join(state.root, "package.json"), "utf8"));
      for (const n of Object.keys(Object.assign({}, pkg.dependencies || {}, pkg.devDependencies || {}))) lista.push(n, n + "/*");
    } catch (e) { /* sem package.json */ }
    // E o que o próprio config importa: uma integração que só foi escrita, sem instalar.
    try {
      const txt = fs.readFileSync(configCache.arquivo, "utf8");
      for (const m of txt.matchAll(/(?:from|import)\s*\(?\s*['"]([^'"./][^'"]*)['"]/g)) lista.push(m[1]);
    } catch (e) { /* sem config */ }
    return lista;
  }

  // O `require` dos módulos empacotados e dos imports de pacote do frontmatter.
  function requireAstro(spec) {
    const s = substitutoAstro(spec);
    if (s) return s;
    return requireDoProjeto()(spec);
  }

  function substitutoAstro(spec) {
    if (spec === "astro:content") return moduloContent();
    if (spec === "astro:assets") return moduloAssets();
    if (spec === "astro/zod" || spec === "astro:schema" || (spec === "zod" && zodCache)) return moduloZod();
    if (spec === "astro/loaders") return { __esModule: true, glob: (o) => Object.assign({ __odeteLoader: "glob" }, o), file: (f, o) => Object.assign({ __odeteLoader: "file", arquivo: f }, o) };
    if (spec === "astro/config") return moduloConfigDoAstro();
    if (spec === "astro:env/client" || spec === "astro:env/server") {
      const env = JSON.parse(definesAstro()["import.meta.env"]);
      return Object.assign({ __esModule: true, getSecret: (k) => env[k] }, env);
    }
    if (spec === "astro:transitions") {
      return { __esModule: true, ClientRouter: () => "", ViewTransitions: () => "", fade: () => ({}), slide: () => ({}) };
    }
    if (spec === "astro:transitions/client") return { __esModule: true, navigate: (u) => { location.href = u; } };
    if (spec === "astro:middleware") return { __esModule: true, defineMiddleware: (f) => f, sequence: (...f) => f[0] };
    if (spec === "astro:i18n") return { __esModule: true, getRelativeLocaleUrl: (l, p) => "/" + (p || ""), getAbsoluteLocaleUrl: (l, p) => "/" + (p || "") };
    if (/^astro:/.test(spec)) return { __esModule: true };
    return null;
  }

  // ---- empacotamento dos imports ----
  // Os imports de um .astro que são módulos do projeto (.ts, .js, .json, CSS) saem num
  // build só do esbuild, com contexto incremental: `export * as m0 from "…"` para cada
  // um. O CSS que eles trazem sai numa folha, que vai para a página. Um arquivo que o
  // esbuild leu entra no grafo do .astro — mudar o .ts refaz a página.
  function caminhoDoImport(spec, pasta) {
    if (spec.startsWith("./") || spec.startsWith("../")) return path.resolve(pasta, spec);
    if (spec.startsWith("/")) return spec.startsWith(state.root + "/") ? spec : path.join(state.root, spec);
    // `@/x` e `~/x` do tsconfig (paths); o resto é pacote.
    const alias = aliasDoTsconfig(spec);
    return alias;
  }

  let tsconfigCache = null;
  function aliasDoTsconfig(spec) {
    if (tsconfigCache === null) {
      tsconfigCache = [];
      try {
        const txt = fs.readFileSync(path.join(state.root, "tsconfig.json"), "utf8")
          .replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"])\/\/.*$/gm, "$1").replace(/,(\s*[}\]])/g, "$1");
        const co = (JSON.parse(txt).compilerOptions) || {};
        const base = path.resolve(state.root, co.baseUrl || ".");
        for (const k of Object.keys(co.paths || {})) {
          const alvo = [].concat(co.paths[k])[0];
          if (alvo) tsconfigCache.push({ prefixo: k.replace(/\*$/, ""), alvo: path.resolve(base, alvo.replace(/\*$/, "")), coringa: k.endsWith("*") });
        }
      } catch (e) { /* sem tsconfig ou sem paths */ }
    }
    for (const a of tsconfigCache) {
      if (a.coringa ? spec.startsWith(a.prefixo) : spec === a.prefixo) return path.join(a.alvo, spec.slice(a.prefixo.length));
    }
    return null;
  }

  async function pacoteDoAstro(consumidor, specs, pasta) {
    const alvos = [];
    for (const spec of specs) {
      if (/^astro([:/]|$)/.test(spec) || /^zod(\/|$)/.test(spec)) continue;
      // Pacote (`@astrojs/rss`, `date-fns`): o esbuild resolve a partir da raiz e o traz
      // convertido para CommonJS.
      const abs = caminhoDoImport(spec, pasta) || (/^[@\w]/.test(spec) && !/^[a-z]+:/.test(spec) ? spec : null);
      if (!abs || /\.astro$/.test(abs) || EXT_IMAGEM.test(abs) || /\.mdx?$/.test(abs)) continue;
      alvos.push({ spec, abs });
    }
    if (!alvos.length) return { mods: new Map(), css: "", jsHash: "", entradas: [] };
    return empacotaAstro(consumidor, alvos);
  }

  async function empacotaAstro(consumidor, alvos, requer, externos) {
    const entrada = path.join(state.root, "__odete_astro_" + hashTexto(consumidor).replace(/\W/g, "") + ".js");
    const virtual = alvos.map((a, i) => (EXT_ESTILO.test(a.abs) && !/\.module\.[a-z]+$/i.test(a.abs)
      ? "import " + JSON.stringify(a.abs) + ";"
      : "export * as m" + i + " from " + JSON.stringify(a.abs) + ";")).join("\n");
    const r = await globalThis.__rebuild("dev" + state.id + ":astro:" + consumidor, {
      root: state.root, entries: [entrada], virtuais: { [entrada]: virtual },
      format: "cjs", platform: "node", dev: true, outdir: "__odete_astro", external: externos || externosDoAstro(),
    });
    if (!r.ok) {
      const e = r.errors[0] || {};
      throw new Error((e.file ? e.file + ":" + e.line + ": " : "") + (e.text || "build dos imports falhou"));
    }
    const js = r.saidas.find((f) => f.path.endsWith(".js"));
    const css = r.saidas.find((f) => f.path.endsWith(".css"));
    // Empacotar o zod custa segundos sem JIT: só quando alguém o pede de verdade.
    if (js && consumidor !== "@zod" && /require\("(zod|astro\/zod|astro:schema|astro:content)"\)/.test(js.text)) await garanteZod();
    const mod = { exports: {} };
    if (js) {
      const fn = (0, eval)("(function (module, exports, require) {" + js.text + "\n})\n//# sourceURL=" + consumidor + ".imports.js");
      fn(mod, mod.exports, requer || requireAstro);
    }
    const mods = new Map();
    alvos.forEach((a, i) => mods.set(a.spec, mod.exports["m" + i] || {}));
    return { mods, css: css ? css.text : "", jsHash: (js ? js.hash : "") + "/" + (css ? css.hash : ""), entradas: r.entradas || [], exports: mod.exports };
  }

  // Um arquivo só (endpoint, content.config.ts, astro.config.mjs), empacotado do mesmo jeito.
  async function moduloDeArquivo(consumidor, arquivo) {
    const pk = await empacotaAstro(consumidor, [{ spec: arquivo, abs: arquivo }]);
    defineDeps(consumidor, [arquivo].concat(pk.entradas));
    anuncia();
    return pk.mods.get(arquivo);
  }

  // ---- imagens ----
  // `import foto from "./foto.jpg"` é o ImageMetadata do Astro: endereço, largura, altura
  // e formato. O endereço serve o próprio arquivo do projeto. Um SVG também é componente
  // (`<Logo />` escreve o SVG na página), como no Astro 5.
  function dimensoes(bytes, ext) {
    const b = bytes;
    const u16 = (i) => (b[i] << 8) | b[i + 1];
    const u32 = (i) => ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0;
    try {
      if (ext === "png" && b[1] === 0x50) return { width: u32(16), height: u32(20) };
      if (ext === "gif") return { width: b[6] | (b[7] << 8), height: b[8] | (b[9] << 8) };
      if (ext === "jpg" || ext === "jpeg") {
        let i = 2;
        while (i < b.length) {
          if (b[i] !== 0xff) { i++; continue; }
          const m = b[i + 1];
          if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) return { height: u16(i + 5), width: u16(i + 7) };
          i += 2 + u16(i + 2);
        }
      }
      if (ext === "webp") {
        const tipo = String.fromCharCode(b[12], b[13], b[14], b[15]);
        if (tipo === "VP8X") return { width: 1 + (b[24] | (b[25] << 8) | (b[26] << 16)), height: 1 + (b[27] | (b[28] << 8) | (b[29] << 16)) };
        if (tipo === "VP8 ") return { width: (b[26] | (b[27] << 8)) & 0x3fff, height: (b[28] | (b[29] << 8)) & 0x3fff };
        if (tipo === "VP8L") { const v = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24); return { width: (v & 0x3fff) + 1, height: ((v >> 14) & 0x3fff) + 1 }; }
      }
      if (ext === "svg") {
        const t = Buffer.from(b).toString("utf8");
        const svg = /<svg\b[^>]*>/i.exec(t);
        if (svg) {
          const w = /\swidth=["']?([\d.]+)/.exec(svg[0]), h = /\sheight=["']?([\d.]+)/.exec(svg[0]);
          const vb = /viewBox=["']\s*[-\d.]+[\s,]+[-\d.]+[\s,]+([\d.]+)[\s,]+([\d.]+)/.exec(svg[0]);
          return { width: w ? +w[1] : vb ? +vb[1] : 0, height: h ? +h[1] : vb ? +vb[2] : 0 };
        }
      }
    } catch (e) { /* cabeçalho fora do esperado */ }
    return { width: 0, height: 0 };
  }

  function urlDoArquivo(abs) {
    const pub = path.join(state.root, "public");
    if (abs.startsWith(pub + "/")) return "/" + path.relative(pub, abs).split(path.sep).join("/");
    return "/@odete/arquivo/" + path.relative(state.root, abs).split(path.sep).map(encodeURIComponent).join("/");
  }

  function imagemDe(abs) {
    const ext = path.extname(abs).slice(1).toLowerCase();
    const bytes = fs.readFileSync(abs);
    const d = dimensoes(bytes, ext);
    const meta = { src: urlDoArquivo(abs), width: d.width, height: d.height, format: ext === "jpeg" ? "jpg" : ext, fsPath: abs };
    if (ext === "svg") {
      const fonte = Buffer.from(bytes).toString("utf8").replace(/<\?xml[^>]*>\s*/, "");
      meta.render = (Astro) => {
        const extras = globalThis.__astroRuntime.__attrs(Object.assign({}, Astro && Astro.props));
        return fonte.replace(/<svg\b/i, "<svg" + extras);
      };
    }
    return meta;
  }

  // ---- markdown ----
  // `.md` e `.mdx`: o texto vira HTML (markdown.js) e o MDX, um .astro — os imports e os
  // componentes dele passam pelo mesmo compilador.
  function imagemDoMarkdown(pasta) {
    return (href) => {
      if (!href || /^[a-z][a-z0-9+.-]*:|^\/\/|^#/i.test(href)) return href;
      const abs = href.startsWith("/") ? path.join(state.root, "public", href) : path.resolve(pasta, decodeURIComponent(href));
      if (!href.startsWith("/") && fs.existsSync(abs)) return urlDoArquivo(abs);
      return href;
    };
  }

  let jsYaml;
  function frontmatterDe(texto) {
    if (jsYaml === undefined) { try { jsYaml = requireDoProjeto()("js-yaml"); } catch (e) { jsYaml = null; } }
    return globalThis.__odeteMarkdown.frontmatter(texto, jsYaml);
  }

  // O MDX vira a fonte de um .astro: frontmatter com os imports e o `frontmatter`, e o
  // corpo em HTML com os componentes no lugar.
  function mdxParaAstro(texto, dados) {
    const linhas = texto.split("\n");
    const topo = [], resto = [];
    let cerca = false, emImport = false;
    for (const l of linhas) {
      if (/^\s*(```|~~~)/.test(l)) cerca = !cerca;
      if (!cerca && (emImport || /^(import|export)\s/.test(l))) {
        topo.push(l);
        emImport = !/(from\s+['"][^'"]+['"]|^import\s+['"][^'"]+['"])\s*;?\s*$/.test(l) && /^(import|export)\s[^;]*$/.test(l) && !/[;}]\s*$/.test(l) ? true : false;
        continue;
      }
      resto.push(l);
    }
    return { topo: topo.join("\n") + "\nconst frontmatter = " + JSON.stringify(dados || {}) + ";", corpo: resto.join("\n") };
  }

  async function moduloMarkdown(abs) {
    const mt = fs.statSync(abs).mtimeMs;
    const cache = modAstro.get(abs);
    if (cache && cache.mt === mt) return cache;
    registraLido("astro:" + abs, abs);
    const fm = frontmatterDe(fs.readFileSync(abs, "utf8"));
    const pasta = path.dirname(abs);
    const ehMdx = /\.mdx$/i.test(abs);
    let Content, headings, css = "", jsHash;
    if (ehMdx) {
      const m = mdxParaAstro(fm.corpo, fm.dados);
      const r = globalThis.__odeteMarkdown.markdown(m.corpo, { imagem: imagemDoMarkdown(pasta), mdx: true });
      headings = r.headings;
      const pronto = await montaAstro(abs, "---\n" + m.topo + "\n---\n" + r.html, mt);
      Content = pronto.exports;
      css = pronto.css;
      jsHash = pronto.jsHash;
    } else {
      const r = globalThis.__odeteMarkdown.markdown(fm.corpo, { imagem: imagemDoMarkdown(pasta) });
      headings = r.headings;
      const html = r.html;
      Content = { render: async () => html, __arquivo: abs };
      jsHash = hashTexto(html);
    }
    const url = urlDaPaginaMarkdown(abs);
    const exports = {
      frontmatter: fm.dados, file: abs, url, Content, default: Content,
      getHeadings: () => headings, rawContent: () => fm.corpo, compiledContent: async () => (await Content.render({ props: {} }, {})),
    };
    const pronto = { mt, exports, css, jsHash, headings, dados: fm.dados, corpo: fm.corpo };
    modAstro.set(abs, pronto);
    return pronto;
  }

  function urlDaPaginaMarkdown(abs) {
    const base = path.join(state.root, "src", "pages");
    if (!abs.startsWith(base + "/")) return undefined;
    const rel = path.relative(base, abs).replace(/\.mdx?$/i, "").replace(/(^|\/)index$/, "");
    return "/" + rel;
  }

  // O `<style>` de um .astro antes do escopo, pelo pipeline de CSS do bundler (estilos.js):
  // Sass e Less pelo `lang`, e `@apply`/`@reference` do Tailwind. O CSS importado no
  // frontmatter não passa aqui: é um build do esbuild, e o plugin dele já o trata. O que
  // o Sass e o Tailwind leem vai para `ctx.vigiados`, que entra no grafo do .astro.
  async function estiloDoAstro(css, lang, arquivo, ctx, n) {
    const l = String(lang || "css").toLowerCase();
    const E = globalThis.__odeteEstilos;
    const tw = globalThis.__odeteTailwind;
    if (!E || !E.compilaTexto || (l === "css" && !(tw && tw.ehDoTailwind(css)))) return css;
    try {
      return await E.compilaTexto(css, l, arquivo, arquivo + "#estilo" + (n || 0) + ".css", ctx);
    } catch (e) {
      const onde = e && e.lugar ? path.relative(state.root, e.lugar.file) + ":" + e.lugar.line + ": " : path.relative(state.root, arquivo) + ": ";
      throw new Error(onde + ((e && e.message) || e));
    }
  }

  // ---- carregar um .astro ----
  async function carregaAstro(arquivo) {
    const mt = fs.statSync(arquivo).mtimeMs;
    const cache = modAstro.get(arquivo);
    if (cache && cache.mt === mt) return cache;
    // Dois componentes pedindo o mesmo ao mesmo tempo esperam o mesmo carregamento.
    const chave = arquivo + "@" + mt;
    if (carregandoAstro.has(chave)) return carregandoAstro.get(chave);
    const p = (async () => {
      try {
        return await montaAstro(arquivo, fs.readFileSync(arquivo, "utf8"), mt);
      } finally {
        carregandoAstro.delete(chave);
      }
    })();
    carregandoAstro.set(chave, p);
    return p;
  }

  async function montaAstro(arquivo, fonte, mt) {
    state.mtimes.set(arquivo, mt);
    const ctxEstilo = { root: state.root, vigiados: new Set(), pastas: new Set(), dev: true, novo: false };
    let c;
    try {
      c = await globalThis.__astroCompilaAsync(fonte, arquivo, {
        define: definesAstro(), cid: cidDoAstro(arquivo),
        processaEstilo: (css, lang, arq, n) => estiloDoAstro(css, lang, arq, ctxEstilo, n),
      });
    } catch (e) {
      // Erro de sintaxe no .astro ou no `<style>`: o arquivo (e o que o estilo leu) fica
      // vigiado, e consertar refaz a página.
      defineDeps("astro:" + arquivo, [arquivo].concat([...ctxEstilo.vigiados]));
      anuncia();
      throw e;
    }
    const pasta = path.dirname(arquivo);
    let pk;
    try {
      pk = await pacoteDoAstro(arquivo, c.specs, pasta);
    } finally {
      // O grafo do .astro: ele e o que o esbuild leu para os imports dele.
      defineDeps("astro:" + arquivo, [arquivo].concat(pk ? pk.entradas : [], [...ctxEstilo.vigiados]));
      anuncia();
    }
    if (c.specs.some((x) => /^(zod|astro\/zod|astro:schema|astro:content)$/.test(x))) await garanteZod();
    const mod = { exports: {} };
    const req = (spec, Astro) => importDoAstro(spec, pasta, pk, Astro);
    const fn = (0, eval)("(function (module, __req, __astroRuntime) {" + c.codigo + "\n})\n//# sourceURL=" + arquivo);
    fn(mod, req, globalThis.__astroRuntime);
    const pronto = {
      mt, exports: mod.exports,
      // O CSS dos imports vem antes do `<style>` do componente, como no Astro.
      cssImportado: pk.css, cssProprio: c.estilos.join("\n"),
      jsHash: hashTexto(c.codigo) + "/" + pk.jsHash.split("/")[0],
      cssHash: hashTexto(pk.css + c.estilos.join("\n")),
    };
    pronto.css = pronto.cssImportado + pronto.cssProprio;
    modAstro.set(arquivo, pronto);
    return pronto;
  }

  async function importDoAstro(spec, pasta, pk, Astro) {
    if (pk.mods.has(spec)) return pk.mods.get(spec);
    const s = substitutoAstro(spec);
    if (s) return s;
    const abs = caminhoDoImport(spec, pasta);
    if (!abs) return requireDoProjeto()(spec);
    if (/\.astro$/.test(abs)) {
      const m = await carregaAstro(abs);
      if (Astro && Astro.__usados) Astro.__usados.add(abs);
      return m.exports;
    }
    if (EXT_IMAGEM.test(abs)) {
      const meta = imagemDe(abs);
      return { __esModule: true, default: meta };
    }
    if (/\.mdx?$/i.test(abs)) {
      const m = await moduloMarkdown(abs);
      if (Astro && Astro.__usados) Astro.__usados.add(abs);
      return m.exports;
    }
    return requireDoProjeto()(abs);
  }

  // ---- astro.config ----
  // O `site` (que vira `Astro.site`) e as fontes (`<Font />`) vêm dele. As integrações
  // não rodam aqui: são plugins do Vite. Cada pacote que o config importa vira um objeto
  // que aceita qualquer chamada, e o `defineConfig` devolve o que recebeu.
  let configCache = null;
  function moduloConfigDoAstro() {
    const provedor = (nome) => (o) => Object.assign({ __odeteProvedor: nome }, o);
    return {
      __esModule: true, defineConfig: (c) => c, envField: new Proxy({}, { get: () => (o) => o }),
      fontProviders: { local: provedor("local"), google: provedor("google"), fontsource: provedor("fontsource"), bunny: provedor("bunny"), adobe: provedor("adobe"), fontshare: provedor("fontshare") },
      passthroughImageService: () => ({}), sharpImageService: () => ({}), squooshImageService: () => ({}),
    };
  }

  // Sem `__esModule` e sem `then`: o interop do esbuild põe o próprio objeto no `default`,
  // e um `then` faria dele uma promessa que nunca resolve.
  function qualquerCoisa() {
    const f = function () { return qualquer; };
    const qualquer = new Proxy(f, {
      get: (_, k) => (k === "__esModule" || k === "then" ? undefined : k === "default" ? qualquer : k === Symbol.toPrimitive ? () => "" : qualquer),
      apply: () => qualquer, construct: () => qualquer,
    });
    return qualquer;
  }

  function configDoAstro() {
    if (configCache) return configCache.config;
    configCache = { config: {} };
    const arquivo = ["astro.config.mjs", "astro.config.ts", "astro.config.js", "astro.config.mts"]
      .map((n) => path.join(state.root, n)).find((f) => fs.existsSync(f));
    configCache.arquivo = arquivo;
    return configCache.config;
  }

  // O config é lido de verdade (esbuild, assíncrono) na primeira página; até lá vale vazio.
  async function carregaConfigDoAstro() {
    configDoAstro();
    if (configCache.lido || !configCache.arquivo) return configCache.config;
    configCache.lido = true;
    try {
      // Integrações (`@astrojs/mdx`, `@astrojs/sitemap`) são plugins do Vite e nem precisam
      // estar instaladas: o que não se acha vira um objeto que aceita qualquer chamada.
      const requer = (spec) => {
        const s = substitutoAstro(spec);
        if (s) return s;
        try { return requireDoProjeto()(spec); } catch (e) { return qualquerCoisa(); }
      };
      const pk = await empacotaAstro("@config", [{ spec: "c", abs: configCache.arquivo }], requer, externosDoConfig());
      defineDeps("astro:@config", [configCache.arquivo].concat(pk.entradas));
      anuncia();
      const m = pk.mods.get("c") || {};
      // Os pacotes do config são integrações e plugins: aqui, qualquer coisa serve.
      const cfg = m.default || {};
      configCache.config = typeof cfg === "function" ? cfg({ command: "dev", mode: "development" }) || {} : cfg;
    } catch (e) {
      // Vai para o painel Problemas: sem o config, `Astro.site` e as fontes somem calados.
      const texto = globalThis.__odeteTexto("astroConfigIlegivel", path.basename(configCache.arquivo), (e && e.message) || e);
      console.warn("[odete] " + texto);
      state.diagnostics = state.diagnostics.filter((d) => d.entry !== "@astro-config")
        .concat([{ text: texto, file: path.relative(state.root, configCache.arquivo), line: null, column: null, lineText: null, kind: "warning", entry: "@astro-config" }]);
      anuncia();
    }
    definesAstroCache = null;
    return configCache.config;
  }

  // ---- astro:assets ----
  function moduloAssets() {
    const R = globalThis.__astroRuntime;
    const srcDe = (src) => (src && typeof src === "object" ? (src.default || src) : { src });
    const img = (props) => {
      const p = Object.assign({}, props);
      const meta = srcDe(p.src);
      const largura = p.width != null ? p.width : meta.width, altura = p.height != null ? p.height : meta.height;
      const extras = {};
      for (const k of Object.keys(p)) {
        if (["src", "width", "height", "format", "quality", "densities", "widths", "formats", "fallbackFormat", "pictureAttributes", "inferSize", "layout", "fit", "position", "priority"].indexOf(k) < 0) extras[k] = p[k];
      }
      if (p.priority) { extras.loading = extras.loading || "eager"; extras.fetchpriority = "high"; }
      return "<img" + R.__attr("src", meta.src) + R.__attr("width", largura) + R.__attr("height", altura) +
        R.__attrs(Object.assign({ loading: "lazy", decoding: "async" }, extras)) + ">";
    };
    const Image = (Astro) => img(Astro.props);
    const Picture = (Astro) => {
      const pa = Astro.props.pictureAttributes || {};
      return "<picture" + R.__attrs(pa) + ">" + img(Astro.props) + "</picture>";
    };
    const Font = (Astro) => htmlDaFonte(Astro.props || {});
    return {
      __esModule: true, Image, Picture, Font,
      getImage: async (o) => {
        const meta = srcDe(o && o.src);
        return { src: meta.src, attributes: { width: o.width || meta.width, height: o.height || meta.height }, options: o, rawOptions: o };
      },
      inferRemoteSize: async () => ({ width: 0, height: 0 }),
      imageConfig: {},
    };
  }

  // `<Font cssVariable="--x" />`: as `@font-face` da família que o config declara com essa
  // variável, e a variável apontando para ela. Arquivo local é servido do projeto; Google
  // vira o CSS da API deles.
  function htmlDaFonte(props) {
    const fontes = [].concat(configDoAstro().fonts || []);
    const f = fontes.find((x) => x && x.cssVariable === props.cssVariable);
    if (!f) return "";
    const fam = "'" + String(f.name).replace(/'/g, "") + "'";
    const pilha = [fam].concat([].concat(f.fallbacks || ["sans-serif"])).join(", ");
    let css = "", links = "";
    const prov = (f.provider && f.provider.__odeteProvedor) || "google";
    const variantes = (f.options && f.options.variants) || f.variants || [];
    if (prov === "local") {
      for (const v of variantes) {
        const srcs = [].concat(v.src || []).map((s) => (typeof s === "string" ? s : s && (s.url || s.path))).filter(Boolean);
        const urls = srcs.map((s) => {
          const abs = path.resolve(state.root, s);
          if (props.preload) links += '<link rel="preload" href="' + urlDoArquivo(abs) + '" as="font" type="font/' + (path.extname(abs).slice(1) || "woff2") + '" crossorigin>';
          return "url('" + urlDoArquivo(abs) + "')";
        });
        css += "@font-face{font-family:" + fam + ";src:" + urls.join(",") + ";font-weight:" + (v.weight || 400) +
          ";font-style:" + (v.style || "normal") + ";font-display:" + (v.display || "swap") + "}";
      }
    } else {
      const pesos = [].concat(f.weights || [400]).join(";");
      links += '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=' + encodeURIComponent(f.name).replace(/%20/g, "+") + ":wght@" + pesos + '&amp;display=swap">';
    }
    css += ":root{" + f.cssVariable + ":" + pilha + "}";
    return links + "<style>" + css + "</style>";
  }

  // ---- astro/zod ----
  // O zod do projeto (o Astro depende dele), carregado uma vez: uma cópia
  // só para o schema do projeto (`astro/zod`, `astro:content`, `zod`) e para o `image()`
  // daqui. É preparado antes de a página rodar (`garanteZod`), porque quem o pede é um
  // `require` síncrono.
  let zodCache = null;
  async function garanteZod() {
    if (zodCache) return zodCache;
    let achou = false;
    for (let d = state.root; ; d = path.dirname(d)) {
      if (fs.existsSync(path.join(d, "node_modules", "zod", "package.json"))) { achou = true; break; }
      if (d === path.dirname(d)) break;
    }
    if (!achou) return null;
    // Pelo `require` do motor primeiro: o CommonJS do zod carrega arquivo por arquivo,
    // sem transformar — sem JIT, bem menos do que o esbuild reanalisar o pacote inteiro.
    // O empacotamento fica para quando o `require` não der conta (um zod só ESM).
    let zz = null;
    const t0 = Date.now();
    try {
      const m = requireDoProjeto()("zod");
      zz = m.z || m;
    } catch (e) {
      const pk = await empacotaAstro("@zod", [{ spec: "zod", abs: "zod" }], null, VIRTUAIS_DO_ASTRO);
      zz = pk.mods.get("zod").z || pk.mods.get("zod");
    }
    state.stats.zodMs = Date.now() - t0;
    zodCache = Object.assign({ __esModule: true }, zz, { z: zz, default: zz });
    return zodCache;
  }
  function moduloZod() {
    if (!zodCache) throw new Error(globalThis.__odeteTexto("astroSemZod"));
    return zodCache;
  }

  // ---- astro:content ----
  // As content collections do `src/content.config.ts` (e as do jeito antigo, pastas em
  // `src/content/`). `glob()` e `file()` são lidos aqui; o schema é o zod do projeto, e o
  // `image()` dele resolve o caminho relativo ao arquivo da entrada.
  let colecoesCache = null;
  const entradasCache = new Map();
  let arquivoDaEntradaAtual = null;

  async function colecoesDoProjeto() {
    if (colecoesCache) return colecoesCache;
    const cfg = ["src/content.config.ts", "src/content.config.js", "src/content.config.mjs", "src/content/config.ts", "src/content/config.js", "src/content/config.mjs"]
      .map((n) => path.join(state.root, n)).find((f) => fs.existsSync(f));
    let cols = {};
    await garanteZod();
    if (cfg) {
      const m = await moduloDeArquivo("astro:@colecoes", cfg);
      cols = (m && m.collections) || {};
    }
    colecoesCache = cols;
    return cols;
  }

  function padraoParaRegex(p) {
    let re = "";
    for (let i = 0; i < p.length; i++) {
      const c = p[i];
      if (c === "*" && p[i + 1] === "*") { re += "(?:.*/)?"; i += p[i + 2] === "/" ? 2 : 1; continue; }
      if (c === "*") { re += "[^/]*"; continue; }
      if (c === "?") { re += "[^/]"; continue; }
      if (c === "{") { const f = p.indexOf("}", i); re += "(?:" + p.slice(i + 1, f).split(",").map((x) => x.replace(/[.+^$()|[\]\\]/g, "\\$&")).join("|") + ")"; i = f; continue; }
      re += c.replace(/[.+^$()|[\]\\]/g, "\\$&");
    }
    return new RegExp("^" + re + "$");
  }

  function arquivosEm(dir) {
    const out = [];
    const anda = (d) => {
      let itens = [];
      try { itens = fs.readdirSync(d); } catch (e) { return; }
      for (const n of itens.sort()) {
        if (n.startsWith(".") || PASTAS_DE_PACOTES.includes(n)) continue;
        const f = path.join(d, n);
        let st;
        try { st = fs.statSync(f); } catch (e) { continue; }
        if (st.isDirectory()) anda(f); else out.push(f);
      }
    };
    anda(dir);
    return out;
  }

  // O id que o glob() dá: o caminho relativo sem extensão, com cada parte em slug.
  const slugDoId = (rel) => rel.replace(/\.[^./]+$/, "").split("/").map((p) => globalThis.__odeteMarkdown.slugDe(p)).join("/").replace(/\/index$/, "");

  async function entradasDaColecao(nome) {
    if (entradasCache.has(nome)) return entradasCache.get(nome);
    const cols = await colecoesDoProjeto();
    let col = cols[nome];
    const pastaAntiga = path.join(state.root, "src", "content", nome);
    if (!col && !fs.existsSync(pastaAntiga)) {
      throw new Error(globalThis.__odeteTexto("astroColecaoNaoExiste", nome));
    }
    col = col || {};
    const loader = col.loader;
    const lidos = [];
    const brutas = [];
    let pastaVigiada = null;
    if (loader && loader.__odeteLoader === "glob") {
      const base = path.resolve(state.root, loader.base || ".");
      pastaVigiada = base;
      const padroes = [].concat(loader.pattern || "**/*").map(padraoParaRegex);
      for (const f of arquivosEm(base)) {
        const rel = path.relative(base, f).split(path.sep).join("/");
        if (!padroes.some((r) => r.test(rel))) continue;
        brutas.push(Object.assign(entradaDeArquivo(f), { id: null, rel }));
        lidos.push(f);
      }
      for (const b of brutas) b.id = typeof loader.generateId === "function"
        ? loader.generateId({ entry: b.rel, base: new URL("file://" + base + "/"), data: b.data })
        : (b.data && b.data.slug) || slugDoId(b.rel);
    } else if (loader && loader.__odeteLoader === "file") {
      const f = path.resolve(state.root, loader.arquivo);
      lidos.push(f);
      const txt = fs.readFileSync(f, "utf8");
      const dados = /\.ya?ml$/i.test(f) ? globalThis.__odeteMarkdown.yaml(txt) : JSON.parse(txt);
      const lista = Array.isArray(dados) ? dados : Object.keys(dados).map((k) => Object.assign({ id: k }, dados[k]));
      for (const d of lista) brutas.push({ id: String(d.id != null ? d.id : d.slug), data: d, body: undefined, arquivo: f });
    } else if (typeof loader === "function") {
      const lista = await loader();
      for (const d of [].concat(lista || [])) brutas.push({ id: String(d.id), data: d, body: undefined, arquivo: null });
    } else if (loader && typeof loader.load === "function") {
      throw new Error(globalThis.__odeteTexto("astroLoaderProprio", nome, loader.name || "load"));
    } else {
      // Coleção do jeito antigo: `src/content/<nome>/`, id com extensão e `slug`.
      pastaVigiada = pastaAntiga;
      for (const f of arquivosEm(pastaAntiga)) {
        if (!/\.(mdx?|json|ya?ml)$/i.test(f)) continue;
        const rel = path.relative(pastaAntiga, f).split(path.sep).join("/");
        const e = entradaDeArquivo(f);
        e.id = rel;
        e.slug = (e.data && e.data.slug) || slugDoId(rel);
        brutas.push(e);
        lidos.push(f);
      }
    }
    // O schema: função (com `image()`) ou o próprio schema do zod.
    let schema = col.schema;
    if (typeof schema === "function") schema = schema({ image: imagemDoSchema });
    const entradas = [];
    for (const b of brutas) {
      let data = b.data || {};
      if (schema && typeof schema.parse === "function") {
        arquivoDaEntradaAtual = b.arquivo;
        try {
          const r = schema.safeParse ? schema.safeParse(data) : { success: true, data: schema.parse(data) };
          if (!r.success) {
            const q = (r.error && r.error.issues && r.error.issues[0]) || {};
            throw new Error(globalThis.__odeteTexto("astroSchema", b.id, nome,
              ((q.path || []).join(".") || "?") + ": " + (q.message || String(r.error))));
          }
          data = r.data;
        } finally {
          arquivoDaEntradaAtual = null;
        }
      }
      const e = { id: b.id, collection: nome, data, body: b.body, filePath: b.arquivo ? path.relative(state.root, b.arquivo) : undefined };
      if (b.slug) e.slug = b.slug;
      Object.defineProperty(e, "__odeteArquivo", { value: b.arquivo, enumerable: false });
      entradas.push(e);
    }
    entradasCache.set(nome, entradas);
    defineDeps("astro:@colecao:" + nome, lidos);
    if (pastaVigiada) state.faltando.set("astro:@colecao:" + nome, new Set([pastaVigiada].concat(lidos.map((f) => path.dirname(f)))));
    anuncia();
    return entradas;
  }

  function entradaDeArquivo(f) {
    const txt = fs.readFileSync(f, "utf8");
    if (/\.mdx?$/i.test(f)) {
      const fm = frontmatterDe(txt);
      return { data: fm.dados, body: fm.corpo, arquivo: f };
    }
    if (/\.ya?ml$/i.test(f)) return { data: globalThis.__odeteMarkdown.yaml(txt), body: undefined, arquivo: f };
    if (/\.json$/i.test(f)) return { data: JSON.parse(txt), body: undefined, arquivo: f };
    return { data: {}, body: txt, arquivo: f };
  }

  // `image()` do schema: o caminho da entrada, relativo ao arquivo dela, vira ImageMetadata.
  function imagemDoSchema() {
    const z = moduloZod();
    return z.string().transform((s) => {
      if (/^(https?:)?\/\//.test(s) || s.startsWith("/")) return { src: s, width: 0, height: 0, format: path.extname(s).slice(1) };
      const base = arquivoDaEntradaAtual ? path.dirname(arquivoDaEntradaAtual) : state.root;
      const abs = s.startsWith("~/") || s.startsWith("@/") ? caminhoDoImport(s, base) || path.resolve(base, s) : path.resolve(base, s);
      return imagemDe(abs);
    });
  }

  function moduloContent() {
    const acha = async (colecao, id) => (await entradasDaColecao(colecao)).find((e) => e.id === id || e.slug === id);
    return {
      __esModule: true,
      defineCollection: (c) => c,
      reference: (col) => moduloZod().string().transform((id) => ({ id, collection: col })),
      // Preguiçoso: quem só lê a coleção (sem schema) não precisa do zod instalado.
      get z() { return moduloZod(); },
      getCollection: async (nome, filtro) => {
        const todas = await entradasDaColecao(nome);
        return typeof filtro === "function" ? todas.filter(filtro) : todas.slice();
      },
      getEntry: async (a, b) => (typeof a === "object" && a ? acha(a.collection, a.id || a.slug) : acha(a, b)),
      getEntryBySlug: async (c, s) => acha(c, s),
      getDataEntryById: async (c, id) => acha(c, id),
      getEntries: async (refs) => Promise.all([].concat(refs || []).map((r) => acha(r.collection, r.id || r.slug))),
      getLiveCollection: async () => ({ entries: [] }),
      render: renderDaEntrada,
    };
  }

  // `render(entrada)`: o `Content` que desenha o corpo (markdown ou MDX) e os títulos.
  async function renderDaEntrada(entrada) {
    const f = entrada && entrada.__odeteArquivo;
    if (!f || !/\.mdx?$/i.test(f)) {
      const html = entrada && entrada.rendered && entrada.rendered.html || "";
      return { Content: { render: async () => html }, headings: [], remarkPluginFrontmatter: {} };
    }
    const m = await moduloMarkdown(f);
    return { Content: m.exports.Content, headings: m.headings, remarkPluginFrontmatter: {} };
  }

  // ---- rotas ----
  // As rotas saem de `src/pages`: `.astro`, `.md` e `.mdx` são páginas; `.ts`/`.js` são
  // endpoints (`rss.xml.js` é `/rss.xml`). `[slug]` pega um segmento, `[...resto]` o que
  // sobrar (inclusive nada). Rota literal ganha de dinâmica, que ganha de resto.
  function rotasDoAstro() {
    const base = path.join(state.root, "src", "pages");
    const rotas = [];
    for (const f of arquivosEm(base)) {
      const rel = path.relative(base, f).split(path.sep).join("/");
      if (rel.split("/").some((p) => p.startsWith("_")) || /\.d\.ts$/.test(rel)) continue;
      let tipo = null;
      if (/\.astro$/i.test(rel)) tipo = "astro";
      else if (/\.mdx?$/i.test(rel)) tipo = "md";
      else if (EXT_CODIGO_DE_PAGINA.test(rel)) tipo = "endpoint";
      if (!tipo) continue;
      const semExt = tipo === "endpoint" ? rel.replace(EXT_CODIGO_DE_PAGINA, "") : rel.replace(/\.[^./]+$/, "");
      const partes = semExt.split("/");
      if (partes[partes.length - 1] === "index") partes.pop();
      const segs = partes.map((p) => {
        const resto = /^\[\.\.\.([^\]]+)\]$/.exec(p);
        if (resto) return { tipo: "resto", nome: resto[1], peso: 1 };
        if (/\[[^\]]+\]/.test(p)) {
          const nomes = [];
          const re = new RegExp("^" + p.replace(/[.+^$()|\\]/g, "\\$&").replace(/\[([^\]]+)\]/g, (m, n) => { nomes.push(n); return "([^/]+?)"; }) + "$");
          return { tipo: "um", re, nomes, peso: 2 };
        }
        return { tipo: "literal", valor: p, peso: 3 };
      });
      rotas.push({ arquivo: f, tipo, segs, rel });
    }
    rotas.sort((a, b) => {
      const n = Math.max(a.segs.length, b.segs.length);
      for (let i = 0; i < n; i++) {
        const x = a.segs[i] ? a.segs[i].peso : 0, y = b.segs[i] ? b.segs[i].peso : 0;
        if (x !== y) return y - x;
      }
      return b.segs.length - a.segs.length;
    });
    return rotas;
  }

  function casaSegmentos(segs, partes) {
    const params = {};
    let i = 0;
    for (let k = 0; k < segs.length; k++) {
      const s = segs[k];
      if (s.tipo === "resto") {
        if (k !== segs.length - 1) return null;
        const r = partes.slice(i);
        params[s.nome] = r.length ? r.join("/") : undefined;
        return params;
      }
      if (i >= partes.length) return null;
      if (s.tipo === "literal") { if (s.valor !== partes[i]) return null; }
      else {
        const m = s.re.exec(partes[i]);
        if (!m) return null;
        s.nomes.forEach((n, j) => { params[n] = m[j + 1]; });
      }
      i++;
    }
    return i === partes.length ? params : null;
  }

  function casaRotasDoAstro(p) {
    const base = path.join(state.root, "src", "pages");
    if (!fs.existsSync(base)) return [];
    let partes;
    try { partes = p.split("/").filter(Boolean).map(decodeURIComponent); } catch (e) { partes = p.split("/").filter(Boolean); }
    const out = [];
    for (const r of rotasDoAstro()) {
      const params = casaSegmentos(r.segs, partes);
      if (params) out.push({ rota: r, params });
    }
    return out;
  }

  const ehDinamica = (r) => r.segs.some((s) => s.tipo !== "literal");

  // `getStaticPaths()` decide o que existe numa rota dinâmica e com que props. Sem ele, a
  // rota é "servidor" e os params vêm da URL.
  async function caminhosEstaticos(getStaticPaths, rota) {
    const nomeDoResto = (rota.segs.find((s) => s.tipo === "resto") || {}).nome ||
      ((rota.segs.find((s) => s.tipo === "um") || {}).nomes || [])[0];
    const paginate = (dados, o) => {
      const tam = (o && o.pageSize) || 10;
      const total = dados.length, ultimas = Math.max(1, Math.ceil(total / tam));
      const out = [];
      for (let n = 1; n <= ultimas; n++) {
        const inicio = (n - 1) * tam;
        const params = Object.assign({}, o && o.params, { [nomeDoResto]: n === 1 && rota.segs.some((s) => s.tipo === "resto") ? undefined : String(n) });
        out.push({
          params, props: Object.assign({}, o && o.props, {
            page: {
              data: dados.slice(inicio, inicio + tam), start: inicio, end: Math.min(total, inicio + tam) - 1,
              size: tam, total, currentPage: n, lastPage: ultimas,
              url: { current: "", prev: n > 1 ? String(n - 1) : undefined, next: n < ultimas ? String(n + 1) : undefined, first: undefined, last: undefined },
            },
          }),
        });
      }
      return out;
    };
    const lista = await getStaticPaths({ paginate });
    return [].concat(lista || []).flat();
  }

  function mesmosParams(a, b) {
    const ks = new Set(Object.keys(a || {}).concat(Object.keys(b || {})));
    for (const k of ks) {
      const x = a && a[k], y = b && b[k];
      const nx = x == null || x === "" ? undefined : String(x), ny = y == null || y === "" ? undefined : String(y);
      if (nx !== ny) return false;
    }
    return true;
  }

  // O `Astro` da página: URL, params, props, site, pedido e o registro dos componentes
  // usados (é por ele que a folha da página junta o CSS de cada um).
  function astroDaPagina(req, url, params, props) {
    const cfg = configDoAstro();
    const cabecalhos = req.headers || {};
    const host = cabecalhos.host || "localhost:" + state.port;
    const href = new URL(url.pathname + url.search, "http://" + host);
    let pedido;
    try { pedido = new Request(href.href, { method: req.method || "GET", headers: cabecalhos }); } catch (e) { pedido = { url: href.href, method: req.method, headers: cabecalhos }; }
    const biscoitos = globalThis.__next && globalThis.__next.pedidoNext ? globalThis.__next.pedidoNext(href.href, req.method, cabecalhos).cookies : { get: () => undefined, has: () => false };
    let versao = "5";
    try { versao = JSON.parse(fs.readFileSync(path.join(state.root, "node_modules", "astro", "package.json"), "utf8")).version; } catch (e) { /* sem astro instalado */ }
    return {
      props: props || {}, params: params || {}, url: href, request: pedido,
      site: cfg.site ? new URL(cfg.site) : undefined, generator: "Astro v" + versao,
      redirect: (destino, status) => new Response(null, { status: status || 302, headers: { location: String(destino) } }),
      cookies: { get: (n) => biscoitos.get(n), has: (n) => biscoitos.has(n), set() {}, delete() {} },
      locals: {}, response: { status: 200, statusText: "", headers: new Headers() },
      clientAddress: "127.0.0.1", isPrerendered: false, currentLocale: undefined, preferredLocale: undefined, preferredLocaleList: [],
      glob: async () => [],
      __usados: new Set(),
    };
  }

  // A resposta de uma rota do Astro, ou null quando nenhuma casou.
  async function rotaDoAstro(req, res, p, url, extras) {
    const candidatas = casaRotasDoAstro(p);
    if (!candidatas.length) return null;
    await carregaConfigDoAstro();
    for (const c of candidatas) {
      const r = await tentaRotaDoAstro(c.rota, c.params, req, res, p, url, extras);
      if (r !== null) return r;
    }
    return null;
  }

  async function tentaRotaDoAstro(rota, params, req, res, p, url, extras) {
    if (rota.tipo === "endpoint") return endpointDoAstro(rota, params, req, res, url, extras);
    let props = {};
    if (rota.tipo === "astro" && ehDinamica(rota)) {
      const mod = (await carregaAstro(rota.arquivo)).exports;
      const r = typeof mod.__frente === "function" ? await mod.__frente(null, {}, "paths") : {};
      if (r && typeof r.getStaticPaths === "function") {
        const lista = await caminhosEstaticos(r.getStaticPaths, rota);
        const achado = lista.find((x) => mesmosParams(x && x.params, params));
        if (!achado) return null;
        props = achado.props || {};
        params = Object.assign({}, params, achado.params);
      }
    }
    const astro = astroDaPagina(req, url, params, props);
    let html;
    if (rota.tipo === "md") html = await paginaMarkdown(rota.arquivo, astro);
    else {
      const pagina = await carregaAstro(rota.arquivo);
      astro.__usados.add(rota.arquivo);
      const R = globalThis.__astroRuntime;
      const a = R.filho(astro, props, {}, pagina.exports);
      a.__usados = astro.__usados;
      html = await pagina.exports.render(a, {});
    }
    if (html && typeof html === "object" && typeof html.status === "number") {
      // `return Astro.redirect("/x")` no frontmatter
      const h = [];
      if (html.headers && html.headers.forEach) html.headers.forEach((v, k) => h.push([k, v]));
      return send(res, html.status, "text/plain; charset=utf-8", "", (extras || []).concat(h));
    }
    folhasDoAstro.set(p, [...astro.__usados]);
    const status = /\/404\.(astro|mdx?)$/.test(rota.arquivo) ? 404 : 200;
    return send(res, status, MIME[".html"], documentoDoAstro(String(html == null ? "" : html), p), extras);
  }

  async function paginaMarkdown(arquivo, astro) {
    const m = await moduloMarkdown(arquivo);
    astro.__usados.add(arquivo);
    const conteudo = await m.exports.Content.render(Object.assign({}, astro, { props: {} }), {});
    const layout = m.dados && m.dados.layout;
    if (!layout) return conteudo;
    const abs = caminhoDoImport(layout, path.dirname(arquivo)) || path.resolve(path.dirname(arquivo), layout);
    const L = await carregaAstro(abs);
    astro.__usados.add(abs);
    const props = { frontmatter: m.dados, content: m.dados, headings: m.headings, file: arquivo, url: m.exports.url, rawContent: () => m.corpo };
    return globalThis.__astroRuntime.__comp(L.exports, props, { default: async () => conteudo }, astro);
  }

  // O documento: `<!DOCTYPE>` se a página escreveu `<html>` sem ele, a folha da rota e o
  // cliente do Preview no `<head>`.
  function documentoDoAstro(html, p) {
    const folha = '<link rel="stylesheet" href="/@odete/css/@astro' + encodeURI(p) + '">';
    const cabeca = folha + importMap() + CLIENT;
    let out = html.replace(/^\s+/, "");
    if (/^<html[\s>]/i.test(out)) out = "<!DOCTYPE html>" + out;
    const i = out.search(/<\/head>/i);
    if (i >= 0) return out.slice(0, i) + cabeca + out.slice(i);
    const b = out.search(/<body[\s>]/i);
    if (b >= 0) return out.slice(0, b) + "<head>" + cabeca + "</head>" + out.slice(b);
    return cabeca + out;
  }

  // A folha de uma rota: o CSS importado por cada componente usado, e depois o `<style>`
  // de cada um, na ordem em que apareceram.
  const folhasDoAstro = new Map();
  async function folhaDoAstro(p) {
    const arquivos = folhasDoAstro.get(p) || [];
    const importados = [], proprios = [], vistos = new Set();
    for (const f of arquivos) {
      let m = modAstro.get(f);
      if (!m || m.mt !== (fs.existsSync(f) ? fs.statSync(f).mtimeMs : -1)) {
        try { m = /\.mdx?$/i.test(f) ? await moduloMarkdown(f) : await carregaAstro(f); } catch (e) { continue; }
      }
      if (m.cssImportado && !vistos.has(m.cssImportado)) { vistos.add(m.cssImportado); importados.push(m.cssImportado); }
      if (m.cssProprio) proprios.push(m.cssProprio);
    }
    return importados.concat(proprios).join("\n");
  }

  // Endpoint: `export async function GET({ params, request })` devolve uma Response.
  async function endpointDoAstro(rota, params, req, res, url, extras) {
    const mod = await moduloDeArquivo("astro:" + rota.arquivo, rota.arquivo);
    if (ehDinamica(rota) && typeof mod.getStaticPaths === "function") {
      const lista = await caminhosEstaticos(mod.getStaticPaths, rota);
      if (!lista.find((x) => mesmosParams(x && x.params, params))) return null;
    }
    const metodo = String(req.method || "GET").toUpperCase();
    const fn = mod[metodo] || mod[metodo.toLowerCase()] || mod.ALL || mod.all || (metodo === "HEAD" ? mod.GET : null);
    if (typeof fn !== "function") return send(res, 405, "text/plain; charset=utf-8", "", [["allow", Object.keys(mod).filter((k) => /^[A-Z]+$/.test(k)).join(", ")]]);
    const astro = astroDaPagina(req, url, params, {});
    if (metodo !== "GET" && metodo !== "HEAD") {
      const corpo = await corpoDoPedido(req);
      try { astro.request = new Request(astro.url.href, { method: metodo, headers: req.headers || {}, body: corpo }); } catch (e) { /* fica o de antes */ }
    }
    const r = await fn(astro);
    // Sem `content-type` na resposta, vale a extensão da rota (`rss.xml` é XML), como no
    // Astro. O `Response` do runtime põe `text/plain` sozinho num corpo de texto: esse
    // também cede à extensão.
    const pelaExtensao = Object.assign({}, MIME, {
      ".xml": "application/xml; charset=utf-8", ".rss": "application/rss+xml; charset=utf-8",
      ".webmanifest": "application/manifest+json", ".ics": "text/calendar; charset=utf-8",
    })[path.extname(url.pathname).toLowerCase()];
    if (r == null) return send(res, 204, "text/plain; charset=utf-8", "", extras);
    if (typeof r === "string") return send(res, 200, pelaExtensao || "text/plain; charset=utf-8", r, extras);
    const h = { "cache-control": "no-store" };
    if (r.headers && typeof r.headers.forEach === "function") r.headers.forEach((v, k) => { h[k] = v; });
    if (pelaExtensao && (!h["content-type"] || /^text\/plain;\s*charset=utf-8$/i.test(h["content-type"]))) h["content-type"] = pelaExtensao;
    if (!h["content-type"]) h["content-type"] = "text/plain; charset=utf-8";
    if (extras) for (const [k, v] of extras) h[k] = v;
    let corpo = "";
    if (typeof r.arrayBuffer === "function") corpo = Buffer.from(new Uint8Array(await r.arrayBuffer()));
    else if (r.body != null) corpo = String(r.body);
    res.writeHead(r.status || 200, h);
    return res.end(corpo);
  }

  // Depois de uma mudança no grafo de um .astro (ou de uma coleção, ou do config). Um
  // .astro é recompilado já: se só o CSS (o `<style>` dele ou uma folha importada) mudou,
  // a página fica e a folha troca.
  async function refazAstro(chave, soEstilo) {
    if (chave.startsWith("@colecao:")) { entradasCache.delete(chave.slice(9)); return { js: true, css: false, refeito: false }; }
    if (chave === "@colecoes") { colecoesCache = null; entradasCache.clear(); return { js: true, css: false, refeito: false }; }
    if (chave === "@config") {
      configCache = null; definesAstroCache = null; modAstro.clear(); colecoesCache = null; entradasCache.clear();
      return { js: true, css: false, refeito: false };
    }
    const antes = modAstro.get(chave);
    modAstro.delete(chave);
    if (/\.(ts|js|mjs|mts|cjs)$/i.test(chave) || !antes || !fs.existsSync(chave)) return { js: true, css: false, refeito: false };
    try {
      const depois = /\.mdx?$/i.test(chave) ? await moduloMarkdown(chave) : await carregaAstro(chave);
      return { js: depois.jsHash !== antes.jsHash, css: depois.css !== antes.css, refeito: true };
    } catch (e) {
      return { js: true, css: false, refeito: true };
    }
  }

  // Um arquivo do projeto pelo endereço (imagens e fontes importadas, que não estão em public/).
  function enviaArquivoDoProjeto(res, p) {
    let rel;
    try { rel = decodeURIComponent(p.slice("/@odete/arquivo/".length)); } catch (e) { rel = p.slice("/@odete/arquivo/".length); }
    const f = path.join(state.root, rel);
    if (!f.startsWith(state.root + "/") || !fs.existsSync(f) || !fs.statSync(f).isFile()) {
      return send(res, 404, "text/plain; charset=utf-8", "não encontrado: " + rel);
    }
    registraLido("est:" + f, f);
    return send(res, 200, MIME[path.extname(f).toLowerCase()] || "application/octet-stream", fs.readFileSync(f));
  }

  // Um erro no Astro vira uma página que diz onde foi, em vez do texto cru.
  function paginaDeErroDoAstro(e) {
    const msg = String((e && e.message) || e);
    const pilha = String((e && e.stack) || "").split("\n").slice(0, 8).join("\n");
    const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
    return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Erro</title>" + CLIENT +
      "</head><body style=\"margin:0;background:#111;color:#eee;font:14px ui-monospace,monospace\"><pre style=\"white-space:pre-wrap;padding:16px;color:#e25d5d\">" +
      esc(msg) + "</pre><pre style=\"white-space:pre-wrap;padding:0 16px;color:#999\">" + esc(pilha) + "</pre></body></html>";
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
    // O `vite preview` de um build com `base: "/repo/"`: o index.html pede
    // /repo/assets/…, e o arquivo está em dist/assets/. Sem o prefixo também serve — o
    // Preview abre na raiz.
    if (state.base !== "/" && (p + "/").startsWith(state.base)) p = "/" + p.slice(state.base.length);
    try {
      if (p.startsWith("/@odete/js/")) { const b = await bundle(p.slice(11)); return send(res, 200, MIME[".js"], b.js); }
      // As folhas das páginas do Next e do Astro moram sob /@odete/css/ também: é o que o
      // cliente do Preview troca sozinho quando só o CSS mudou.
      if (p.startsWith("/@odete/css/@next/") || p === "/@odete/css/@next") {
        return send(res, 200, MIME[".css"], await folhaDaRota(p.slice("/@odete/css/@next".length) || "/"));
      }
      if (p.startsWith("/@odete/css/@astro/")) {
        return send(res, 200, MIME[".css"], await folhaDoAstro(p.slice("/@odete/css/@astro".length)));
      }
      if (p.startsWith("/@odete/arquivo/")) return enviaArquivoDoProjeto(res, p);
      if (p.startsWith("/@odete/css/")) { const b = await bundle(p.slice(12)); return send(res, 200, MIME[".css"], b.css); }
      if (p === "/@odete/deps.js" || p === "/@odete/deps.css") return await enviaDeps(req, res, p, url);
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

      // Os ícones de convenção do App Router (`app/favicon.ico`, `app/icon.png`) são
      // servidos na raiz do site, como o Next faz.
      if (globalThis.__next && ehProjetoNext() && globalThis.__next.ehIconeDoApp(p.slice(1))) {
        const f = path.join(state.root, "app", p.slice(1));
        if (!fs.existsSync(path.join(state.root, "public", p.slice(1))) && fs.existsSync(f)) {
          registraLido("est:" + f, f);
          return send(res, 200, MIME[path.extname(f).toLowerCase()] || "application/octet-stream", fs.readFileSync(f), extras);
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
      const astro = ehProjetoAstro();
      if (astro) {
        try {
          const r = await rotaDoAstro(req, res, p, url, extras);
          if (r !== null) return r;
        } catch (e) {
          return send(res, 500, MIME[".html"], paginaDeErroDoAstro(e), extras);
        }
      }
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
          // O pedido que a página vai ler: `usePathname`, `useSearchParams`, `useParams`,
          // `headers()` e `cookies()` respondem com ele.
          globalThis.__next.defineRequisicao({
            pathname: p, search: url.search, params: rotaNext.params || {}, headers: req.headers || {},
          });

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
      // O 404 do projeto Astro é a página `src/pages/404.astro`, se houver.
      if (astro && !p.startsWith("/@odete/")) {
        const nf = casaRotasDoAstro("/404").find((c) => /\/404\.(astro|mdx?)$/.test(c.rota.arquivo));
        if (nf) {
          try {
            const r = await tentaRotaDoAstro(nf.rota, {}, req, res, p, url, extras);
            if (r !== null) return r;
          } catch (e) { /* cai no recado */ }
        }
      }
      send(res, 404, "text/plain; charset=utf-8", recado404(p));
    } catch (e) {
      send(res, 500, "text/plain; charset=utf-8", String((e && e.message) || e) + "\n\n" + String((e && e.stack) || ""));
    }
  }

  function inicia(id, root, port, preset, base) {
    return new Promise((resolve, reject) => {
      state.id = id; state.root = root; state.preset = preset || "plain"; state.base = base || "/";
      state.pre.deps = globalThis.__depsCria(root, "dev" + id + ":");
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
    estatisticas: () => Object.assign(
      { contextos: globalThis.__contextosVivos(), sockets: state.sockets.size, preEmpacota: state.pre.ligado ? 1 : 0 },
      state.stats, state.pre.deps ? state.pre.deps.estatisticas() : {},
    ),
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

  globalThis.__devStart = async (root, port, preset, base) => {
    const id = (globalThis.__devProximoId = (globalThis.__devProximoId || 0) + 1);
    const s = globalThis.__devCria();
    servidores.set(id, s);
    try {
      const r = await s.inicia(id, root, port, preset, base);
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
