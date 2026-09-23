// Rotas e render de projetos Next, no aparelho.
//
// O Next roda um servidor Node que a Odete não tem. O que ela tem é o mesmo React e o
// mesmo `require` que resolve `node_modules` e transpila TSX — então a página é
// executada aqui e devolvida como HTML.
//
// Componente de servidor é função `async`. Quem espera cada um é o renderizador de
// streaming do próprio React (`renderToPipeableStream`, lido só quando tudo ficou pronto):
// ele executa a árvore inteira, síncronos e async misturados, como o Next faz.
(function (raiz) {
  "use strict";

  const EXT = [".tsx", ".jsx", ".ts", ".js", ".mjs"];

  function achaArquivo(fs, path, base, nome) {
    for (const e of EXT) {
      const f = path.join(base, nome + e);
      if (fs.existsSync(f) && fs.statSync(f).isFile()) return f;
    }
    return null;
  }

  function ehPasta(fs, f) {
    try { return fs.statSync(f).isDirectory(); } catch (e) { return false; }
  }

  function pastasEm(fs, dir) {
    try { return fs.readdirSync(dir); } catch (e) { return []; }
  }

  // Pastas do App Router que não são segmento de URL:
  //   `(loja)` agrupa sem aparecer no caminho
  //   `[id]` pega um segmento, `[...resto]` pega o que sobrar, `[[...resto]]` pode não pegar nada
  //   `@slot` é paralelo, e o que a Odete faz com ele é ignorar
  function classifica(nome) {
    if (/^\(.+\)$/.test(nome)) return { tipo: "grupo" };
    let m = /^\[\[\.\.\.(.+)\]\]$/.exec(nome);
    if (m) return { tipo: "resto", nome: m[1], opcional: true };
    m = /^\[\.\.\.(.+)\]$/.exec(nome);
    if (m) return { tipo: "resto", nome: m[1], opcional: false };
    m = /^\[(.+)\]$/.exec(nome);
    if (m) return { tipo: "um", nome: m[1] };
    return { tipo: "literal" };
  }

  function dinamicosEm(fs, path, dir) {
    const out = { grupos: [], um: [], resto: [] };
    for (const nome of pastasEm(fs, dir)) {
      if (!ehPasta(fs, path.join(dir, nome))) continue;
      const c = classifica(nome);
      if (c.tipo === "grupo") out.grupos.push(nome);
      else if (c.tipo === "um") out.um.push({ pasta: nome, nome: c.nome });
      else if (c.tipo === "resto") out.resto.push({ pasta: nome, nome: c.nome, opcional: c.opcional });
    }
    return out;
  }

  // Caminha a árvore casando segmento a segmento, literal antes de dinâmico — que é a
  // ordem de precedência do Next. Vai acumulando os layouts de fora para dentro e os
  // parâmetros que os segmentos dinâmicos capturaram.
  function achaNaArvore(fs, path, dir, partes, camadas, params, alvo) {
    // `template` embrulha como o layout, por dentro dele: para a Odete, que remonta a
    // página a cada pedido, os dois são a mesma coisa.
    const meu = achaArquivo(fs, path, dir, "layout");
    const molde = alvo === "page" ? achaArquivo(fs, path, dir, "template") : null;
    const cam = camadas.concat(meu ? [meu] : [], molde ? [molde] : []);
    const dins = dinamicosEm(fs, path, dir);

    if (!partes.length) {
      const f = achaArquivo(fs, path, dir, alvo);
      if (f) return { arquivo: f, layouts: cam, params, pasta: dir };
      for (const g of dins.grupos) {
        const r = achaNaArvore(fs, path, path.join(dir, g), [], cam, params, alvo);
        if (r) return r;
      }
      for (const d of dins.resto) {
        if (!d.opcional) continue;
        const r = achaNaArvore(fs, path, path.join(dir, d.pasta), [], cam, assign(params, d.nome, []), alvo);
        if (r) return r;
      }
      return null;
    }

    const cabeca = partes[0], resto = partes.slice(1);
    const literal = path.join(dir, cabeca);
    if (ehPasta(fs, literal) && classifica(cabeca).tipo === "literal") {
      const r = achaNaArvore(fs, path, literal, resto, cam, params, alvo);
      if (r) return r;
    }
    for (const g of dins.grupos) {
      const r = achaNaArvore(fs, path, path.join(dir, g), partes, cam, params, alvo);
      if (r) return r;
    }
    for (const d of dins.um) {
      const r = achaNaArvore(fs, path, path.join(dir, d.pasta), resto, cam, assign(params, d.nome, cabeca), alvo);
      if (r) return r;
    }
    for (const d of dins.resto) {
      const r = achaNaArvore(fs, path, path.join(dir, d.pasta), [], cam, assign(params, d.nome, partes), alvo);
      if (r) return r;
    }
    return null;
  }

  function assign(o, k, v) {
    const novo = {};
    for (const x of Object.keys(o)) novo[x] = o[x];
    novo[k] = v;
    return novo;
  }

  // App Router: `app/page.tsx` é `/`, `app/blog/page.tsx` é `/blog`, `app/blog/[slug]`
  // é qualquer coisa abaixo de /blog, e cada nível pode ter um `layout` que embrulha o
  // de dentro. `app/api/x/route.ts` não é página: é função por método HTTP.
  function rotaDoApp(fs, path, root, p, alvo) {
    const base = path.join(root, "app");
    if (!ehPasta(fs, base)) return null;
    const r = achaNaArvore(fs, path, base, p.split("/").filter(Boolean), [], {}, alvo || "page");
    if (!r) return null;
    return {
      tipo: alvo === "route" ? "handler" : "app",
      pagina: r.arquivo, layouts: r.layouts, params: r.params, pasta: r.pasta,
      carregando: alvo === "route" ? null : carregandoAte(fs, path, base, r.pasta),
      icones: iconesDoApp(fs, path, base),
    };
  }

  // `loading.tsx` vale do segmento para dentro: o mais perto da página, subindo até app/.
  function carregandoAte(fs, path, base, pasta) {
    for (let dir = pasta; dir && dir.startsWith(base); dir = path.dirname(dir)) {
      const f = achaArquivo(fs, path, dir, "loading");
      if (f) return f;
      if (dir === base) break;
    }
    return null;
  }

  // Os ícones por convenção de arquivo (`app/favicon.ico`, `app/icon.png`): o Next os
  // serve na raiz do site e põe o <link> no <head> sozinho.
  const ICONES = ["favicon.ico", "icon.ico", "icon.png", "icon.svg", "icon.jpg", "apple-icon.png", "apple-icon.jpg"];
  function iconesDoApp(fs, path, base) {
    const out = [];
    for (const n of ICONES) {
      try { if (fs.statSync(path.join(base, n)).isFile()) out.push(n); } catch (e) { /* não tem */ }
    }
    return out;
  }
  function ehIconeDoApp(nome) { return ICONES.indexOf(nome) >= 0; }

  // Pages Router: `pages/index.tsx` é `/`, `pages/sobre.tsx` é `/sobre`,
  // `pages/post/[id].tsx` casa /post/o-que-for, e `_app` embrulha.
  function rotaDasPages(fs, path, root, p) {
    const base = path.join(root, "pages");
    if (!ehPasta(fs, base)) return null;
    const partes = p.split("/").filter(Boolean);
    const achado = procuraPages(fs, path, base, partes, {});
    if (!achado) return null;
    const app = achaArquivo(fs, path, base, "_app");
    return { tipo: "pages", pagina: achado.arquivo, layouts: app ? [app] : [], params: achado.params };
  }

  function procuraPages(fs, path, dir, partes, params) {
    if (!partes.length) {
      const f = achaArquivo(fs, path, dir, "index");
      return f ? { arquivo: f, params } : null;
    }
    const cabeca = partes[0], resto = partes.slice(1);
    if (!resto.length) {
      const f = achaArquivo(fs, path, dir, cabeca);
      if (f) return { arquivo: f, params };
    }
    const sub = path.join(dir, cabeca);
    if (ehPasta(fs, sub)) {
      const r = procuraPages(fs, path, sub, resto, params);
      if (r) return r;
    }
    // dinâmicos: pasta [id]/ ou arquivo [id].tsx
    for (const nome of pastasEm(fs, dir)) {
      const c = classifica(nome.replace(/\.(tsx|jsx|ts|js|mjs)$/, ""));
      if (c.tipo === "literal" || c.tipo === "grupo") continue;
      const cheio = path.join(dir, nome);
      if (ehPasta(fs, cheio)) {
        const p2 = c.tipo === "resto" ? assign(params, c.nome, partes) : assign(params, c.nome, cabeca);
        const r = procuraPages(fs, path, cheio, c.tipo === "resto" ? [] : resto, p2);
        if (r) return r;
      } else if (!resto.length || c.tipo === "resto") {
        const p2 = c.tipo === "resto" ? assign(params, c.nome, partes) : assign(params, c.nome, cabeca);
        return { arquivo: cheio, params: p2 };
      }
    }
    return null;
  }

  function rota(fs, path, root, p) {
    return rotaDoApp(fs, path, root, p, "route") ||
      rotaDoApp(fs, path, root, p, "page") ||
      rotaDasPages(fs, path, root, p);
  }

  // `not-found.tsx` e `error.tsx` valem do segmento para dentro; quando a página falha,
  // sobe-se procurando o mais próximo.
  function especial(fs, path, root, p, nome) {
    const base = path.join(root, "app");
    if (!ehPasta(fs, base)) return null;
    const partes = p.split("/").filter(Boolean);
    for (let i = partes.length; i >= 0; i--) {
      const dir = path.join(base, ...partes.slice(0, i));
      if (!dir.startsWith(base)) continue;
      const f = achaArquivo(fs, path, dir, nome);
      if (f) return { tipo: "app", pagina: f, layouts: i === 0 ? layoutsAte(fs, path, base, []) : layoutsAte(fs, path, base, partes.slice(0, i)), params: {}, icones: iconesDoApp(fs, path, base) };
    }
    return null;
  }

  function layoutsAte(fs, path, base, partes) {
    const out = [];
    let dir = base;
    const l0 = achaArquivo(fs, path, dir, "layout");
    if (l0) out.push(l0);
    for (const parte of partes) {
      dir = path.join(dir, parte);
      if (!ehPasta(fs, dir)) break;
      const l = achaArquivo(fs, path, dir, "layout");
      if (l) out.push(l);
    }
    return out;
  }

  // ---- render ----
  // Componente de servidor é função async, e o `renderToString` não espera promessa: uma
  // página síncrona com um filho async dava "A component suspended while responding to
  // synchronous input". O renderizador de streaming espera — e `onAllReady` só chama
  // quando a árvore inteira resolveu, então o HTML sai de uma vez, com cada fronteira de
  // Suspense já no lugar, sem os scripts de troca que o streaming mandaria aos pedaços.
  function renderizaTudo(servidor, el) {
    return new Promise((resolve, reject) => {
      const partes = [];
      let erro = null;
      const destino = {
        write(c) { partes.push(typeof c === "string" ? Buffer.from(c, "utf8") : Buffer.from(c)); return true; },
        end() { if (erro) reject(erro); else resolve(Buffer.concat(partes).toString("utf8")); },
        on() { return destino; }, once() { return destino; }, off() { return destino; },
        removeListener() { return destino; }, emit() { return true; }, destroy() {},
      };
      let fluxo = null;
      try {
        fluxo = servidor.renderToPipeableStream(el, {
          onAllReady() { fluxo.pipe(destino); },
          onShellError(e) { reject(erro || e); },
          // `redirect()`, `notFound()` e o erro de um componente dentro de uma fronteira
          // de Suspense não derrubam o shell: o React os entrega aqui e segue com o
          // fallback. O primeiro fica guardado e quem chama recebe o erro, como recebia do
          // `renderToString` — é ele que decide entre 307, not-found e error.
          onError(e) { if (!erro) erro = e; },
        });
      } catch (e) {
        reject(e);
      }
    });
  }

  // `coletadas` recebe os ids das ilhas que a página usou.
  async function renderiza(ctx, rota, url, coletadas) {
    const { React, servidor } = ctx;
    // Layouts, loading e página vêm num pacote só (devserver.js, `carregaRota`): o que eles
    // importam em comum é o mesmo módulo para todos.
    const lista = rota.layouts.concat(rota.carregando ? [rota.carregando] : [], [rota.pagina]);
    const mods = ctx.carregaRota ? await ctx.carregaRota(lista) : await Promise.all(lista.map((f) => ctx.carrega(f)));
    const modDe = new Map(lista.map((f, i) => [f, mods[i]]));
    const req = async (f) => modDe.get(f) || (await ctx.carrega(f));
    const pagina = await req(rota.pagina);
    const Page = pagina.default || pagina;
    if (typeof Page !== "function") throw new Error(rota.pagina + " não exporta um componente");

    const busca = {};
    if (url && url.searchParams) {
      for (const [k, v] of url.searchParams) {
        busca[k] = Object.prototype.hasOwnProperty.call(busca, k) ? [].concat(busca[k], v) : v;
      }
    }
    // No Next 15 `params` e `searchParams` são promessas. Um objeto comum atende os
    // dois jeitos: `await params` devolve o próprio objeto, e `params.id` também lê.
    const params = rota.params || {};
    let props = rota.tipo === "pages" ? {} : { params, searchParams: busca };
    // `error.tsx` não recebe params: recebe o erro e o botão de tentar de novo.
    if (rota.props) props = Object.assign({}, props, rota.props);
    let el = React.createElement(Page, props);
    // `loading.tsx` é o fallback de uma fronteira de Suspense em volta da página. Aqui a
    // página só sai quando tudo resolveu, então ele não aparece — mas a fronteira fica,
    // igual à do Next, e um erro lá dentro cai no mesmo lugar.
    if (rota.carregando) {
      const m = await req(rota.carregando);
      const L = m.default || m;
      if (typeof L === "function") el = React.createElement(React.Suspense, { fallback: React.createElement(L, {}) }, el);
    }

    const metas = [];
    // layouts de fora para dentro: o primeiro da lista é o mais externo
    for (let i = rota.layouts.length - 1; i >= 0; i--) {
      const m = await req(rota.layouts[i]);
      metas.unshift(m);
      const L = m.default || m;
      if (typeof L !== "function") continue;
      el = rota.tipo === "pages"
        ? React.createElement(L, { Component: Page, pageProps: props })
        : React.createElement(L, { params, children: el });
      if (rota.tipo === "pages") break; // _app já recebe a página inteira
    }
    metas.push(pagina);

    contextoDentro(React);
    el = React.createElement(raiz.__odeteColeta.Provider, { value: coletadas || null }, el);
    const corpo = await renderizaTudo(servidor, el);
    return {
      corpo,
      cabeca: await cabecaDeMetadata(metas, props, rota.icones || []),
      // O layout raiz do App Router escreve `<html>` e `<body>`; o React então devolve o
      // documento inteiro, e o que é da Odete entra no `<head>` dele.
      documento: /^\s*(<!doctype html>|<html[\s>])/i.test(corpo),
    };
  }

  // `metadata` (objeto) e `generateMetadata` (função) de cada camada, do layout de fora
  // para a página; o de dentro ganha. `title.template` de um layout vale para os títulos
  // dos segmentos de dentro, e `title.absolute` escapa dele.
  async function cabecaDeMetadata(modulos, props, icones) {
    let junto = {}, titulo = null, molde = null, viewport = null;
    let pai = Promise.resolve({});
    for (const m of modulos) {
      if (!m) continue;
      let meta = null;
      if (typeof m.generateMetadata === "function") meta = await m.generateMetadata(props, pai);
      else if (m.metadata && typeof m.metadata === "object") meta = m.metadata;
      if (typeof m.generateViewport === "function") viewport = Object.assign({}, viewport, await m.generateViewport(props));
      else if (m.viewport && typeof m.viewport === "object") viewport = Object.assign({}, viewport, m.viewport);
      if (!meta) continue;
      let proximoMolde = molde;
      const t = meta.title;
      if (typeof t === "string") titulo = molde ? molde.replace(/%s/g, t) : t;
      else if (t && typeof t === "object") {
        if (t.absolute) titulo = t.absolute;
        else if (t.default) titulo = t.default;
        if (t.template) proximoMolde = t.template;
      }
      molde = proximoMolde;
      for (const k of Object.keys(meta)) if (k !== "title") junto[k] = meta[k];
      pai = Promise.resolve(Object.assign({}, junto, { title: titulo }));
    }
    const partes = ['<meta charset="utf-8">'];
    const esc = (v) => String(v).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");
    const meta = (nome, v, prop) => {
      if (v == null || v === "") return;
      partes.push("<meta " + (prop ? "property" : "name") + '="' + nome + '" content="' + esc(v) + '">');
    };
    const vp = Object.assign({ width: "device-width", initialScale: 1 }, viewport || {});
    const vpTexto = Object.keys(vp)
      .filter((k) => k !== "themeColor" && k !== "colorScheme" && vp[k] != null)
      .map((k) => k.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase()) + "=" + (typeof vp[k] === "boolean" ? (vp[k] ? "yes" : "no") : vp[k]))
      .join(", ");
    meta("viewport", vpTexto);
    if (typeof vp.themeColor === "string") meta("theme-color", vp.themeColor);
    if (vp.colorScheme) meta("color-scheme", vp.colorScheme);
    if (titulo) partes.push("<title>" + esc(titulo) + "</title>");
    meta("description", junto.description);
    if (junto.keywords) meta("keywords", [].concat(junto.keywords).join(", "));
    if (junto.applicationName) meta("application-name", junto.applicationName);
    if (junto.generator) meta("generator", junto.generator);
    if (junto.robots) meta("robots", typeof junto.robots === "string" ? junto.robots :
      [junto.robots.index === false ? "noindex" : "index", junto.robots.follow === false ? "nofollow" : "follow"].join(", "));
    if (junto.alternates && junto.alternates.canonical) {
      partes.push('<link rel="canonical" href="' + esc(junto.alternates.canonical) + '">');
    }
    const og = junto.openGraph;
    if (og) {
      meta("og:title", og.title || titulo, true);
      meta("og:description", og.description || junto.description, true);
      meta("og:url", og.url, true);
      meta("og:site_name", og.siteName, true);
      meta("og:type", og.type, true);
      for (const i of [].concat(og.images || [])) meta("og:image", typeof i === "string" ? i : i && (i.url || i.src), true);
    }
    const tw = junto.twitter;
    if (tw) {
      meta("twitter:card", tw.card);
      meta("twitter:title", tw.title);
      meta("twitter:description", tw.description);
      for (const i of [].concat(tw.images || [])) meta("twitter:image", typeof i === "string" ? i : i && i.url);
    }
    // Ícones: os de `metadata.icons`, e na falta deles os arquivos de convenção de app/.
    const ic = junto.icons;
    if (ic) {
      const lista = typeof ic === "string" || Array.isArray(ic) ? { icon: ic } : ic;
      for (const rel of ["icon", "shortcut", "apple"]) {
        for (const i of [].concat(lista[rel] || [])) {
          const href = typeof i === "string" ? i : i && i.url;
          if (href) partes.push('<link rel="' + (rel === "apple" ? "apple-touch-icon" : rel === "shortcut" ? "shortcut icon" : "icon") + '" href="' + esc(href) + '">');
        }
      }
    } else {
      for (const n of icones) {
        partes.push(n.startsWith("apple-icon")
          ? '<link rel="apple-touch-icon" href="/' + n + '">'
          : '<link rel="icon" href="/' + n + '"' + (n === "favicon.ico" ? ' sizes="any"' : "") + ">");
      }
    }
    if (junto.manifest) partes.push('<link rel="manifest" href="' + esc(junto.manifest) + '">');
    return partes.join("");
  }

  // Route Handler: `app/api/x/route.ts` exporta uma função por método. O que ela
  // devolve é uma Response — a do `next/server` ou uma feita à mão com status e corpo.
  async function rodaHandler(ctx, rota, pedido) {
    const mod = await ctx.carrega(rota.pagina);
    const fn = mod[pedido.method] || mod[pedido.method.toUpperCase()];
    if (typeof fn !== "function") {
      return { status: 405, cabecalhos: [["allow", Object.keys(mod).filter((k) => /^[A-Z]+$/.test(k)).join(", ")]], corpo: "" };
    }
    const r = await fn(pedido, { params: rota.params || {} });
    if (r == null) return { status: 204, cabecalhos: [], corpo: "" };
    if (typeof r === "string") return { status: 200, cabecalhos: [["content-type", "text/plain; charset=utf-8"]], corpo: r };
    const lido = leResposta(r);
    if (lido) return { status: lido.status, cabecalhos: lido.cabecalhos.concat(lido.biscoitos.map((c) => ["set-cookie", c])), corpo: lido.corpo || "" };
    return { status: 200, cabecalhos: [["content-type", "application/json; charset=utf-8"]], corpo: JSON.stringify(r) };
  }

  // ---- ilhas ----
  // Um componente de cliente renderiza normalmente no servidor, mas embrulhado numa
  // marca que carrega o módulo e as props. O navegador acha essas marcas e hidrata só
  // elas — o resto da página é HTML e continua sendo HTML.
  //
  // Filhos que vêm do servidor (`<Providers>{children}</Providers>`) não atravessam JSON:
  // são árvore de componentes de servidor. O que atravessa é o HTML deles — renderizado
  // aqui dentro de `<odete-filhos>`, e no navegador devolvido ao componente como um nó
  // que mostra esse HTML (ilhas-cliente.js). É o papel do payload de RSC, feito com o
  // que já está na página. O mesmo vale para qualquer prop que seja elemento.
  //
  // Um componente de cliente dentro de outro não é ilha: no navegador o de fora já o
  // renderiza. O contexto `Dentro` diz se estamos dentro de uma ilha; os filhos que
  // voltam para o servidor saem dele.
  //
  // Quem anota as ilhas usadas é outro contexto, com o conjunto do pedido: o módulo da
  // página fica em cache e seu embrulho é criado uma vez só, e dois pedidos podem estar
  // renderizando ao mesmo tempo — um conjunto preso no embrulho seria o do primeiro.
  function contextoDentro(React) {
    if (!raiz.__odeteDentro || raiz.__odeteDentroDe !== React) {
      raiz.__odeteDentro = React.createContext(false);
      raiz.__odeteColeta = React.createContext(null);
      raiz.__odeteDentroDe = React;
    }
    return raiz.__odeteDentro;
  }

  function temElemento(React, v, fundo) {
    if (React.isValidElement(v)) return true;
    if (Array.isArray(v) && (fundo || 0) < 8) return v.some((x) => temElemento(React, x, (fundo || 0) + 1));
    return false;
  }

  // As props como vão para o navegador. Data, Server Action e erro ganham uma marca que o
  // navegador desfaz; elemento vira slot. O que não tem volta (uma função comum, um
  // ciclo) torna a ilha estática — melhor do que hidratar com a prop faltando.
  function serializaProps(React, props) {
    const slots = {};
    let ok = true;
    const vistos = [];
    const conv = (v, slot) => {
      if (v === undefined) return undefined;
      if (v === null || typeof v === "string" || typeof v === "number" || typeof v === "boolean") return v;
      if (typeof v === "function") {
        if (typeof v.$$id === "string") return { $odeteAcao: v.$$id, ligados: v.$$ligados || [] };
        ok = false;
        return null;
      }
      if (typeof v !== "object") { ok = false; return null; }
      if (v instanceof Date) return { $odeteData: isNaN(v) ? null : v.toISOString() };
      if (v instanceof Error) return { $odeteErro: { message: String(v.message), name: v.name, digest: v.digest } };
      if (temElemento(React, v)) {
        if (slot) { slots[slot] = v; return { $odeteSlot: slot }; }
        ok = false;
        return null;
      }
      if (vistos.indexOf(v) >= 0) { ok = false; return null; }
      vistos.push(v);
      let out;
      if (Array.isArray(v)) out = v.map((x) => { const r = conv(x); return r === undefined ? null : r; });
      else {
        out = {};
        for (const k of Object.keys(v)) { const r = conv(v[k]); if (r !== undefined) out[k] = r; }
      }
      vistos.pop();
      return out;
    };
    const dados = {};
    for (const k of Object.keys(props || {})) {
      if (k === "ref" || k === "key") continue;
      const r = conv(props[k], k);
      if (r !== undefined) dados[k] = r;
    }
    let json = null;
    if (ok) { try { json = JSON.stringify(dados); } catch (e) { json = null; } }
    return { json, slots };
  }

  function instalaIlhas(React) {
    const Dentro = contextoDentro(React);
    const Coleta = raiz.__odeteColeta;
    const h = React.createElement;
    raiz.__odeteIlha = function (modulo, exportado, Componente) {
      const ehComponente = typeof Componente === "function" ||
        (Componente && typeof Componente === "object" && Componente.$$typeof);
      // Um módulo "use client" também exporta hooks e utilitários (`useCarrinho`,
      // `formata`). Embrulhados, deixariam de funcionar como funções: só vira ilha o que
      // tem nome de componente.
      if (!ehComponente || (exportado !== "default" && !/^[A-Z]/.test(exportado))) return Componente;
      const Ilha = function (props) {
        const dentro = React.useContext(Dentro);
        const coletadas = React.useContext(Coleta);
        if (dentro) return h(Componente, props);
        const id = modulo + "#" + exportado;
        if (coletadas) coletadas.add(id);
        const s = serializaProps(React, props || {});
        const reais = Object.assign({}, props);
        for (const nome of Object.keys(s.slots)) {
          reais[nome] = h(Dentro.Provider, { value: false }, h("odete-filhos", { "data-slot": nome }, s.slots[nome]));
        }
        return h(
          "odete-ilha",
          s.json !== null ? { "data-ilha": id, "data-props": s.json } : { "data-ilha": id, "data-estatica": "1" },
          h(Dentro.Provider, { value: true }, h(Componente, reais))
        );
      };
      Ilha.displayName = "Ilha(" + exportado + ")";
      return Ilha;
    };
  }


  // ---- next/font e os outros substitutos de `next/*` ----
  // A fonte é criada no topo do módulo, quando a rota carrega, e não a cada render. O
  // registro é do processo, e o <head> das páginas do projeto leva o que estiver
  // registrado — um pouco mais do que o Next mandaria em cada rota, e muito menos do
  // que não ter fonte nenhuma.
  //
  // Link, Image, fontes, dynamic e os hooks de navegação vêm da fábrica de
  // next-cliente.js, a mesma que o navegador recebe: o que o servidor escreve é o que a
  // hidratação espera encontrar.
  const fontes = { links: new Map(), regras: new Map() };
  const registroDeFontes = {
    link: (familia, url) => fontes.links.set(familia, url),
    regra: (classe, css) => fontes.regras.set(classe, css),
    arquivo: (caminho) => (typeof raiz.__odeteArquivoDeFonte === "function" ? raiz.__odeteArquivoDeFonte(caminho) : null),
  };

  // O pedido que está sendo renderizado: é o que `usePathname`, `useSearchParams`,
  // `headers()` e `cookies()` leem no servidor.
  let requisicao = { pathname: "/", search: "", params: {}, headers: {} };
  function defineRequisicao(r) {
    requisicao = Object.assign({ pathname: "/", search: "", params: {}, headers: {} }, r || {});
    acoes.rota = requisicao.pathname;
  }

  let fabrica = null;
  function daFabrica(React) {
    if (!fabrica || fabrica.React !== React) {
      if (typeof raiz.__odeteNextFabrica !== "function") throw new Error("next-cliente.js não foi carregado");
      fabrica = { React, m: raiz.__odeteNextFabrica(React, null, "servidor", () => requisicao) };
      fabrica.fontes = fabrica.m.fontes(registroDeFontes);
    }
    return fabrica;
  }

  function moduloFonteGoogle(React) { return daFabrica(React).fontes.moduloGoogle; }
  function moduloFonteLocal(React) { return { __esModule: true, default: daFabrica(React).fontes.local }; }

  function cabecalhoDeFontes() {
    let s = "";
    for (const u of fontes.links.values()) s += '<link rel="stylesheet" href="' + u.replace(/&/g, "&amp;") + '">';
    const css = [...fontes.regras.values()].join("");
    if (css) s += "<style>" + css + "</style>";
    return s;
  }

  // `next/headers`: no Next 15 `headers()` e `cookies()` são promessas, antes eram
  // síncronos. Um objeto comum atende os dois — `await` de um valor devolve o valor.
  function moduloHeaders() {
    return {
      __esModule: true,
      headers: () => new Cabecalhos(requisicao.headers || {}),
      cookies: () => {
        const b = biscoitosDoPedido((requisicao.headers || {}).cookie);
        return Object.assign(b, { set() { return b; }, delete() { return b; }, toString: () => (requisicao.headers || {}).cookie || "" });
      },
      draftMode: () => ({ isEnabled: false, enable() {}, disable() {} }),
    };
  }

  // O módulo que o `require` da página recebe no lugar de `next/<nome>`.
  function substituto(spec, React) {
    const nome = spec.slice("next/".length);
    if (nome === "server") return moduloNextServer();
    if (nome === "navigation") return moduloNavegacao(React);
    if (nome === "cache") return moduloCache();
    if (nome === "headers") return moduloHeaders();
    if (nome === "font/google") return moduloFonteGoogle(React);
    if (nome === "font/local") return moduloFonteLocal(React);
    const f = daFabrica(React).m;
    if (nome === "link") return { __esModule: true, default: f.Link, useLinkStatus: f.useLinkStatus };
    if (nome === "image") return { __esModule: true, default: f.Image, getImageProps: f.getImageProps };
    if (nome === "head") return { __esModule: true, default: f.Head };
    if (nome === "dynamic") return { __esModule: true, default: f.dynamic };
    if (nome === "script") return { __esModule: true, default: f.Script };
    if (nome === "router") return { __esModule: true, useRouter: f.useRouterPages, default: f.roteador };
    if (nome === "form") return { __esModule: true, default: (props) => React.createElement("form", props) };
    throw new Error("Odete ainda não tem substituto para " + spec);
  }

  // ---- next/server e middleware ----
  // O middleware do Next roda antes da rota e decide: segue, redireciona, reescreve ou
  // responde ele mesmo. Isso não depende do runtime da Vercel, só de rodar a função e
  // ler o que ela devolveu — então roda aqui.
  class Cabecalhos {
    constructor(init) {
      this._ = new Map();
      if (init instanceof Cabecalhos) { for (const [k, v] of init._) this._.set(k, v); }
      else if (Array.isArray(init)) { for (const par of init) this.set(par[0], par[1]); }
      else if (init && typeof init.forEach === "function") { init.forEach((v, k) => this.set(k, v)); }
      else if (init && typeof init === "object") { for (const k of Object.keys(init)) this.set(k, init[k]); }
    }
    set(k, v) { this._.set(String(k).toLowerCase(), String(v)); return this; }
    append(k, v) {
      const c = String(k).toLowerCase(), a = this._.get(c);
      this._.set(c, a == null ? String(v) : a + ", " + v);
      return this;
    }
    get(k) { const v = this._.get(String(k).toLowerCase()); return v === undefined ? null : v; }
    has(k) { return this._.has(String(k).toLowerCase()); }
    delete(k) { this._.delete(String(k).toLowerCase()); return this; }
    forEach(f, t) { for (const [k, v] of this._) f.call(t, v, k, this); }
    entries() { return this._.entries(); }
    keys() { return this._.keys(); }
    values() { return this._.values(); }
    [Symbol.iterator]() { return this._.entries(); }
  }

  class Biscoitos {
    constructor(dono) { this.dono = dono; this.lista = []; }
    set(nome, valor, opcoes) {
      if (nome && typeof nome === "object") { opcoes = nome; valor = nome.value; nome = nome.name; }
      const o = opcoes || {};
      let s = encodeURIComponent(nome) + "=" + encodeURIComponent(valor == null ? "" : valor);
      s += "; Path=" + (o.path || "/");
      if (o.maxAge != null) s += "; Max-Age=" + o.maxAge;
      if (o.expires) s += "; Expires=" + new Date(o.expires).toUTCString();
      if (o.domain) s += "; Domain=" + o.domain;
      if (o.httpOnly) s += "; HttpOnly";
      if (o.secure) s += "; Secure";
      if (o.sameSite) s += "; SameSite=" + o.sameSite;
      this.lista.push(s);
      return this.dono;
    }
    delete(nome) { return this.set(nome, "", { maxAge: 0 }); }
    getAll() { return this.lista.slice(); }
  }

  function biscoitosDoPedido(cabecalho) {
    const mapa = new Map();
    for (const parte of String(cabecalho || "").split(";")) {
      const i = parte.indexOf("=");
      if (i < 0) continue;
      const n = parte.slice(0, i).trim();
      if (n) mapa.set(n, decodeURIComponent(parte.slice(i + 1).trim()));
    }
    return {
      get: (n) => (mapa.has(n) ? { name: n, value: mapa.get(n) } : undefined),
      getAll: () => [...mapa].map(([name, value]) => ({ name, value })),
      has: (n) => mapa.has(n),
      size: mapa.size,
    };
  }

  const ACAO = "__odeteAcao";

  class RespostaNext {
    constructor(corpo, init) {
      const o = init || {};
      this.body = corpo == null ? null : corpo;
      this.status = o.status || 200;
      this.statusText = o.statusText || "";
      this.headers = o.headers instanceof Cabecalhos ? o.headers : new Cabecalhos(o.headers);
      this.cookies = new Biscoitos(this);
      this.destino = null;
      this[ACAO] = "resposta";
    }
    static next(init) { const r = new RespostaNext(null, init); r[ACAO] = "segue"; return r; }
    static redirect(url, init) {
      const st = typeof init === "number" ? init : (init && init.status) || 307;
      const r = new RespostaNext(null, typeof init === "object" ? init : null);
      r[ACAO] = "redireciona"; r.destino = String(url); r.status = st;
      r.headers.set("location", r.destino);
      return r;
    }
    static rewrite(url, init) {
      const r = new RespostaNext(null, init);
      r[ACAO] = "reescreve"; r.destino = String(url);
      return r;
    }
    static json(dados, init) {
      const r = new RespostaNext(JSON.stringify(dados), init);
      r.headers.set("content-type", "application/json; charset=utf-8");
      return r;
    }
  }

  function pedidoNext(href, metodo, cabecalhos) {
    const u = new URL(href);
    u.clone = () => pedidoNext(String(u), metodo, cabecalhos).nextUrl;
    return {
      url: String(u),
      nextUrl: u,
      method: (metodo || "GET").toUpperCase(),
      headers: new Cabecalhos(cabecalhos),
      cookies: biscoitosDoPedido((cabecalhos || {}).cookie),
      ip: "127.0.0.1",
      geo: {},
    };
  }

  function moduloNextServer() {
    return {
      __esModule: true,
      NextResponse: RespostaNext,
      NextRequest: function NextRequest(href, init) {
        return pedidoNext(String(href), (init || {}).method, (init || {}).headers);
      },
      Headers: Cabecalhos,
      userAgent: (req) => ({ ua: (req && req.headers && req.headers.get("user-agent")) || "" }),
      userAgentFromString: (s) => ({ ua: s || "" }),
      ImageResponse: function () { throw new Error("Odete ainda não gera ImageResponse"); },
    };
  }

  // `config.matcher` é path-to-regexp. Aqui entra o pedaço que projeto de verdade usa:
  // `:nome` e seus modificadores, e grupo `( ... )` copiado como regex — é assim que o
  // matcher padrão do Next, `/((?!api|_next).*)`, funciona.
  function regexDoMatcher(padrao) {
    let re = "", i = 0;
    while (i < padrao.length) {
      const c = padrao[i];
      if (c === "(") {
        let n = 1, j = i + 1;
        while (j < padrao.length && n > 0) {
          if (padrao[j] === "\\") j++;
          else if (padrao[j] === "(") n++;
          else if (padrao[j] === ")") n--;
          j++;
        }
        re += padrao.slice(i, j); i = j; continue;
      }
      // "/:resto*" casa também sem a barra: /blog/:p* pega /blog.
      const opcional = /^\/:([A-Za-z0-9_]+)([*?])/.exec(padrao.slice(i));
      if (opcional) {
        re += opcional[2] === "*" ? "(?:/(.*))?" : "(?:/([^/]*))?";
        i += opcional[0].length; continue;
      }
      const nomeado = /^:([A-Za-z0-9_]+)([*+?]?)/.exec(padrao.slice(i));
      if (nomeado) {
        re += nomeado[2] === "*" ? "(.*)" : nomeado[2] === "+" ? "(.+)" : nomeado[2] === "?" ? "([^/]*)" : "([^/]+)";
        i += nomeado[0].length; continue;
      }
      re += c.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      i++;
    }
    return new RegExp("^" + re + "$");
  }

  function casaMatcher(config, p) {
    const m = config && config.matcher;
    if (m == null) return true;
    const lista = [].concat(m)
      .map((x) => (typeof x === "string" ? x : x && (x.source || x.matcher)))
      .filter((x) => typeof x === "string");
    if (!lista.length) return true;
    for (const padrao of lista) {
      try { if (regexDoMatcher(padrao).test(p)) return true; } catch (e) { /* padrão fora do que a gente lê */ }
    }
    return false;
  }

  // O que o devserver precisa saber do que o middleware devolveu, sem conhecer as
  // classes daqui.
  function leResposta(r) {
    if (r == null) return null;
    const acao = r[ACAO] || (typeof r.status === "number" || r.body != null ? "resposta" : null);
    if (!acao) return null;
    const cabecalhos = [];
    if (r.headers && typeof r.headers.forEach === "function") r.headers.forEach((v, k) => cabecalhos.push([k, v]));
    return {
      acao,
      status: r.status || 200,
      destino: r.destino || null,
      corpo: r.body == null ? null : String(r.body),
      cabecalhos,
      biscoitos: r.cookies && typeof r.cookies.getAll === "function" ? r.cookies.getAll() : [],
    };
  }


  // ---- Server Actions ----
  // Um módulo que começa com "use server" exporta funções que só rodam aqui. O que o
  // React precisa para ligar um `<form action={fn}>` a uma delas é `$$FORM_ACTION`: ele
  // chama isso no render e escreve no formulário para onde postar e que campos ocultos
  // mandar. O formulário então funciona sem JavaScript nenhum, que é o comportamento
  // que o Next chama de progressive enhancement.
  const acoes = { registro: new Map(), rota: "/" };

  // O `data` do `$$FORM_ACTION` é um FormData do ponto de vista do React: ele percorre
  // com forEach e o `useActionState` acrescenta a própria chave com append.
  class Campos {
    constructor(pares) { this.pares = pares ? pares.slice() : []; }
    append(k, v) { this.pares.push([String(k), String(v)]); return this; }
    forEach(f, t) { for (const [k, v] of this.pares) f.call(t, v, k, this); }
  }

  function embrulhaAcao(id, fn, ligados) {
    const acao = function () {
      return fn.apply(null, ligados.concat(Array.prototype.slice.call(arguments)));
    };
    acao.$$id = id;
    // A ilha que recebe a ação como prop chama pela rede com os mesmos argumentos ligados.
    acao.$$ligados = ligados;
    acao.$$FORM_ACTION = function () {
      const dados = new Campos([[CAMPO, id]]);
      if (ligados.length) {
        // `bind` sem serializar viraria argumento perdido no caminho até aqui.
        try { dados.append(CAMPO_LIGADOS, JSON.stringify(ligados)); } catch (e) { /* fica de fora */ }
      }
      return {
        action: acoes.rota,
        method: "POST",
        encType: "application/x-www-form-urlencoded",
        data: dados,
      };
    };
    // `useActionState` faz `action.bind(null, estadoInicial)`, e o `bind` de série não
    // leva as propriedades junto — sem este, o React desiste e cai no talão que só
    // funciona depois de hidratar.
    acao.bind = function () {
      const extra = Array.prototype.slice.call(arguments, 1);
      return embrulhaAcao(id, fn, ligados.concat(extra));
    };
    return acao;
  }

  const CAMPO = "$odete_acao";
  const CAMPO_LIGADOS = "$odete_ligados";

  function instalaAcoes() {
    raiz.__odeteAcaoServidor = function (modulo, exportado, fn) {
      if (typeof fn !== "function") return fn;
      const id = modulo + "#" + exportado;
      acoes.registro.set(id, fn);
      return embrulhaAcao(id, fn, []);
    };
  }

  function rotaDasAcoes(p) { defineRequisicao(Object.assign({}, requisicao, { pathname: p })); }

  function acaoPorId(id) { return acoes.registro.get(id) || null; }

  // `redirect()` e `notFound()` do Next funcionam lançando: quem chama não segue adiante.
  const REDIR = "__odeteRedirect", NAOACHOU = "__odeteNotFound";

  // O servidor precisa das duas metades: os hooks, que um componente de cliente chama
  // enquanto é renderizado aqui, e o `redirect()` que lança a marca que `leErroDeNavegacao`
  // lê. As duas vêm da fábrica, que é a mesma do navegador.
  function moduloNavegacao(React) {
    return Object.assign({ __esModule: true }, daFabrica(React).m.navegacao);
  }

  // O Preview re-renderiza a cada requisição: não há cache para invalidar.
  function moduloCache() {
    return {
      __esModule: true,
      revalidatePath: () => {}, revalidateTag: () => {},
      unstable_cache: (fn) => fn, unstable_noStore: () => {},
    };
  }

  function leErroDeNavegacao(e) {
    if (!e || typeof e !== "object") return null;
    if (e[REDIR]) return { acao: "redireciona", destino: e[REDIR], status: e.status || 307 };
    if (e[NAOACHOU]) return { acao: "naoachou" };
    return null;
  }

  raiz.__next = {
    rota, renderiza, instalaIlhas, substituto, defineRequisicao, ehIconeDoApp,
    moduloFonteGoogle, moduloFonteLocal, cabecalhoDeFontes,
    moduloNextServer, pedidoNext, casaMatcher, leResposta, regexDoMatcher,
    instalaAcoes, rotaDasAcoes, acaoPorId, moduloNavegacao, moduloCache,
    leErroDeNavegacao, CAMPO, CAMPO_LIGADOS,
    rotaDoApp, rotaDasPages, especial, cabecaDeMetadata, rodaHandler,
  };
  if (typeof module !== "undefined" && module.exports) module.exports = raiz.__next;
})(typeof globalThis !== "undefined" ? globalThis : this);
