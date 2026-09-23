// CSS do projeto antes de chegar ao esbuild: Sass, Less, Tailwind e CSS Modules.
//
// O esbuild só entende CSS. Um `.scss` caía no carregador de arquivo e virava uma string
// em data URL — o `import "./app.scss"` não dava erro nenhum e a página ficava sem estilo.
// E `import s from "./a.module.css"` era `{}` calado: o loader era `css`, não `local-css`.
// Aqui, como o Vite faz:
//   - `.scss`/`.sass` passam pelo pacote `sass` do projeto (JS puro, o dart-sass compilado
//     para JS) e `.less` pelo `less`; sem o pacote instalado, o erro diz qual instalar;
//   - depois, o CSS com diretivas do Tailwind passa pelo tailwind.js;
//   - `*.module.(css|scss|sass|less)` vai com o loader `local-css`: as classes viram nomes
//     únicos e o import devolve o mapa delas.
// Os arquivos que o Sass e o Less leem (`@use`, `@import`) não passam pelo esbuild e não
// aparecem no metafile: vão para `vigiados`, e o dev server vigia também esses.
(function () {
  const fs = require("fs"), path = require("path"), H = globalThis.__odete;
  const texto = (k, ...a) => globalThis.__odeteTexto(k, ...a);

  const EH_ESTILO = /\.(css|scss|sass|less)$/i;
  const EH_MODULO = /\.module\.(css|scss|sass|less)$/i;

  // Resultado do Sass/Less por arquivo: vale enquanto ele e o que ele leu tiverem a mesma
  // data. Sem JIT, compilar Sass de novo a cada rebuild seria a maior parte do rebuild.
  const compilados = new Map(); // arquivo → { texto, deps: Map(arquivo → mt), css }

  function mtimeDe(f) { try { return fs.statSync(f).mtimeMs; } catch (e) { return null; } }

  function aindaVale(g, conteudo) {
    if (!g || g.texto !== conteudo) return false;
    for (const [f, mt] of g.deps) if (mtimeDe(f) !== mt) return false;
    return true;
  }

  // O pacote pelo `require` do motor, a partir do arquivo: o do projeto, não um nosso.
  function pacote(nome, de) {
    const r = H.resolve(nome + "/package.json", de);
    if (!r || typeof r !== "string") return null;
    return { dir: path.dirname(r), json: JSON.parse(fs.readFileSync(r, "utf8")) };
  }

  // ---- Sass ----
  // O `sass.node.js` do pacote pede `require("module")`, que o runtime não tem (é para o
  // `pkg:` importer). O que ele faz é pouco: carrega o dart-sass e entrega a ele os
  // módulos do Node. Isso é refeito aqui, com um `module` que só sabe `createRequire`.
  const sasses = new Map(); // pasta do pacote → biblioteca
  function carregaSass(de) {
    const p = pacote("sass", de);
    if (!p) throw new Error(texto("estiloSemPacote", "sass", path.basename(de)));
    const g = sasses.get(p.dir);
    if (g) return g;
    const req = globalThis.__odete_makeRequire(path.join(p.dir, "sass.node.js"));
    req("./sass.dart.js");
    const pilha = globalThis._cliPkgExports;
    const lib = pilha.pop();
    if (!pilha.length) delete globalThis._cliPkgExports;
    lib.load({
      util: req("util"), stream: req("stream"), fs: req("fs"), immutable: req("immutable"),
      nodeModule: { createRequire: (f) => globalThis.__odete_makeRequire(String(f).replace(/^file:\/\//, "")) },
    });
    sasses.set(p.dir, lib);
    return lib;
  }

  // `@use "bootstrap/scss/bootstrap"` e `@import "~pacote/x"`: o Sass só conhece caminho
  // relativo e `loadPaths`. O Vite resolve o resto — alias e pacote em node_modules — e
  // devolve para o Sass achar o parcial (`_x.scss`) e o índice como ele sabe.
  function importadorSass(ctx, de) {
    return {
      findFileUrl(url, contexto) {
        if (/^[a-z][a-z0-9+.-]*:/i.test(url) || url.startsWith(".") || url.startsWith("/")) return null;
        const pedido = url.startsWith("~") ? url.slice(1) : url;
        const base = contexto && contexto.containingUrl ? path.dirname(decodeURIComponent(contexto.containingUrl.pathname)) : path.dirname(de);
        const alias = globalThis.__odeteAlias ? globalThis.__odeteAlias.aplica(ctx.root, pedido, ctx.vigiados) : null;
        if (alias && alias.length) return new URL("file://" + encodeURI(path.resolve(ctx.root, alias[0])));
        const partes = pedido.split("/");
        const n = pedido.startsWith("@") ? 2 : 1;
        for (let d = base; ; d = path.dirname(d)) {
          const dir = path.join(d, "node_modules", partes.slice(0, n).join("/"));
          if (fs.existsSync(dir)) {
            if (partes.length > n) return new URL("file://" + encodeURI(path.join(dir, partes.slice(n).join("/"))));
            // O pacote inteiro: o campo `sass` ou `style` do package.json diz o arquivo.
            try {
              const j = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
              const f = j.sass || j.style;
              if (typeof f === "string") return new URL("file://" + encodeURI(path.join(dir, f)));
            } catch (e) { /* sem package.json */ }
            return new URL("file://" + encodeURI(dir));
          }
          if (d === path.dirname(d)) return null;
        }
      },
    };
  }

  async function compilaSass(arquivo, ctx) {
    const sass = carregaSass(arquivo);
    try {
      const r = await sass.compileAsync(arquivo, {
        style: "expanded", sourceMap: false, loadPaths: [path.dirname(arquivo), ctx.root],
        importers: [importadorSass(ctx, arquivo)],
        // O Sass avisa de coisa depreciada no console; o Vite também deixa passar.
        logger: { warn: () => {}, debug: () => {} },
      });
      const deps = new Map();
      for (const u of r.loadedUrls || []) {
        if (u.protocol !== "file:") continue;
        const f = decodeURIComponent(u.pathname);
        deps.set(f, mtimeDe(f));
      }
      return { css: r.css, deps };
    } catch (e) {
      throw erroComLugar(e, arquivo);
    }
  }

  // ---- Less ----
  function carregaLess(de) {
    const p = pacote("less", de);
    if (!p) throw new Error(texto("estiloSemPacote", "less", path.basename(de)));
    const mod = globalThis.__odete_makeRequire(de)("less");
    return mod && mod.default ? mod.default : mod;
  }

  async function compilaLess(arquivo, conteudo, ctx) {
    const less = carregaLess(arquivo);
    try {
      const r = await less.render(conteudo, { filename: arquivo, paths: [path.dirname(arquivo), ctx.root, path.join(ctx.root, "node_modules")], javascriptEnabled: true });
      const deps = new Map();
      for (const f of r.imports || []) deps.set(path.resolve(path.dirname(arquivo), f), mtimeDe(path.resolve(path.dirname(arquivo), f)));
      return { css: r.css, deps };
    } catch (e) {
      const err = new Error(e.message || String(e));
      if (e.line) err.lugar = { file: e.filename || arquivo, line: e.line, column: e.column || 0, lineText: e.extract ? e.extract[1] : "" };
      throw err;
    }
  }

  function erroComLugar(e, arquivo) {
    const err = new Error(e.sassMessage || e.message || String(e));
    const s = e.span;
    if (s && s.start) {
      const f = s.url && s.url.pathname ? decodeURIComponent(s.url.pathname) : arquivo;
      err.lugar = { file: f, line: s.start.line + 1, column: s.start.column, lineText: (s.context || "").split("\n")[0] };
    }
    return err;
  }

  // O CSS pronto para o esbuild. `ctx`: { root, vigiados (Set), pastas (Set), novo }.
  // Devolve { contents, loader } ou { errors } no formato do onLoad.
  async function carrega(arquivo, ctx) {
    const loader = EH_MODULO.test(arquivo) ? "local-css" : "css";
    try {
      let conteudo = fs.readFileSync(arquivo, "utf8");
      const ext = path.extname(arquivo).toLowerCase();
      if (ext === ".scss" || ext === ".sass" || ext === ".less") {
        const g = compilados.get(arquivo);
        if (!ctx.novo && aindaVale(g, conteudo)) {
          for (const f of g.deps.keys()) ctx.vigiados.add(f);
          conteudo = g.css;
        } else {
          const r = ext === ".less" ? await compilaLess(arquivo, conteudo, ctx) : await compilaSass(arquivo, ctx);
          r.deps.set(arquivo, mtimeDe(arquivo));
          if (!ctx.novo) compilados.set(arquivo, { texto: conteudo, deps: r.deps, css: r.css });
          for (const f of r.deps.keys()) ctx.vigiados.add(f);
          conteudo = r.css;
        }
      }
      if (globalThis.__odeteTailwind.ehDoTailwind(conteudo)) {
        const css = await globalThis.__odeteTailwind.processa(arquivo, conteudo, ctx);
        if (css != null) conteudo = css;
      }
      return { contents: conteudo, loader, resolveDir: path.dirname(arquivo) };
    } catch (e) {
      const lugar = e.lugar ? { file: path.relative(ctx.root, e.lugar.file), line: e.lugar.line, column: e.lugar.column, lineText: e.lugar.lineText } : { file: path.relative(ctx.root, arquivo) };
      return { errors: [{ text: String(e.message || e), location: lugar }], watchFiles: [arquivo] };
    }
  }

  function esquece(caminhos) {
    for (const c of caminhos || []) compilados.delete(c);
  }

  // O mesmo caminho para CSS que não é arquivo: o `<style lang="scss">` de um .astro.
  // `de` é o arquivo onde o bloco mora (o `@use` relativo e o pacote partem dele); `chave`
  // separa os blocos de um mesmo arquivo no cache do Tailwind. Devolve o CSS pronto.
  async function compilaTexto(conteudo, lang, de, chave, ctx) {
    const l = String(lang || "css").toLowerCase();
    let css = conteudo;
    if (l === "scss" || l === "sass") {
      const sass = carregaSass(de);
      try {
        const r = await sass.compileStringAsync(conteudo, {
          syntax: l === "sass" ? "indented" : "scss", url: new URL("file://" + encodeURI(de)),
          style: "expanded", sourceMap: false, loadPaths: [path.dirname(de), ctx.root],
          importers: [importadorSass(ctx, de)], logger: { warn: () => {}, debug: () => {} },
        });
        for (const u of r.loadedUrls || []) {
          const f = u.protocol === "file:" ? decodeURIComponent(u.pathname) : null;
          if (f && f !== de) ctx.vigiados.add(f);
        }
        css = r.css;
      } catch (e) {
        throw erroComLugar(e, de);
      }
    } else if (l === "less") {
      const r = await compilaLess(de, conteudo, ctx);
      for (const f of r.deps.keys()) ctx.vigiados.add(f);
      css = r.css;
    }
    if (globalThis.__odeteTailwind.ehDoTailwind(css)) {
      const t = await globalThis.__odeteTailwind.processa(chave || de, css, ctx);
      if (t != null) css = t;
    }
    return css;
  }

  // Um `.css` comum, sem módulo e sem diretiva do Tailwind, não precisa de nada daqui:
  // segue pelo carregador de sempre, com os bytes guardados entre rebuilds. A resposta
  // fica guardada por arquivo até ele mudar — o CSS de um pacote não é decodificado a
  // cada rebuild só para descobrir que é CSS comum.
  // Com a data junto: o `vite build` não passa pelo observador, e um CSS que ganhou um
  // `@apply` entre dois builds não pode seguir como "comum".
  const simples = new Map(); // arquivo → { mt, tw }
  function precisa(arquivo) {
    if (!/\.css$/i.test(arquivo) || EH_MODULO.test(arquivo)) return true;
    const mt = mtimeDe(arquivo);
    const g = simples.get(arquivo);
    if (g && g.mt === mt) return g.tw;
    let t = "";
    try { t = fs.readFileSync(arquivo, "utf8"); } catch (e) { return false; }
    const tw = globalThis.__odeteTailwind.ehDoTailwind(t);
    simples.set(arquivo, { mt, tw });
    return tw;
  }

  globalThis.__odeteEstilos = {
    ehEstilo: (p) => EH_ESTILO.test(p),
    ehModulo: (p) => EH_MODULO.test(p),
    precisa, carrega, compilaTexto,
    esquece: (caminhos) => { for (const c of caminhos || []) simples.delete(c); esquece(caminhos); },
    esqueceTudo: () => { compilados.clear(); sasses.clear(); simples.clear(); },
  };
})();
