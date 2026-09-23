// Aliases de import: `@/components/Botao` e companhia.
//
// O `@/` do shadcn, do template do Next e de meio mundo não existia aqui: no dev server
// o import virava externo (o navegador pedia `@/lib/utils` e parava) e no build aparecia
// "Não achei o pacote … Rode npm install", que manda a pessoa instalar um pacote que não
// existe. Duas fontes, como no Vite e no esbuild:
//   - `compilerOptions.paths` e `baseUrl` do tsconfig.json (ou do jsconfig.json), com
//     `extends` (arquivo ou pacote) e os tsconfig de `references` — o template do Vite
//     põe as opções no tsconfig.app.json e deixa o tsconfig.json só com as referências;
//   - `resolve.alias` do vite.config, objeto ou lista de `{ find, replacement }`. A config
//     não roda (ela importa o próprio Vite, que não sobe aqui): o valor é lido do texto,
//     e os jeitos comuns de escrever a pasta são entendidos — texto literal,
//     `path.resolve(__dirname, "./src")`, `fileURLToPath(new URL("./src", import.meta.url))`.
// O alias do vite.config vem antes, como no Vite (o plugin de alias roda antes da
// resolução); o `paths` do tsconfig depois.
(function () {
  const fs = require("fs"), path = require("path"), H = globalThis.__odete;

  const TSCONFIGS = ["tsconfig.json", "jsconfig.json"];
  const VITE_CONFIGS = ["vite.config.ts", "vite.config.mts", "vite.config.js", "vite.config.mjs", "vite.config.cts", "vite.config.cjs"];

  // Por raiz: as regras e as datas dos arquivos de onde saíram.
  const porRaiz = new Map(); // raiz → { datas: Map(arquivo → mt), vite: [...], paths: [...], baseUrl }
  let versao = 0;

  const mtimeDe = (f) => { try { return fs.statSync(f).mtimeMs; } catch (e) { return null; } };

  // ---- JSON com comentário ----
  // O tsconfig aceita `//`, `/* */` e vírgula sobrando; o JSON.parse não.
  function jsonc(t) {
    let out = "", i = 0;
    while (i < t.length) {
      const c = t[i];
      if (c === '"') {
        let j = i + 1;
        while (j < t.length && t[j] !== '"') j += t[j] === "\\" ? 2 : 1;
        out += t.slice(i, j + 1); i = j + 1; continue;
      }
      if (c === "/" && t[i + 1] === "/") { while (i < t.length && t[i] !== "\n") i++; continue; }
      if (c === "/" && t[i + 1] === "*") { const f = t.indexOf("*/", i + 2); i = f < 0 ? t.length : f + 2; continue; }
      out += c; i++;
    }
    return JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
  }

  // ---- tsconfig ----
  function achaExtends(e, dir) {
    if (e.startsWith("./") || e.startsWith("../") || e.startsWith("/")) {
      const abs = path.resolve(dir, e);
      for (const c of [abs, abs + ".json", path.join(abs, "tsconfig.json")]) {
        try { if (fs.statSync(c).isFile()) return c; } catch (err) { /* próximo */ }
      }
      return null;
    }
    for (const c of [e, e + ".json", e + "/tsconfig.json"]) {
      const r = H.resolve(c, path.join(dir, "_.json"));
      if (typeof r === "string") return r;
    }
    return null;
  }

  // As opções de um tsconfig com as herdadas. `paths` guarda a pasta de onde os alvos
  // são relativos: o `baseUrl` se houver, senão a pasta do tsconfig que declarou `paths`.
  function leTsconfig(arquivo, datas, vistos) {
    if (vistos.has(arquivo)) return {};
    vistos.add(arquivo);
    datas.set(arquivo, mtimeDe(arquivo));
    let j;
    try { j = jsonc(fs.readFileSync(arquivo, "utf8")); } catch (e) { return {}; }
    const dir = path.dirname(arquivo);
    let herdado = {};
    const ext = j.extends ? (Array.isArray(j.extends) ? j.extends : [j.extends]) : [];
    for (const e of ext) {
      const f = typeof e === "string" ? achaExtends(e, dir) : null;
      if (f) herdado = Object.assign({}, herdado, leTsconfig(f, datas, vistos));
    }
    const co = j.compilerOptions || {};
    const r = Object.assign({}, herdado);
    if (typeof co.baseUrl === "string") r.baseUrl = path.resolve(dir, co.baseUrl);
    if (co.paths && typeof co.paths === "object") { r.paths = co.paths; r.pathsDir = null; r.pathsDe = dir; }
    if (r.paths) r.pathsBase = r.baseUrl || r.pathsDe;
    r.references = (j.references || []).map((x) => x && typeof x.path === "string" ? path.resolve(dir, x.path) : null).filter(Boolean);
    return r;
  }

  function regrasDePaths(paths, base) {
    const regras = [];
    for (const chave of Object.keys(paths)) {
      const alvos = Array.isArray(paths[chave]) ? paths[chave] : [paths[chave]];
      const i = chave.indexOf("*");
      regras.push({
        prefixo: i < 0 ? chave : chave.slice(0, i), sufixo: i < 0 ? "" : chave.slice(i + 1), estrela: i >= 0,
        alvos: alvos.filter((a) => typeof a === "string").map((a) => path.resolve(base, a)),
      });
    }
    // O prefixo mais longo ganha, como no TypeScript.
    return regras.sort((a, b) => b.prefixo.length - a.prefixo.length);
  }

  function carregaTsconfig(raiz, datas) {
    const out = { paths: [], baseUrl: null };
    for (const n of TSCONFIGS) {
      const f = path.join(raiz, n);
      datas.set(f, mtimeDe(f));
      if (datas.get(f) == null) continue;
      const vistos = new Set();
      const principal = leTsconfig(f, datas, vistos);
      const todos = [principal];
      for (const ref of principal.references || []) {
        let alvo = ref;
        try { if (fs.statSync(ref).isDirectory()) alvo = path.join(ref, "tsconfig.json"); } catch (e) { continue; }
        todos.push(leTsconfig(alvo, datas, vistos));
      }
      for (const t of todos) {
        if (t.paths) out.paths = out.paths.concat(regrasDePaths(t.paths, t.pathsBase));
        if (!out.baseUrl && t.baseUrl) out.baseUrl = t.baseUrl;
      }
      break;
    }
    out.paths.sort((a, b) => b.prefixo.length - a.prefixo.length);
    return out;
  }

  // ---- vite.config ----
  // Só o trecho de `alias:`, lido como literal. O que não dá para ler fica de fora: um
  // alias a menos é o que já era antes.
  function carregaVite(raiz, datas) {
    for (const n of VITE_CONFIGS) {
      const f = path.join(raiz, n);
      datas.set(f, mtimeDe(f));
      if (datas.get(f) == null) continue;
      let t;
      try { t = fs.readFileSync(f, "utf8"); } catch (e) { return []; }
      return leAliasDoVite(semComentarios(t), path.dirname(f), raiz);
    }
    return [];
  }

  function semComentarios(t) {
    return t.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'`\\])\/\/[^\n]*/g, "$1");
  }

  function leAliasDoVite(t, dir, raiz) {
    const m = /\balias\s*:\s*([[{])/.exec(t);
    if (!m) return [];
    const inicio = m.index + m[0].length - 1;
    const fim = fecha(t, inicio);
    if (fim < 0) return [];
    const corpo = t.slice(inicio + 1, fim);
    const regras = [];
    if (m[1] === "{") {
      for (const parte of partesDoTopo(corpo)) {
        const i = doisPontos(parte);
        if (i < 0) continue;
        const chave = literal(parte.slice(0, i).trim()) ?? (/^[\w$]+$/.test(parte.slice(0, i).trim()) ? parte.slice(0, i).trim() : null);
        const valor = expressao(parte.slice(i + 1).trim(), dir, raiz);
        if (chave != null && valor != null) regras.push({ find: chave, replacement: valor });
      }
    } else {
      for (const parte of partesDoTopo(corpo)) {
        const p = parte.trim();
        if (!p.startsWith("{")) continue;
        let find = null, replacement = null;
        for (const campo of partesDoTopo(p.slice(1, fecha(p, 0)))) {
          const i = doisPontos(campo);
          if (i < 0) continue;
          const k = campo.slice(0, i).trim().replace(/^["']|["']$/g, "");
          const v = campo.slice(i + 1).trim();
          if (k === "find") find = literal(v) ?? regex(v);
          if (k === "replacement") replacement = expressao(v, dir, raiz);
        }
        if (find != null && replacement != null) regras.push({ find, replacement });
      }
    }
    return regras;
  }

  // Índice do fechamento do `{`/`[`/`(` em `i`, pulando texto entre aspas.
  function fecha(t, i) {
    const pares = { "{": "}", "[": "]", "(": ")" };
    const pilha = [];
    for (let j = i; j < t.length; j++) {
      const c = t[j];
      if (c === '"' || c === "'" || c === "`") { j = fimDoTexto(t, j); continue; }
      if (pares[c]) pilha.push(pares[c]);
      else if (c === pilha[pilha.length - 1]) { pilha.pop(); if (!pilha.length) return j; }
    }
    return -1;
  }
  function fimDoTexto(t, i) {
    const q = t[i];
    let j = i + 1;
    while (j < t.length && t[j] !== q) j += t[j] === "\\" ? 2 : 1;
    return j;
  }
  // Separa por vírgula de primeiro nível.
  function partesDoTopo(t) {
    const partes = [];
    let nivel = 0, ini = 0;
    for (let j = 0; j < t.length; j++) {
      const c = t[j];
      if (c === '"' || c === "'" || c === "`") { j = fimDoTexto(t, j); continue; }
      if (c === "/" && nivel === 0 && /[,:(\[{]\s*$|^\s*$/.test(t.slice(ini, j))) { j = fimDaRegex(t, j); continue; }
      if (c === "{" || c === "[" || c === "(") nivel++;
      else if (c === "}" || c === "]" || c === ")") nivel--;
      else if (c === "," && nivel === 0) { partes.push(t.slice(ini, j)); ini = j + 1; }
    }
    if (t.slice(ini).trim()) partes.push(t.slice(ini));
    return partes;
  }
  function fimDaRegex(t, i) {
    let j = i + 1, classe = false;
    while (j < t.length) {
      const c = t[j];
      if (c === "\\") { j += 2; continue; }
      if (c === "[") classe = true;
      else if (c === "]") classe = false;
      else if (c === "/" && !classe) break;
      j++;
    }
    return j;
  }
  function doisPontos(parte) {
    for (let j = 0; j < parte.length; j++) {
      const c = parte[j];
      if (c === '"' || c === "'" || c === "`") { j = fimDoTexto(parte, j); continue; }
      if (c === ":") return j;
    }
    return -1;
  }

  function literal(v) {
    const m = /^(["'`])((?:\\.|(?!\1)[^\\])*)\1$/.exec(v);
    if (!m || (m[1] === "`" && m[2].indexOf("${") >= 0)) return null;
    return m[2].replace(/\\(.)/g, "$1");
  }
  function regex(v) {
    const m = /^\/((?:\\.|[^/])+)\/([gimsuy]*)$/.exec(v);
    if (!m) return null;
    try { return new RegExp(m[1], m[2]); } catch (e) { return null; }
  }

  // A pasta de um alias, dos jeitos que se escreve num vite.config.
  function expressao(v, dir, raiz) {
    v = v.trim().replace(/\s+as\s+\w+$/, "");
    const lit = literal(v);
    if (lit != null) return lit;
    // `${__dirname}/src`
    const tpl = /^`([^`]*)`$/.exec(v);
    if (tpl) {
      const s = tpl[1].replace(/\$\{\s*(__dirname|import\.meta\.dirname)\s*\}/g, dir).replace(/\$\{\s*process\.cwd\(\)\s*\}/g, raiz);
      return s.indexOf("${") >= 0 ? null : s;
    }
    // fileURLToPath(new URL("./src", import.meta.url)) — e `url.fileURLToPath`, e o `.pathname`.
    let m = /^(?:[\w$]+\.)?fileURLToPath\(\s*new\s+URL\(\s*(["'`][^"'`]*["'`])\s*,\s*import\.meta\.url\s*\)\s*\)$/.exec(v) ||
      /^new\s+URL\(\s*(["'`][^"'`]*["'`])\s*,\s*import\.meta\.url\s*\)\.pathname$/.exec(v);
    if (m) return path.resolve(dir, literal(m[1]));
    // path.resolve(__dirname, "./src"), resolve(...), path.join(...), join(...)
    m = /^(?:(?:node:)?[\w$]+\.)?(resolve|join)\(([\s\S]*)\)$/.exec(v);
    if (m) {
      const args = [];
      for (const a of partesDoTopo(m[2])) {
        const x = a.trim();
        if (x === "__dirname" || x === "import.meta.dirname") args.push(dir);
        else if (x === "process.cwd()") args.push(raiz);
        else {
          const l = literal(x);
          if (l == null) return null;
          args.push(l);
        }
      }
      if (!args.length) return null;
      return m[1] === "join" ? path.join(...args) : path.resolve(dir, ...args);
    }
    return null;
  }

  // ---- uso ----
  // Confere as datas dos arquivos de config e relê o que mudou. O plugin chama isto no
  // começo de cada build: resolver um import não faz `stat` de config nenhuma.
  function prepara(raiz, vigiados) {
    let g = porRaiz.get(raiz);
    let valido = !!g;
    if (g) for (const [f, mt] of g.datas) if (mtimeDe(f) !== mt) { valido = false; break; }
    if (!valido) {
      const datas = new Map();
      const ts = carregaTsconfig(raiz, datas);
      g = { datas, vite: carregaVite(raiz, datas), paths: ts.paths, baseUrl: ts.baseUrl };
      porRaiz.set(raiz, g);
      versao++;
    }
    if (vigiados) for (const [f, mt] of g.datas) if (mt != null) vigiados.add(f);
    return versao;
  }

  // Os caminhos a tentar para `spec`, em ordem; `null` se nenhum alias se aplica. O que
  // volta pode ser um caminho absoluto ou outro nome de pacote (`vue` → `vue/dist/…`).
  // O `paths` do tsconfig vale para o código do projeto, não para o de dentro de um
  // pacote — como no esbuild: um `"*": ["./src/types/*"]` não pode desviar o `react` que o
  // react-dom importa. O alias do Vite vale para todos, como no Vite.
  function aplica(raiz, spec, vigiados, importer) {
    let g = porRaiz.get(raiz);
    if (!g) { prepara(raiz, vigiados); g = porRaiz.get(raiz); }
    for (const r of g.vite) {
      if (r.find instanceof RegExp) {
        if (r.find.test(spec)) return [spec.replace(r.find, r.replacement)];
      } else if (spec === r.find || spec.startsWith(r.find + "/")) {
        return [r.replacement + spec.slice(r.find.length)];
      }
    }
    if (importer && (importer.indexOf("/node_modules/") >= 0 || importer.indexOf("/node_modules.nosync/") >= 0)) return null;
    for (const r of g.paths) {
      if (r.estrela) {
        if (spec.length < r.prefixo.length + r.sufixo.length || !spec.startsWith(r.prefixo) || !spec.endsWith(r.sufixo)) continue;
        const meio = spec.slice(r.prefixo.length, spec.length - r.sufixo.length);
        return r.alvos.map((a) => a.replace("*", meio));
      }
      if (spec === r.prefixo) return r.alvos.slice();
    }
    return null;
  }

  // `baseUrl`: `import "components/Botao"` com `baseUrl: "src"` é o src/components/Botao.
  function daBase(raiz, spec) {
    const g = porRaiz.get(raiz);
    return g && g.baseUrl ? path.join(g.baseUrl, spec) : null;
  }

  function ehConfig(f) {
    const n = path.basename(f);
    return /^(tsconfig|jsconfig)(\..+)?\.json$/.test(n) || VITE_CONFIGS.includes(n);
  }

  globalThis.__odeteAlias = { prepara, aplica, daBase, ehConfig, versao: () => versao, jsonc };
})();
