// Dev server: serve index.html, bundles do esbuild, estáticos e reload por WebSocket.
(function () {
  const http = require("http"), fs = require("fs"), path = require("path");
  const MIME = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp", ".ico": "image/x-icon", ".txt": "text/plain; charset=utf-8", ".map": "application/json", ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf", ".wasm": "application/wasm", ".md": "text/markdown; charset=utf-8" };
  const CLIENT = `<script>(function(){var p=location.protocol==="https:"?"wss":"ws";var s=new WebSocket(p+"://"+location.host+"/@odete/ws");s.onmessage=function(e){if(e.data==="reload")location.reload();};s.onclose=function(){setTimeout(function(){location.reload()},1500)};})();</script>`;
  const state = { root: "", server: null, port: 0, cache: new Map(), diagnostics: [], preset: "plain", sockets: new Set(), building: null };
  const sendDiag = () => globalThis.__odete_diagnostics && globalThis.__odete_diagnostics(JSON.stringify(state.diagnostics));

  async function bundle(entryRel) {
    const key = entryRel;
    if (state.cache.has(key)) return state.cache.get(key);
    const p = (async () => {
      const r = await globalThis.__build({ root: state.root, entries: [entryRel], format: "esm", platform: "browser", dev: true, outdir: "__odete", externalMissing: true });
      state.diagnostics = state.diagnostics.filter((d) => d.entry !== key).concat(r.errors.map((e) => ({ ...e, kind: "error", entry: key })), r.warnings.map((w) => ({ ...w, kind: "warning", entry: key })));
      sendDiag();
      const js = r.files.find((f) => f.path.endsWith(".js")), css = r.files.find((f) => f.path.endsWith(".css"));
      return { ok: r.ok, js: js ? js.text : errorOverlay(r.errors), css: css ? css.text : "" };
    })();
    state.cache.set(key, p);
    return p;
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
      extra = "\n\nEste é um projeto Astro: a rota " + p + " viria de src/pages" +
        (p === "/" ? "/index.astro" : p + ".astro") +
        ".\nA Odete serve estáticos e bundles, mas ainda não compila páginas .astro." +
        "\nPara ver algo no Preview agora, ponha um index.html em public/.";
    } else if (state.preset === "next" || tem("app") || tem("pages")) {
      extra = "\n\nEste é um projeto Next: a Odete ainda não renderiza rotas de app/ ou pages/." +
        "\nPara ver algo no Preview agora, ponha um index.html em public/.";
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
  async function carregaNext(arquivo) {
    const mt = fs.statSync(arquivo).mtimeMs;
    const cache = pacoteNext.get(arquivo);
    if (cache && cache.mt === mt) return cache.exports;
    const r = await globalThis.__build({
      root: state.root, entries: [path.relative(state.root, arquivo)],
      format: "cjs", platform: "node", dev: true, outdir: "__odete_next",
      external: ["react", "react-dom", "react/jsx-runtime", "react/jsx-dev-runtime", "next/*"],
    });
    if (!r.ok) throw new Error((r.errors[0] && r.errors[0].text) || "build da página falhou");
    const saida = r.files.find((f) => f.path.endsWith(".js"));
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

  // `next/link` e `next/image` existem para o roteador e o otimizador do Next, que aqui
  // não existem: viram a marcação que eles produziriam.
  function substitutoNext(spec, React) {
    const nome = spec.slice("next/".length);
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

  function send(res, status, type, body) { res.writeHead(status, { "content-type": type, "cache-control": "no-store", "access-control-allow-origin": "*" }); res.end(body); }

  async function handle(req, res) {
    const url = new URL(req.url, "http://x");
    let p = decodeURIComponent(url.pathname);
    try {
      if (p.startsWith("/@odete/js/")) { const b = await bundle(p.slice(11)); return send(res, 200, MIME[".js"], b.js); }
      if (p.startsWith("/@odete/css/")) { const b = await bundle(p.slice(12)); return send(res, 200, MIME[".css"], b.css); }
      if (p === "/@odete/diag") return send(res, 200, "application/json", JSON.stringify(state.diagnostics));
      // estáticos: public/ primeiro, depois raiz
      for (const base of [path.join(state.root, "public"), state.root]) {
        let f = path.join(base, p);
        if (!f.startsWith(base)) continue;
        if (fs.existsSync(f) && fs.statSync(f).isDirectory()) f = path.join(f, "index.html");
        if (!fs.existsSync(f)) continue;
        const ext = path.extname(f).toLowerCase();
        if (ext === ".html") return send(res, 200, MIME[".html"], html(f));
        if ([".ts", ".tsx", ".jsx", ".mts"].includes(ext)) { const b = await bundle(path.relative(state.root, f)); return send(res, 200, MIME[".js"], b.js); }
        return send(res, 200, MIME[ext] || "application/octet-stream", fs.readFileSync(f));
      }
      // páginas de framework, antes do fallback: nem Astro nem Next têm index.html
      const pagina = paginaAstro(p);
      if (pagina) return send(res, 200, MIME[".html"], await renderizaAstro(pagina));
      const rotaNext = globalThis.__next && globalThis.__next.rota(fs, path, state.root, p);
      if (rotaNext) {
        try {
          const corpo = await globalThis.__next.renderiza(contextoNext(), rotaNext, url);
          const doc = "<!doctype html><html><head>" + importMap() + CLIENT +
            "</head><body>" + corpo + "</body></html>";
          return send(res, 200, MIME[".html"], doc);
        } catch (e) {
          if (faltaReact(e)) {
            return send(res, 500, "text/plain; charset=utf-8",
              "O projeto é Next mas react e react-dom não estão instalados.\nRode npm install no terminal.");
          }
          throw e;
        }
      }
      // SPA fallback
      const index = path.join(state.root, "index.html");
      if (!path.extname(p) && fs.existsSync(index)) return send(res, 200, MIME[".html"], html(index));
      send(res, 404, "text/plain; charset=utf-8", recado404(p));
    } catch (e) {
      send(res, 500, "text/plain; charset=utf-8", String((e && e.message) || e) + "\n\n" + String((e && e.stack) || ""));
    }
  }

  globalThis.__devStart = (root, port, preset) => new Promise((resolve, reject) => {
    state.root = root; state.preset = preset || "plain";
    const srv = http.createServer(handle);
    srv.on("odete:ws", (sock) => { state.sockets.add(sock); sock.on("close", () => state.sockets.delete(sock)); });
    srv.on("error", reject);
    srv.listen(port || 5173, () => { state.server = srv; state.port = srv.address().port; resolve({ port: state.port }); });
  });

  globalThis.__devInvalidate = () => { state.cache.clear(); for (const s of state.sockets) s.send("reload"); return state.sockets.size; };
  globalThis.__devStop = () => { if (state.server) state.server.close(); state.server = null; return true; };
  globalThis.__devDiagnostics = () => state.diagnostics;
})();
