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
      // SPA fallback
      const index = path.join(state.root, "index.html");
      if (!path.extname(p) && fs.existsSync(index)) return send(res, 200, MIME[".html"], html(index));
      send(res, 404, "text/plain; charset=utf-8", "não encontrado: " + p);
    } catch (e) {
      send(res, 500, "text/plain; charset=utf-8", String(e && e.stack || e));
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
