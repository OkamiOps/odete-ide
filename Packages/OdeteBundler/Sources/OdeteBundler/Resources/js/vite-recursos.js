// O que o Vite acrescenta ao `import` e que o esbuild não conhece:
//   - `import.meta.glob("./paginas/*.tsx")` (preguiçoso, com `() => import(…)`) e
//     `{ eager: true }` (com import estático), com `import:` (um export só), `query:` e o
//     antigo `as:`; e `import.meta.globEager`;
//   - `?raw` (o texto do arquivo), `?url` (o endereço dele), `?inline` (o CSS pronto, em
//     texto, ou o arquivo em data URL) e `?worker` (um construtor de Worker com o código
//     empacotado dentro).
// O glob é trocado no código-fonte antes do esbuild ler — a lista de arquivos vira
// imports comuns, que passam pelo resto do caminho como qualquer outro.
(function () {
  const fs = require("fs"), path = require("path");

  // ---- literais ----
  // Os argumentos do glob têm de ser literais, como no Vite. Lidos por um analisador
  // pequeno em vez de `eval`: o build não roda código do projeto.
  function leLiteral(t, i) {
    i = pula(t, i);
    const c = t[i];
    if (c === '"' || c === "'" || c === "`") {
      let j = i + 1, s = "";
      while (j < t.length && t[j] !== c) {
        if (t[j] === "\\") { s += t[j + 1]; j += 2; continue; }
        if (c === "`" && t[j] === "$" && t[j + 1] === "{") throw new Error("template");
        s += t[j++];
      }
      return [s, j + 1];
    }
    if (c === "[") {
      const arr = [];
      i++;
      for (;;) {
        i = pula(t, i);
        if (t[i] === "]") return [arr, i + 1];
        const [v, j] = leLiteral(t, i);
        arr.push(v);
        i = pula(t, j);
        if (t[i] === ",") i++;
      }
    }
    if (c === "{") {
      const obj = {};
      i++;
      for (;;) {
        i = pula(t, i);
        if (t[i] === "}") return [obj, i + 1];
        let chave;
        if (t[i] === '"' || t[i] === "'") { const [k, j] = leLiteral(t, i); chave = k; i = j; }
        else { const m = /^[\w$]+/.exec(t.slice(i)); if (!m) throw new Error("chave"); chave = m[0]; i += chave.length; }
        i = pula(t, i);
        if (t[i] !== ":") throw new Error(":");
        const [v, j] = leLiteral(t, i + 1);
        obj[chave] = v;
        i = pula(t, j);
        if (t[i] === ",") i++;
      }
    }
    const m = /^(true|false|null|-?\d+(?:\.\d+)?)/.exec(t.slice(i));
    if (m) return [JSON.parse(m[1]), i + m[1].length];
    throw new Error("literal");
  }
  function pula(t, i) {
    for (;;) {
      while (i < t.length && /\s/.test(t[i])) i++;
      if (t[i] === "/" && t[i + 1] === "/") { while (i < t.length && t[i] !== "\n") i++; continue; }
      if (t[i] === "/" && t[i + 1] === "*") { const f = t.indexOf("*/", i + 2); i = f < 0 ? t.length : f + 2; continue; }
      return i;
    }
  }

  // ---- arquivos do glob ----
  function paraRegex(p) { return globalThis.__odeteTailwind.globParaRegex(p); }

  // Os arquivos que batem com os padrões. `node_modules` e pastas com ponto só entram se
  // o padrão pedir (`exhaustive`, no Vite).
  function arquivos(padroes, dirDoArquivo, raiz, ctx, completo) {
    const positivos = [], negativos = [];
    for (const p0 of padroes) {
      const nega = p0.startsWith("!");
      const p = nega ? p0.slice(1) : p0;
      let abs;
      if (p.startsWith("/")) abs = path.join(raiz, p);
      else if (p.startsWith("./") || p.startsWith("../")) abs = path.resolve(dirDoArquivo, p);
      else {
        const a = globalThis.__odeteAlias.aplica(raiz, p, ctx.vigiados);
        if (!a || !a.length) continue;
        abs = path.resolve(raiz, a[0]);
      }
      (nega ? negativos : positivos).push(abs);
    }
    const achados = new Set();
    for (const abs of positivos) {
      const partes = abs.split("/");
      const fixas = [];
      for (const x of partes) { if (/[*?{[]/.test(x)) break; fixas.push(x); }
      const pasta = fixas.join("/") || "/";
      const re = paraRegex(partes.slice(fixas.length).join("/") || "*");
      const pede = (n) => abs.indexOf("/" + n) >= 0;
      const anda = (dir) => {
        ctx.pastas.add(dir);
        let itens;
        try { itens = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
        for (const d of itens) {
          const f = path.join(dir, d.name);
          if (d.isDirectory()) {
            if (!completo && ((d.name === "node_modules" && !pede("node_modules")) || (d.name[0] === "." && !pede(d.name)))) continue;
            anda(f);
          } else if (re.test(path.relative(pasta, f))) achados.add(f);
        }
      };
      anda(pasta);
    }
    const negs = negativos.map((n) => {
      const partes = n.split("/");
      const fixas = [];
      for (const x of partes) { if (/[*?{[]/.test(x)) break; fixas.push(x); }
      const pasta = fixas.join("/") || "/";
      const re = paraRegex(partes.slice(fixas.length).join("/") || "*");
      return (f) => f.startsWith(pasta + "/") && re.test(path.relative(pasta, f));
    });
    return [...achados].filter((f) => !negs.some((n) => n(f))).sort();
  }

  // A chave do objeto, como o Vite escreve: relativa a quem importa se o padrão é
  // relativo, a partir da raiz (`/src/…`) se é absoluto ou alias.
  function chaveDe(f, dirDoArquivo, raiz, relativo) {
    if (relativo) {
      const r = path.relative(dirDoArquivo, f);
      return r.startsWith(".") ? r : "./" + r;
    }
    return "/" + path.relative(raiz, f);
  }

  // Troca cada `import.meta.glob(…)` do código por um objeto. Devolve o código novo, ou
  // `null` se não havia glob (quase sempre: a procura é um indexOf).
  let seq = 0;
  function transformaGlob(codigo, arquivo, raiz, ctx) {
    if (codigo.indexOf("import.meta.glob") < 0) return null;
    const dir = path.dirname(arquivo);
    const topo = [];
    let saida = "", ultimo = 0, n = 0;
    const re = /import\.meta\.glob(Eager)?\s*(?:<[^>()]*>)?\s*\(/g;
    let m;
    while ((m = re.exec(codigo))) {
      let args, fim;
      try {
        const [padrao, j] = leLiteral(codigo, m.index + m[0].length);
        let i = pula(codigo, j), opcoes = {};
        if (codigo[i] === ",") {
          i = pula(codigo, i + 1);
          if (codigo[i] !== ")") { const [o, k] = leLiteral(codigo, i); opcoes = o; i = pula(codigo, k); if (codigo[i] === ",") i = pula(codigo, i + 1); }
        }
        if (codigo[i] !== ")") continue;
        args = { padroes: Array.isArray(padrao) ? padrao : [padrao], opcoes };
        fim = i + 1;
      } catch (e) {
        continue; // não é literal: fica como está, e o esbuild avisa que import.meta.glob não existe
      }
      const o = args.opcoes;
      const ansioso = !!m[1] || o.eager === true;
      let consulta = typeof o.query === "string" ? o.query : o.query && typeof o.query === "object" ? "?" + Object.keys(o.query).map((k) => o.query[k] === true || o.query[k] === "" ? k : k + "=" + o.query[k]).join("&") : "";
      if (!consulta && (o.as === "raw" || o.as === "url")) consulta = "?" + o.as;
      if (consulta && consulta[0] !== "?") consulta = "?" + consulta;
      const nome = typeof o.import === "string" ? o.import : o.as === "raw" || o.as === "url" ? "default" : null;
      const relativo = args.padroes.every((p) => (p.startsWith("!") ? p.slice(1) : p).startsWith("."));
      const lista = arquivos(args.padroes, dir, raiz, ctx, o.exhaustive === true).filter((f) => f !== arquivo);
      const partes = [];
      for (const f of lista) {
        const chave = chaveDe(f, dir, raiz, relativo);
        const alvo = JSON.stringify(chave + consulta);
        if (ansioso) {
          const v = "__odete_glob_" + seq + "_" + n++;
          if (nome === "default") topo.push(`import ${v} from ${alvo};`);
          else if (nome && nome !== "*") topo.push(`import { ${nome} as ${v} } from ${alvo};`);
          else topo.push(`import * as ${v} from ${alvo};`);
          partes.push(`${JSON.stringify(chave)}: ${v}`);
        } else if (nome && nome !== "*") {
          partes.push(`${JSON.stringify(chave)}: () => import(${alvo}).then((m) => m[${JSON.stringify(nome)}])`);
        } else {
          partes.push(`${JSON.stringify(chave)}: () => import(${alvo})`);
        }
      }
      saida += codigo.slice(ultimo, m.index) + "Object.assign({" + partes.join(", ") + "})";
      ultimo = fim;
      re.lastIndex = fim;
    }
    seq++;
    if (!ultimo) return null;
    return topo.join("\n") + (topo.length ? "\n" : "") + saida + codigo.slice(ultimo);
  }

  // ---- ?raw, ?url, ?inline, ?worker ----
  const CONSULTAS = ["raw", "url", "inline", "worker", "sharedworker"];
  // `./a.svg?raw` → { caminho: "./a.svg", consulta: "raw", resto: "" }; o que não é
  // consulta do Vite volta `null` (o `?` pode ser parte de um nome de arquivo).
  function separa(spec) {
    const i = spec.lastIndexOf("?");
    if (i < 0) return null;
    const params = spec.slice(i + 1).split("&");
    const tipo = params.find((p) => CONSULTAS.includes(p));
    if (!tipo) return null;
    return { caminho: spec.slice(0, i), consulta: tipo, params };
  }

  // O endereço de um arquivo no dev server: ele serve a raiz do projeto.
  function urlDoDev(abs, raiz) {
    const rel = path.relative(raiz, abs);
    return rel.startsWith("..") ? "/@fs" + abs : "/" + rel.split(path.sep).join("/");
  }

  const MIME = { ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp", ".avif": "image/avif", ".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf", ".json": "application/json", ".txt": "text/plain", ".js": "text/javascript", ".css": "text/css", ".wasm": "application/wasm" };

  async function carrega(abs, consulta, params, ctx) {
    ctx.vigiados.add(abs);
    const resolveDir = path.dirname(abs);
    if (consulta === "raw") {
      return { contents: "export default " + JSON.stringify(fs.readFileSync(abs, "utf8")) + ";\n", loader: "js", resolveDir };
    }
    if (consulta === "url") {
      if (ctx.dev) return { contents: "export default " + JSON.stringify(urlDoDev(abs, ctx.root)) + ";\n", loader: "js", resolveDir };
      // No build o arquivo sai com hash, pelo esbuild; o pequeno vai embutido, como no Vite.
      const bytes = fs.readFileSync(abs);
      const comoArquivo = typeof ctx.limiteDeInline !== "number" ? false : bytes.length > ctx.limiteDeInline || params.includes("no-inline");
      return { contents: bytes, loader: comoArquivo ? "file" : "dataurl", resolveDir };
    }
    if (consulta === "inline") {
      if (globalThis.__odeteEstilos.ehEstilo(abs)) {
        const r = await globalThis.__odeteEstilos.carrega(abs, ctx);
        if (r.errors) return r;
        let css = r.contents;
        const t = await globalThis.esbuild.transform(css, { loader: "css", minify: !ctx.dev, supported: ctx.dev ? {} : { nesting: false }, logLevel: "silent" });
        css = t.code;
        return { contents: "export default " + JSON.stringify(css) + ";\n", loader: "js", resolveDir };
      }
      const tipo = MIME[path.extname(abs).toLowerCase()] || "application/octet-stream";
      const b64 = Buffer.from(fs.readFileSync(abs)).toString("base64");
      return { contents: "export default " + JSON.stringify("data:" + tipo + ";base64," + b64) + ";\n", loader: "js", resolveDir };
    }
    // ?worker: o código do worker empacotado à parte (IIFE, que todo navegador aceita num
    // Worker clássico) e entregue num Blob — funciona igual no dev e no build.
    const r = await globalThis.__buildBruto({
      root: ctx.root, entries: [abs], format: "iife", platform: "browser", dev: ctx.dev, minify: !ctx.dev,
      outdir: "__odete_worker", metafile: true,
    });
    if (!r.ok) return { errors: r.errors.map((e) => ({ text: e.text, location: e.file ? { file: e.file, line: e.line, column: e.column, lineText: e.lineText } : null })) };
    for (const f of r.entradas || []) ctx.vigiados.add(f);
    const js = r.saidas.find((s) => s.path.endsWith(".js"));
    const classe = consulta === "sharedworker" ? "SharedWorker" : "Worker";
    return {
      contents: `const codigo = ${JSON.stringify(js ? js.text : "")};\n` +
        `export default function WorkerWrapper(options) {\n` +
        `  const url = URL.createObjectURL(new Blob([codigo], { type: "text/javascript" }));\n` +
        `  try { return new ${classe}(url, options); } finally { URL.revokeObjectURL(url); }\n` +
        `}\n`,
      loader: "js", resolveDir,
    };
  }

  globalThis.__odeteVite = { transformaGlob, separa, carrega, leLiteral };
})();
