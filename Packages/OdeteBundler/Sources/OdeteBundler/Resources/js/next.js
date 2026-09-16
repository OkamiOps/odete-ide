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

  raiz.__next = { rota, renderiza, resolveServidor, instalaIlhas };
  if (typeof module !== "undefined" && module.exports) module.exports = raiz.__next;
})(typeof globalThis !== "undefined" ? globalThis : this);
