// Pacote de dependências do dev server: o `optimizeDeps` do Vite, feito no iPad.
//
// O rebuild incremental do esbuild guarda a análise de cada módulo, mas não a ligação
// nem a impressão: editar uma letra do App.tsx religava e reimprimia o bundle inteiro,
// react-dom junto — 1,6 s de CPU num iPad sem JIT, num projeto Vite + React pequeno.
// Então os pacotes que o app importa (o que um import sem `./` resolve dentro de
// node_modules) saem do bundle do app e vêm deste pacote, feito uma vez:
//
//   - um bundle ESM só, com um registro: cada arquivo de pacote que o app importa vira
//     uma fábrica em `globalThis.__odeteDep`, e o app pega o módulo dali (bundler.js
//     explica os dois módulos pequenos que ficam no lugar do pacote). Um bundle só porque
//     o react-dom usa o `react` por dentro: dois bundles teriam dois Reacts e os hooks
//     quebrariam. Aqui há uma cópia de cada módulo, e ela é a do app também;
//   - servido em `/@odete/deps.js` (e a folha dos pacotes em `/@odete/deps.css`), com
//     ETag: recarregar a página não manda o megabyte de novo pelo servidor interpretado;
//   - guardado em `node_modules/.odete-deps/`, que anda junto com os pacotes (em projeto
//     do iCloud, `node_modules` é um atalho para `node_modules.nosync`, que o iCloud não
//     sincroniza, e o cache vai parar lá). Vale entre servidores e entre aberturas do app.
//
// A chave do cache é a versão deste formato e a do esbuild, os arquivos do registro, as
// opções que mudam a saída (NODE_ENV, defines do .env, JSX) e o conteúdo do lockfile. E
// o cache só vale se cada arquivo lido pelo build tiver o mesmo tamanho e a mesma data de
// quando foi lido: um pacote reinstalado ou editado à mão faz o pacote ser refeito.
//
// Um import de pacote novo refaz o pacote com o que já havia mais o novo, num contexto
// incremental (o que não mudou não é reanalisado), e o Preview recarrega. Refeito, ele
// passa a registrar todo o código que tem dentro: importar depois um arquivo que já
// estava lá (o `react-dom` que o `react-dom/client` usa) não refaz mais nada.
globalThis.__depsCria = function (root, prefixo) {
  const fs = require("fs"), path = require("path"), crypto = require("crypto");
  // Muda quando o formato do registro muda: pacote guardado no formato velho não serve.
  const FORMATO = 1;
  const ENTRADA = "__odete_deps.js";
  const TRAVAS = ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb"];
  // Quantos pacotes ficam em disco: trocar de branch e voltar não refaz nada.
  const GUARDADOS = 4;
  const CONTEXTO = prefixo + "@deps";
  const CODIGO = /\.([mc]?[jt]s|[jt]sx)$/i;
  // Sem pacote nenhum: o app sem dependências também importa o registro.
  const VAZIO = 'globalThis.__odeteDep = function (k) { throw new Error("[odete] " + k + " não está no pacote de dependências; recarregue a página"); };\n';

  // `chaves`: os arquivos que o registro sabe entregar. `modulos`: o código que o pacote
  // tem dentro, registrado ou não.
  const est = {
    chaves: new Set(), modulos: new Set(), js: null, css: null, etag: "", avisos: [],
    fila: Promise.resolve(),
    stats: { builds: 0, doDisco: 0 },
  };

  const opcoes = (chaves) => ({
    root, entries: [ENTRADA], format: "esm", platform: "browser", dev: true, outdir: "__odete_deps",
    externalMissing: true, memoria: false, bytes: true,
    virtuais: { [ENTRADA]: fonte(chaves) },
  });

  // A entrada do pacote: uma fábrica por arquivo, que só roda quando o app pede — como
  // no bundle inteiro, onde um pacote só roda quando alguém o importa. O `require` é pelo
  // caminho absoluto, que chega ao mesmo arquivo (e ao mesmo módulo) que o `require("react")`
  // de dentro do react-dom.
  function fonte(chaves) {
    const linhas = ["var feitos = {}, fabricas = {};"];
    for (const k of chaves) {
      linhas.push(`fabricas[${JSON.stringify(k)}] = function () { return require(${JSON.stringify(path.join(root, k))}); };`);
    }
    linhas.push(
      "globalThis.__odeteDep = function (k) {",
      "  if (Object.prototype.hasOwnProperty.call(feitos, k)) return feitos[k];",
      "  var f = fabricas[k];",
      '  if (!f) throw new Error("[odete] " + k + " não está no pacote de dependências; recarregue a página");',
      "  return (feitos[k] = f());",
      "};",
    );
    return linhas.join("\n");
  }

  // ---- cache em disco ----
  function pasta() {
    const nm = path.join(root, "node_modules");
    try { return fs.statSync(nm).isDirectory() ? path.join(nm, ".odete-deps") : null; } catch (e) { return null; }
  }

  // Tudo o que decide a saída, menos a lista de arquivos: pacote guardado com a mesma base
  // e com todos os arquivos pedidos (e mais alguns) também serve.
  function base() {
    const h = crypto.createHash("sha256");
    h.update(JSON.stringify([FORMATO, globalThis.esbuild.version, globalThis.__opcoesQueMudamASaida(opcoes([]))]));
    for (const t of TRAVAS) {
      try { const b = fs.readFileSync(path.join(root, t)); h.update(t + "\0"); h.update(b); } catch (e) { /* não tem */ }
    }
    return h.digest("hex");
  }

  const nomeDe = (b, chaves) => crypto.createHash("sha256").update(b + "\0" + chaves.join("\0")).digest("hex").slice(0, 20);

  // Cada arquivo que o build leu, com tamanho e data de quando foi lido.
  function carimbos(entradas) {
    const out = [];
    for (const f of entradas || []) {
      try { const st = fs.statSync(f); out.push([path.relative(root, f), st.size, st.mtimeMs]); } catch (e) { /* sumiu */ }
    }
    return out;
  }

  function valeAinda(meta) {
    for (const [rel, tamanho, data] of meta.entradas || []) {
      let st;
      try { st = fs.statSync(path.join(root, rel)); } catch (e) { return false; }
      if (st.size !== tamanho || Math.abs(st.mtimeMs - data) > 1) return false;
    }
    return true;
  }

  // O guardado com esta base que tem todos os arquivos pedidos: o de nome exato, se houver;
  // senão o menor que os contenha (um import removido não refaz nada).
  function procura(b, chaves) {
    const dir = pasta();
    if (!dir) return null;
    let nomes;
    try { nomes = fs.readdirSync(dir).filter((n) => n.endsWith(".json")); } catch (e) { return null; }
    const exato = nomeDe(b, chaves) + ".json";
    nomes.sort((x, y) => (x === exato ? -1 : y === exato ? 1 : 0));
    let melhor = null;
    for (const n of nomes) {
      let meta;
      try { meta = JSON.parse(fs.readFileSync(path.join(dir, n), "utf8")); } catch (e) { continue; }
      if (meta.formato !== FORMATO || meta.base !== b) continue;
      const tem = new Set(meta.chaves);
      if (!chaves.every((k) => tem.has(k))) continue;
      if (!melhor || meta.chaves.length < melhor.chaves.length) melhor = meta;
      if (n === exato) break;
    }
    if (!melhor || !valeAinda(melhor)) return null;
    try {
      const js = fs.readFileSync(path.join(dir, melhor.nome + ".js"));
      const css = melhor.css ? fs.readFileSync(path.join(dir, melhor.nome + ".css")) : null;
      // Usado agora: fica entre os que sobram na limpeza.
      try { fs.writeFileSync(path.join(dir, melhor.nome + ".json"), JSON.stringify(melhor)); } catch (e) { /* só a ordem */ }
      return { chaves: melhor.chaves, js, css, hash: melhor.hash, avisos: melhor.avisos || [], modulos: (melhor.entradas || []).map((e) => e[0]) };
    } catch (e) {
      return null;
    }
  }

  // Grava o pacote e só depois o índice dele: um pacote pela metade nunca é achado.
  function guarda(b, chaves, r) {
    const dir = pasta();
    if (!dir) return;
    const nome = nomeDe(b, chaves);
    try {
      fs.mkdirSync(dir, { recursive: true });
      const grava = (arq, conteudo) => {
        const tmp = path.join(dir, arq + ".tmp");
        fs.writeFileSync(tmp, conteudo);
        fs.renameSync(tmp, path.join(dir, arq));
      };
      grava(nome + ".js", r.js);
      if (r.css) grava(nome + ".css", r.css);
      grava(nome + ".json", JSON.stringify({
        formato: FORMATO, base: b, nome, chaves, hash: r.hash, css: !!r.css, avisos: r.avisos, entradas: carimbos(r.entradas),
      }));
      limpa(dir);
    } catch (e) {
      // Cache é conforto: sem disco, o pacote segue em memória e o servidor funciona.
    }
  }

  function limpa(dir) {
    const metas = [];
    for (const n of fs.readdirSync(dir)) {
      // Sobra de uma gravação interrompida (o app fechou no meio).
      if (n.endsWith(".tmp")) { try { fs.unlinkSync(path.join(dir, n)); } catch (e) { /* já foi */ } continue; }
      if (!n.endsWith(".json")) continue;
      try { metas.push([n.slice(0, -5), fs.statSync(path.join(dir, n)).mtimeMs]); } catch (e) { /* sumiu */ }
    }
    metas.sort((a, b) => b[1] - a[1]);
    for (const [nome] of metas.slice(GUARDADOS)) {
      for (const ext of [".json", ".js", ".css"]) {
        try { fs.unlinkSync(path.join(dir, nome + ext)); } catch (e) { /* não tinha */ }
      }
    }
  }

  // ---- montagem ----
  // O módulo ESM que o esbuild teve de iniciar de forma assíncrona. Procura pelo texto e
  // só confere de perto onde ele aparece: expressão regular no megabyte inteiro, sem JIT,
  // é o interpretador de regex andando caractere por caractere.
  function comAwaitNoTopo(texto) {
    for (let i = texto.indexOf("= __esm({"); i >= 0; i = texto.indexOf("= __esm({", i + 1)) {
      const m = /^= __esm\(\{\s*async "([^"]+)"/.exec(texto.slice(i, i + 300));
      if (m) return m[1];
    }
    return null;
  }

  function aplica(chaves, r) {
    est.chaves = new Set(chaves);
    est.modulos = new Set(r.modulos.filter((m) => CODIGO.test(m)));
    est.js = r.js;
    est.css = r.css;
    est.etag = '"' + r.hash + '"';
    est.avisos = r.avisos || [];
  }

  // Refazer registra também todo o código que o pacote já tinha dentro: o próximo import
  // que cair num deles (`react-dom` depois de `react-dom/client`, que já o usa por dentro)
  // não refaz nada. Não dá para fazer isso no primeiro build — só depois dele se sabe o
  // que entrou — e fazer dois builds seria pagar a ligação duas vezes.
  async function atualiza(pedidas) {
    const faltam = pedidas.filter((k) => !est.chaves.has(k));
    if (!faltam.length) return { ok: true };
    const chaves = [...new Set([...est.chaves, ...est.modulos, ...pedidas])].sort();
    const b = base();
    const guardado = procura(b, chaves);
    if (guardado) {
      est.stats.doDisco++;
      aplica(guardado.chaves, guardado);
      return { ok: true, doDisco: true };
    }
    est.stats.builds++;
    const r = await globalThis.__rebuild(CONTEXTO, opcoes(chaves));
    if (!r.ok) return { ok: false, errors: r.errors, warnings: r.warnings };
    const js = r.saidas.find((f) => f.path.endsWith(".js"));
    const css = r.saidas.find((f) => f.path.endsWith(".css"));
    // Pacote ESM com `await` no topo não vira fábrica: o esbuild aceita o `require`, mas o
    // embrulha num init assíncrono e devolve o módulo antes de ele terminar — o app leria
    // `undefined` sem erro nenhum. No bundle inteiro ele funciona; então quem decide é
    // quem chamou (o servidor volta a levar os pacotes no bundle do app).
    const assincrono = js && comAwaitNoTopo(js.text);
    if (assincrono) {
      return { ok: false, errors: [{ text: `${assincrono} usa await no topo e não pode ir para o pacote de dependências` }], warnings: [] };
    }
    const feito = {
      js: js ? js.contents : VAZIO, css: css && css.contents.length ? css.contents : null,
      hash: (js ? js.hash : "") + (css ? css.hash : ""), avisos: r.warnings, entradas: r.entradas,
      modulos: (r.entradas || []).map((f) => path.relative(root, f)),
    };
    aplica(chaves, feito);
    guarda(b, chaves, feito);
    return { ok: true };
  }

  return {
    // Garante que o pacote tem estes arquivos. Um de cada vez: dois bundles de entrada
    // pedindo pacotes ao mesmo tempo esperam o mesmo build.
    garante(pedidas) {
      const vez = est.fila.then(() => atualiza(pedidas));
      est.fila = vez.catch(() => {});
      return vez;
    },
    pronto: () => est.fila,
    js: () => est.js || VAZIO,
    css: () => est.css || "",
    etag: () => est.etag || '"vazio"',
    avisos: () => est.avisos,
    // Esquece o que está em memória (o disco fica): npm install, .env, botão Rebuild. O
    // próximo pedido confere o cache de novo, e um pacote reinstalado não passa na
    // conferência das datas. Na fila, depois de um build que esteja correndo — senão ele
    // terminaria depois e poria de volta o pacote velho.
    esquece() {
      const vez = est.fila.then(() => {
        est.chaves = new Set(); est.modulos = new Set(); est.js = null; est.css = null; est.etag = ""; est.avisos = [];
      });
      est.fila = vez.catch(() => {});
      return vez;
    },
    estatisticas: () => ({ depsBuilds: est.stats.builds, depsDoDisco: est.stats.doDisco, depsModulos: est.chaves.size }),
    // Há pacote guardado com esta base (mesmo lock, mesmo .env, mesmo esbuild) e com os
    // arquivos intactos? O aquecimento pergunta antes de fazer o build do app só para
    // descobrir as chaves — se já há, o primeiro `npm run dev` já cai no caminho rápido.
    jaTemPacote() {
      const dir = pasta();
      if (!dir) return false;
      const b = base();
      let nomes;
      try { nomes = fs.readdirSync(dir).filter((n) => n.endsWith(".json")); } catch (e) { return false; }
      for (const n of nomes) {
        try {
          const meta = JSON.parse(fs.readFileSync(path.join(dir, n), "utf8"));
          if (meta.formato === FORMATO && meta.base === b && valeAinda(meta)) return true;
        } catch (e) { /* índice quebrado: não conta */ }
      }
      return false;
    },
  };
};
