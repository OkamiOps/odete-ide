// Rotas e render de projetos Next, no aparelho.
//
// O Next roda um servidor Node que a Odete não tem. O que ela tem é o mesmo React e o
// mesmo `require` que resolve `node_modules` e transpila TSX — então a página é
// executada aqui e devolvida como HTML.
//
// O renderizador de componentes de servidor é nosso: `renderToString` do React não
// aceita componente `async`, e componente de servidor é exatamente isso. A passagem
// abaixo executa a árvore, espera cada um e entrega ao React uma árvore já resolvida.
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

  // App Router: `app/page.tsx` é `/`, `app/blog/page.tsx` é `/blog`, e cada nível pode
  // ter um `layout` que embrulha o de dentro.
  function rotaDoApp(fs, path, root, p) {
    const base = path.join(root, "app");
    if (!fs.existsSync(base)) return null;
    const partes = p.split("/").filter(Boolean);
    const dir = path.join(base, ...partes);
    if (!dir.startsWith(base)) return null;
    const pagina = achaArquivo(fs, path, dir, "page");
    if (!pagina) return null;
    const layouts = [];
    let atual = base;
    const camadas = [atual].concat(partes.map((_, i) => path.join(base, ...partes.slice(0, i + 1))));
    for (const c of camadas) {
      const l = achaArquivo(fs, path, c, "layout");
      if (l) layouts.push(l);
    }
    return { tipo: "app", pagina, layouts };
  }

  // Pages Router: `pages/index.tsx` é `/`, `pages/sobre.tsx` é `/sobre`, e `_app` embrulha.
  function rotaDasPages(fs, path, root, p) {
    const base = path.join(root, "pages");
    if (!fs.existsSync(base)) return null;
    const rel = p.replace(/^\/+|\/+$/g, "");
    const alvo = rel === "" ? "index" : rel;
    let pagina = achaArquivo(fs, path, base, alvo);
    if (!pagina) pagina = achaArquivo(fs, path, path.join(base, alvo), "index");
    if (!pagina) return null;
    const app = achaArquivo(fs, path, base, "_app");
    return { tipo: "pages", pagina, layouts: app ? [app] : [] };
  }

  function rota(fs, path, root, p) {
    return rotaDoApp(fs, path, root, p) || rotaDasPages(fs, path, root, p);
  }

  // ---- render ----
  // `renderToString` não espera promessa, e componente de servidor é função async. Esta
  // passagem executa a árvore antes: cada componente que é função async vira o que ele
  // devolveu, recursivamente. É o pedaço de RSC que a gente escreve, e não importa.
  async function resolveServidor(React, el, fundo) {
    if (el == null || typeof el !== "object") return el;
    if (Array.isArray(el)) return await Promise.all(el.map((x) => resolveServidor(React, x, fundo)));
    if (!el.type) return el;
    const tipo = el.type;
    const ehAsync = typeof tipo === "function" &&
      (tipo.constructor && tipo.constructor.name === "AsyncFunction");
    if (ehAsync) {
      if (fundo.profundidade > 64) throw new Error("componentes de servidor aninhados demais");
      fundo.profundidade++;
      const saida = await tipo(el.props || {});
      fundo.profundidade--;
      return await resolveServidor(React, saida, fundo);
    }
    const filhos = el.props && el.props.children;
    if (filhos === undefined) return el;
    const resolvidos = await resolveServidor(React, filhos, fundo);
    if (resolvidos === filhos) return el;
    return React.cloneElement(el, undefined, resolvidos);
  }

  async function renderiza(ctx, rota, url) {
    const { React, servidor } = ctx;
    const req = ctx.carrega;
    const pagina = await req(rota.pagina);
    const Page = pagina.default || pagina;
    if (typeof Page !== "function") throw new Error(rota.pagina + " não exporta um componente");

    const props = rota.tipo === "pages" ? { } : { params: {}, searchParams: {} };
    let el = React.createElement(Page, props);

    // layouts de fora para dentro: o primeiro da lista é o mais externo
    for (let i = rota.layouts.length - 1; i >= 0; i--) {
      const m = await req(rota.layouts[i]);
      const L = m.default || m;
      if (typeof L !== "function") continue;
      el = rota.tipo === "pages"
        ? React.createElement(L, { Component: Page, pageProps: props })
        : React.createElement(L, { children: el });
      if (rota.tipo === "pages") break; // _app já recebe a página inteira
    }

    const pronta = await resolveServidor(React, el, { profundidade: 0 });
    return servidor.renderToString(pronta);
  }

  // ---- ilhas ----
  // Um componente de cliente renderiza normalmente no servidor, mas embrulhado numa
  // marca que carrega o módulo e as props. O navegador acha essas marcas e hidrata só
  // elas — o resto da página é HTML e continua sendo HTML.
  function instalaIlhas(React, coletadas) {
    raiz.__odeteIlha = function (modulo, exportado, Componente) {
      if (typeof Componente !== "function") return Componente;
      const Ilha = function (props) {
        const semFilhos = {};
        let temFilhos = false;
        for (const k of Object.keys(props || {})) {
          if (k === "children") { temFilhos = true; continue; }
          semFilhos[k] = props[k];
        }
        let dados = null;
        try { dados = JSON.stringify(semFilhos); } catch (e) { dados = null; }
        const id = modulo + "#" + exportado;
        coletadas.add(id);
        // Props que não atravessam JSON, ou filhos vindos do servidor, tornam a
        // hidratação insegura: melhor a ilha ficar estática do que remontar errado.
        const podeHidratar = dados !== null && !temFilhos;
        return React.createElement(
          "odete-ilha",
          podeHidratar ? { "data-ilha": id, "data-props": dados } : { "data-ilha": id, "data-estatica": "1" },
          React.createElement(Componente, props)
        );
      };
      Ilha.displayName = "Ilha(" + exportado + ")";
      return Ilha;
    };
  }


  // ---- next/font ----
  // A fonte é criada no topo do módulo, quando a rota carrega, e não a cada render. O
  // registro é do processo, e o <head> das páginas do projeto leva o que estiver
  // registrado — um pouco mais do que o Next mandaria em cada rota, e muito menos do
  // que não ter fonte nenhuma.
  const fontes = { links: new Map(), regras: new Map() };

  function apelido(s) {
    return String(s).replace(/[^A-Za-z0-9]+/g, "_").replace(/^_+|_+$/g, "").toLowerCase();
  }

  function comAspas(f) {
    return /^[A-Za-z0-9-]+$/.test(f) ? f : "'" + String(f).replace(/'/g, "") + "'";
  }

  function familiaCSS(familia, o) {
    const lista = [comAspas(familia)].concat([].concat(o.fallback || []).map(comAspas));
    lista.push(o.generico || "sans-serif");
    return lista.join(", ");
  }

  // O que o Next devolve: `className` para aplicar a fonte, `variable` para quem prefere
  // a custom property, e `style` para quem aplica direto no elemento.
  function resultadoFonte(familia, o, antes) {
    const classe = "__odete_fonte_" + apelido(familia);
    const fam = familiaCSS(familia, o);
    let css = (antes || "") + "." + classe + "{font-family:" + fam;
    if (o.weight && !Array.isArray(o.weight)) css += ";font-weight:" + o.weight;
    if (o.style && !Array.isArray(o.style)) css += ";font-style:" + o.style;
    css += "}";
    let variavel = "";
    if (o.variable) {
      variavel = classe + "_var";
      css += "." + variavel + "{" + o.variable + ":" + fam + "}";
    }
    fontes.regras.set(classe, css);
    return { className: classe, variable: variavel, style: { fontFamily: fam } };
  }

  function urlGoogle(familia, o) {
    const pesos = [].concat(o.weight || []).map(String).filter((w) => w && w !== "variable");
    const estilos = [].concat(o.style || []).map(String);
    const nome = familia.replace(/ /g, "+");
    let eixo = "";
    if (estilos.indexOf("italic") >= 0) {
      const ps = pesos.length ? pesos : ["400"];
      const its = estilos.indexOf("normal") >= 0 || estilos.length > 1 ? [0, 1] : [1];
      const pares = [];
      for (const i of its) for (const w of ps) pares.push(i + "," + w);
      eixo = ":ital,wght@" + pares.sort().join(";");
    } else if (pesos.length) {
      eixo = ":wght@" + pesos.slice().sort().join(";");
    }
    return "https://fonts.googleapis.com/css2?family=" + nome + eixo + "&display=" + (o.display || "swap");
  }

  function fonteGoogle(exportado, opcoes) {
    const o = opcoes || {};
    const familia = String(exportado).replace(/_/g, " ");
    fontes.links.set(familia, urlGoogle(familia, o));
    return resultadoFonte(familia, o);
  }

  const FORMATO = { woff2: "woff2", woff: "woff", ttf: "truetype", otf: "opentype", eot: "embedded-opentype" };

  function fonteLocal(opcoes) {
    const o = opcoes || {};
    const entradas = [].concat(o.src || []);
    const primeiro = typeof entradas[0] === "string" ? entradas[0] : (entradas[0] && entradas[0].path) || "fonte";
    const familia = o.family || "Odete " + apelido(primeiro.split("/").pop().replace(/\.[^.]+$/, ""));
    const faces = [];
    for (const e of entradas) {
      const caminho = typeof e === "string" ? e : e && e.path;
      if (!caminho) continue;
      const url = typeof raiz.__odeteArquivoDeFonte === "function" ? raiz.__odeteArquivoDeFonte(caminho) : null;
      if (!url) continue;
      const ext = (url.split(".").pop() || "").toLowerCase();
      faces.push(
        "@font-face{font-family:" + comAspas(familia) + ";src:url('" + url + "')" +
        (FORMATO[ext] ? " format('" + FORMATO[ext] + "')" : "") +
        ";font-weight:" + ((typeof e === "object" && e.weight) || o.weight || "400") +
        ";font-style:" + ((typeof e === "object" && e.style) || o.style || "normal") +
        ";font-display:" + (o.display || "swap") + "}"
      );
    }
    return resultadoFonte(familia, o, faces.join(""));
  }

  // `next/font/google` exporta uma função por família, e não dá para saber quais antes
  // de ver o import. Um Proxy no *protótipo* resolve qualquer nome — e no protótipo
  // porque o interop CJS do esbuild copia as próprias chaves do módulo, que num Proxy
  // vazio são nenhuma; pelo protótipo a busca cai no trap e o nome aparece.
  function moduloFonteGoogle() {
    return Object.create(new Proxy({}, {
      get(_, nome) {
        if (typeof nome !== "string") return undefined;
        if (nome === "__esModule") return true;
        return (opcoes) => fonteGoogle(nome, opcoes);
      },
      has() { return true; },
    }));
  }

  function moduloFonteLocal() {
    return { __esModule: true, default: fonteLocal };
  }

  function cabecalhoDeFontes() {
    let s = "";
    for (const u of fontes.links.values()) s += '<link rel="stylesheet" href="' + u.replace(/&/g, "&amp;") + '">';
    const css = [...fontes.regras.values()].join("");
    if (css) s += "<style>" + css + "</style>";
    return s;
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

  function rotaDasAcoes(p) { acoes.rota = p; }

  function acaoPorId(id) { return acoes.registro.get(id) || null; }

  // `redirect()` e `notFound()` do Next funcionam lançando: quem chama não segue adiante.
  const REDIR = "__odeteRedirect", NAOACHOU = "__odeteNotFound";

  function moduloNavegacao() {
    const lanca = (url, status) => {
      const e = new Error("NEXT_REDIRECT");
      e[REDIR] = String(url); e.status = status;
      throw e;
    };
    return {
      __esModule: true,
      redirect: (url) => lanca(url, 307),
      permanentRedirect: (url) => lanca(url, 308),
      notFound: () => { const e = new Error("NEXT_NOT_FOUND"); e[NAOACHOU] = true; throw e; },
      RedirectType: { push: "push", replace: "replace" },
      usePathname: () => acoes.rota,
      useSearchParams: () => new URLSearchParams(),
      useRouter: () => ({
        push: () => {}, replace: () => {}, back: () => {}, forward: () => {},
        refresh: () => {}, prefetch: () => {},
      }),
      useParams: () => ({}),
    };
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
    rota, renderiza, resolveServidor, instalaIlhas,
    moduloFonteGoogle, moduloFonteLocal, cabecalhoDeFontes,
    moduloNextServer, pedidoNext, casaMatcher, leResposta, regexDoMatcher,
    instalaAcoes, rotaDasAcoes, acaoPorId, moduloNavegacao, moduloCache,
    leErroDeNavegacao, CAMPO, CAMPO_LIGADOS,
  };
  if (typeof module !== "undefined" && module.exports) module.exports = raiz.__next;
})(typeof globalThis !== "undefined" ? globalThis : this);
