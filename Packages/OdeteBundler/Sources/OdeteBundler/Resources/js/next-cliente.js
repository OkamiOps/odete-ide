// Os substitutos de `next/*`, os mesmos nos dois lados.
//
// O servidor renderiza um `<Link>` ou um `<Image>` e o navegador hidrata o mesmo
// componente: se os dois não escreverem exatamente a mesma marcação, a hidratação desiste
// e redesenha a ilha inteira. Por isso a fonte é uma só — o servidor avalia este arquivo
// com o React dele (next.js), e o pacote das ilhas leva o texto inteiro, avaliado com o
// React do navegador (devserver.js, `pacoteDeIlhas`).
//
// Navegar, aqui, é pedir a página de novo ao servidor: cada rota é renderizada no pedido
// e não há árvore de RSC para trocar aos pedaços. `router.push` vira `location.assign`, e
// o que o App Router guardaria entre rotas (estado de layout) recomeça.
globalThis.__odeteNextFabrica = function (React, ReactDOM, lado, requisicao) {
  "use strict";
  const h = React.createElement;
  const noNavegador = lado === "cliente";

  // Onde a página está. No navegador, o location e os parâmetros que o servidor escreveu
  // na página; no servidor, o pedido que está sendo renderizado.
  function aqui() {
    if (noNavegador) {
      const d = globalThis.__odeteRota || {};
      return { pathname: location.pathname, search: location.search, params: d.params || {} };
    }
    const r = (requisicao && requisicao()) || {};
    return { pathname: r.pathname || "/", search: r.search || "", params: r.params || {} };
  }

  // `href` pode ser objeto: `{ pathname, query, hash }`, como o `url.format` do Node.
  function hrefDe(href) {
    if (href == null) return "";
    if (typeof href === "string") return href;
    if (href instanceof URL) return href.toString();
    let s = href.pathname || "";
    const q = href.query;
    if (q && typeof q === "object") {
      const u = new URLSearchParams();
      for (const k of Object.keys(q)) {
        const v = q[k];
        if (Array.isArray(v)) for (const x of v) u.append(k, String(x));
        else if (v != null) u.append(k, String(v));
      }
      const t = u.toString();
      if (t) s += "?" + t;
    } else if (href.search) {
      s += href.search[0] === "?" ? href.search : "?" + href.search;
    }
    if (href.hash) s += href.hash[0] === "#" ? href.hash : "#" + href.hash;
    return s;
  }

  function navega(url, substitui) {
    if (!noNavegador) return;
    if (substitui) location.replace(url);
    else location.assign(url);
  }

  const roteador = {
    push: (u) => navega(hrefDe(u), false),
    replace: (u) => navega(hrefDe(u), true),
    back: () => { if (noNavegador) history.back(); },
    forward: () => { if (noNavegador) history.forward(); },
    refresh: () => { if (noNavegador) location.reload(); },
    prefetch: () => Promise.resolve(),
  };

  // ---- next/link ----
  // O que o `<Link>` aceita e o `<a>` não: fica de fora, dos dois lados.
  const FORA_DO_A = ["href", "as", "replace", "scroll", "shallow", "passHref", "prefetch", "locale",
    "legacyBehavior", "onNavigate", "unstable_dynamicOnHover", "children"];

  const Link = React.forwardRef(function Link(props, ref) {
    const href = hrefDe(props.as || props.href);
    // `replace` é a única diferença para o clique comum: o resto o `<a>` já faz.
    const onClick = (e) => {
      if (props.onClick) props.onClick(e);
      if (!props.replace && !props.onNavigate) return;
      if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      if (props.target && props.target !== "_self") return;
      let evitou = false;
      if (props.onNavigate) props.onNavigate({ preventDefault: () => { evitou = true; } });
      e.preventDefault();
      if (!evitou) navega(href, !!props.replace);
    };
    if (props.legacyBehavior && React.isValidElement(props.children)) {
      return React.cloneElement(props.children, { href, onClick, ref });
    }
    const a = {};
    for (const k of Object.keys(props)) if (FORA_DO_A.indexOf(k) < 0) a[k] = props[k];
    a.href = href;
    a.ref = ref;
    a.onClick = onClick;
    return h("a", a, props.children);
  });
  Link.displayName = "Link";

  function useLinkStatus() { return { pending: false }; }

  // ---- next/image ----
  // Sem o otimizador do Next: o `<img>` que ele escreveria, com a mesma forma — tamanho,
  // carregamento preguiçoso, e `fill` ocupando o pai.
  const FORA_DA_IMG = ["src", "alt", "width", "height", "priority", "preload", "quality", "fill", "loader",
    "placeholder", "blurDataURL", "unoptimized", "overrideSrc", "onLoadingComplete", "lazyBoundary",
    "lazyRoot", "layout", "objectFit", "objectPosition", "style", "loading", "decoding"];

  function srcDe(src) {
    if (src && typeof src === "object") return src.default ? src.default : src;
    return { src };
  }

  function propsDaImagem(props) {
    const est = srcDe(props.src);
    const width = props.fill ? undefined : props.width != null ? props.width : est.width;
    const height = props.fill ? undefined : props.height != null ? props.height : est.height;
    let src = props.overrideSrc || est.src || "";
    if (typeof props.loader === "function") src = props.loader({ src, width: Number(width) || 0, quality: props.quality || 75 });
    const cedo = props.priority || props.preload;
    const a = {};
    for (const k of Object.keys(props)) if (FORA_DA_IMG.indexOf(k) < 0) a[k] = props[k];
    a.alt = props.alt == null ? "" : props.alt;
    if (cedo && a.fetchPriority == null) a.fetchPriority = "high";
    a.loading = cedo ? undefined : props.loading || "lazy";
    a.width = width;
    a.height = height;
    a.decoding = props.decoding || "async";
    a["data-nimg"] = props.fill ? "fill" : "1";
    a.style = Object.assign(
      props.fill ? { position: "absolute", height: "100%", width: "100%", left: 0, top: 0, right: 0, bottom: 0 } : {},
      { color: "transparent" },
      props.style || {}
    );
    a.src = src;
    return a;
  }

  const Image = React.forwardRef(function Image(props, ref) {
    const a = propsDaImagem(props);
    a.ref = ref;
    return h("img", a);
  });
  Image.displayName = "Image";

  function getImageProps(props) { return { props: propsDaImagem(props || {}) }; }

  // ---- next/font ----
  // A fonte vira uma classe com a família e, se pedida, uma variável CSS com ela. O nome
  // da classe sai só da família: o servidor e o navegador chegam ao mesmo sem conversar.
  // Quem registra o <link> do Google e as regras é o servidor (`registra`); no navegador a
  // página já veio com elas.
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
  function resultadoFonte(familia, o, antes, registra) {
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
    if (registra) registra.regra(classe, css);
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
  const FORMATO = { woff2: "woff2", woff: "woff", ttf: "truetype", otf: "opentype", eot: "embedded-opentype" };

  function fontes(registra) {
    function google(exportado, opcoes) {
      const o = opcoes || {};
      const familia = String(exportado).replace(/_/g, " ");
      if (registra) registra.link(familia, urlGoogle(familia, o));
      return resultadoFonte(familia, o, "", registra);
    }
    function local(opcoes) {
      const o = opcoes || {};
      const entradas = [].concat(o.src || []);
      const primeiro = typeof entradas[0] === "string" ? entradas[0] : (entradas[0] && entradas[0].path) || "fonte";
      const familia = o.family || "Odete " + apelido(primeiro.split("/").pop().replace(/\.[^.]+$/, ""));
      const faces = [];
      for (const e of entradas) {
        const caminho = typeof e === "string" ? e : e && e.path;
        if (!caminho || !registra || !registra.arquivo) continue;
        const url = registra.arquivo(caminho);
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
      return resultadoFonte(familia, o, faces.join(""), registra);
    }
    // `next/font/google` exporta uma função por família, e não dá para saber quais antes
    // de ver o import. Um Proxy no *protótipo* resolve qualquer nome — e no protótipo
    // porque o interop CJS do esbuild copia as próprias chaves do módulo, que num Proxy
    // vazio são nenhuma; pelo protótipo a busca cai no trap e o nome aparece.
    const moduloGoogle = Object.create(new Proxy({}, {
      get(_, nome) {
        if (typeof nome !== "string") return undefined;
        if (nome === "__esModule") return true;
        return (opcoes) => google(nome, opcoes);
      },
      has() { return true; },
    }));
    return { google, local, moduloGoogle };
  }

  // ---- next/dynamic ----
  // `ssr: false` renderiza o `loading` (ou nada) no servidor e na hidratação, e só então
  // carrega; com SSR, `lazy` dentro de Suspense — o servidor espera e manda pronto.
  function dynamic(carrega, opcoes) {
    const o = typeof carrega === "object" && carrega && !opcoes ? carrega : opcoes || {};
    const fn = typeof carrega === "function" ? carrega : o.loader;
    const Carregando = o.loading;
    const aguarde = () => (Carregando ? h(Carregando, { isLoading: true, pastDelay: true, error: null }) : null);
    const componente = (m) => (m && m.default ? m.default : m);
    if (o.ssr === false) {
      return function Dinamico(props) {
        const [C, setC] = React.useState(null);
        React.useEffect(() => {
          let vivo = true;
          Promise.resolve(fn()).then((m) => { if (vivo) setC(() => componente(m)); });
          return () => { vivo = false; };
        }, []);
        return C ? h(C, props) : aguarde();
      };
    }
    const Preguica = React.lazy(() => Promise.resolve(fn()).then((m) => ({ default: componente(m) })));
    return function Dinamico(props) {
      return h(React.Suspense, { fallback: aguarde() }, h(Preguica, props));
    };
  }

  // ---- next/script ----
  // Os scripts do Next entram depois da página pronta; `beforeInteractive` sai no HTML.
  function Script(props) {
    const { src, strategy, onLoad, onReady, onError, id, children, dangerouslySetInnerHTML } = props;
    React.useEffect(() => {
      if (strategy === "beforeInteractive") return;
      if (id && document.getElementById(id)) { if (onReady) onReady(); return; }
      const s = document.createElement("script");
      if (id) s.id = id;
      for (const k of Object.keys(props)) {
        if (["src", "strategy", "onLoad", "onReady", "onError", "children", "dangerouslySetInnerHTML", "id"].indexOf(k) >= 0) continue;
        if (typeof props[k] === "string") s.setAttribute(k, props[k]);
      }
      if (src) {
        s.src = src;
        s.onload = (e) => { if (onLoad) onLoad(e); if (onReady) onReady(); };
        s.onerror = (e) => { if (onError) onError(e); };
      } else {
        s.textContent = (dangerouslySetInnerHTML && dangerouslySetInnerHTML.__html) || (typeof children === "string" ? children : "");
      }
      document.body.appendChild(s);
    }, []);
    if (strategy === "beforeInteractive" && src) return h("script", { src, id });
    return null;
  }

  // ---- next/head (Pages Router) ----
  function Head(props) { return h(React.Fragment, null, props && props.children); }

  // ---- next/navigation ----
  function usePathname() { return aqui().pathname; }
  function useSearchParams() { return new URLSearchParams(aqui().search); }
  function useParams() { return aqui().params; }
  function useRouter() { return roteador; }
  function useSelectedLayoutSegments() { return aqui().pathname.split("/").filter(Boolean); }
  function useSelectedLayoutSegment() { return useSelectedLayoutSegments()[0] || null; }
  function useServerInsertedHTML() {}

  // `redirect()` e `notFound()` interrompem quem chamou. No servidor o next.js lê a
  // marca e responde 307 ou 404; no navegador, a página já está indo para outro lugar.
  const REDIR = "__odeteRedirect", NAOACHOU = "__odeteNotFound";
  function lanca(url, status) {
    navega(url, true);
    const e = new Error("NEXT_REDIRECT");
    e[REDIR] = String(url);
    e.status = status;
    throw e;
  }
  function notFound() {
    const e = new Error("NEXT_NOT_FOUND");
    e[NAOACHOU] = true;
    throw e;
  }

  const navegacao = {
    useRouter, usePathname, useSearchParams, useParams, useSelectedLayoutSegment,
    useSelectedLayoutSegments, useServerInsertedHTML,
    redirect: (url) => lanca(url, 307),
    permanentRedirect: (url) => lanca(url, 308),
    notFound,
    forbidden: notFound,
    unauthorized: notFound,
    unstable_rethrow: (e) => { if (e && (e[REDIR] || e[NAOACHOU])) throw e; },
    RedirectType: { push: "push", replace: "replace" },
    ReadonlyURLSearchParams: URLSearchParams,
  };

  // Pages Router: o `useRouter` de `next/router` tem mais coisas que o do App Router.
  function useRouterPages() {
    const a = aqui();
    const query = Object.assign({}, Object.fromEntries(new URLSearchParams(a.search)), a.params);
    return Object.assign({}, roteador, {
      pathname: a.pathname, asPath: a.pathname + a.search, route: a.pathname, query,
      isReady: true, isFallback: false, basePath: "", locale: undefined,
      events: { on() {}, off() {}, emit() {} },
    });
  }

  return {
    Link, useLinkStatus, Image, getImageProps, fontes, dynamic, Script, Head,
    navegacao, useRouterPages, roteador, hrefDe, REDIR, NAOACHOU,
  };
};
