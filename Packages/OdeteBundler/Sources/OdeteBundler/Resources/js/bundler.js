// esbuild-wasm dentro do JSC + plugin de sistema de arquivos + dev server.
(function () {
  const fs = require("fs"), path = require("path"), H = globalThis.__odete;
  let ready = null;

  globalThis.__esbuildInit = (browserJsPath, wasmPath) => {
    if (ready) return ready;
    ready = (async () => {
      const src = fs.readFileSync(browserJsPath, "utf8");
      (0, eval)(src + "\n//# sourceURL=esbuild-browser.js"); // define globalThis.esbuild (UMD)
      const bytes = fs.readFileSync(wasmPath);
      const mod = new WebAssembly.Module(bytes);
      await globalThis.esbuild.initialize({ wasmModule: mod, worker: false });
      return globalThis.esbuild.version;
    })();
    return ready;
  };

  const LOADERS = { ".js": "js", ".mjs": "js", ".cjs": "js", ".jsx": "jsx", ".ts": "ts", ".mts": "ts", ".cts": "ts", ".tsx": "tsx", ".json": "json", ".css": "css", ".txt": "text", ".md": "text", ".svg": "dataurl", ".png": "dataurl", ".jpg": "dataurl", ".jpeg": "dataurl", ".gif": "dataurl", ".webp": "dataurl", ".woff": "dataurl", ".woff2": "dataurl", ".ttf": "dataurl", ".wasm": "binary" };
  // `a.module.css` é CSS Modules: `import s from "./a.module.css"` recebe o mapa das classes.
  // Com o loader `css` ele recebia `{}`, calado.
  const loaderFor = (p) => (/\.module\.css$/i.test(p) ? "local-css" : LOADERS[path.extname(p).toLowerCase()] || "file");

  // Frases para a pessoa ler, na língua do app: o Esbuild.swift põe a tabela em
  // `__odeteTextos`, com os `%1$@` do `tr()`.
  globalThis.__odeteTexto = (k, ...a) => {
    const t = (globalThis.__odeteTextos && globalThis.__odeteTextos[k]) || k;
    return t.replace(/%(\d+)\$@/g, (_, n) => String(a[Number(n) - 1]));
  };
  const texto = globalThis.__odeteTexto;

  // ---- memória entre builds ----
  // O rebuild incremental do esbuild só pula a análise de quem chegou igual: o plugin
  // continua sendo chamado para cada import e cada arquivo, a cada build. Sem memória
  // aqui, todo rebuild relia o react-dom inteiro do disco e o recodificava em UTF-8 no
  // JS interpretado, só para o esbuild descobrir que era o mesmo texto. Os bytes ficam
  // guardados até alguém dizer que o arquivo mudou (`__esqueceArquivos`, que o dev
  // server chama com o que o observador viu).
  const leituras = new Map(); // caminho → bytes lidos
  // Data de modificação de cada arquivo do projeto quando um build o leu. O observador do
  // lado nativo compara com a do disco ao começar a vigiar: se mudou entre o build ler e
  // o observador armar, a mudança não se perde.
  const mtimes = new Map();
  // Resolução de import muda quando arquivo nasce ou some. Em vez de achar cada cache,
  // quem guarda confere esta geração e se esvazia sozinho quando ela anda.
  let geracaoDeResolucao = 0;
  // `node_modules.nosync` é onde os pacotes moram de verdade em projeto do iCloud.
  const ehDoProjeto = (p) => p.indexOf("/node_modules/") < 0 && p.indexOf("/node_modules.nosync/") < 0;

  // O CSS pronto (Sass, Tailwind) e o glob também guardam coisa por arquivo; e um tsconfig
  // ou vite.config que muda muda os aliases, e com eles a resolução.
  globalThis.__esqueceArquivos = (caminhos, estrutura) => {
    for (const c of caminhos || []) { leituras.delete(c); mtimes.delete(c); comGlob.delete(c); }
    if (estrutura || (caminhos || []).some((c) => globalThis.__odeteAlias && globalThis.__odeteAlias.ehConfig(c))) geracaoDeResolucao++;
    if (globalThis.__odeteEstilos) globalThis.__odeteEstilos.esquece(caminhos);
    if (globalThis.__odeteTailwind) globalThis.__odeteTailwind.esquece(caminhos);
  };
  globalThis.__esqueceTudo = () => {
    leituras.clear(); mtimes.clear(); comGlob.clear(); geracaoDeResolucao++;
    if (globalThis.__odeteEstilos) globalThis.__odeteEstilos.esqueceTudo();
    if (globalThis.__odeteTailwind) globalThis.__odeteTailwind.esqueceTudo();
  };
  // Arquivo do app → tem `import.meta.glob`? Guardado até ele mudar.
  const comGlob = new Map();
  // Só o que ainda é dependência de alguém fica: um arquivo que saiu do grafo deixa de
  // ser vigiado, e bytes guardados dele ficariam velhos sem ninguém avisar.
  globalThis.__guardaSo = (vivos) => {
    for (const c of [...leituras.keys()]) if (!vivos.has(c)) leituras.delete(c);
  };
  globalThis.__mtimeLido = (p) => (mtimes.has(p) ? mtimes.get(p) : null);

  function anotaMtime(p) {
    if (!ehDoProjeto(p)) return;
    try { mtimes.set(p, fs.statSync(p).mtimeMs); } catch (e) { mtimes.delete(p); }
  }

  // ---- dependências pré-empacotadas ----
  // No dev server, o que um import de pacote resolve (`react`, `react-dom/client`) sai do
  // bundle do app e vai para um pacote de dependências à parte, feito uma vez e guardado
  // em disco (dependencias.js). O bundle do app fica só com o código do projeto: o
  // rebuild depois de editar o App.tsx liga e imprime só isso, e não o react-dom inteiro.
  //
  // No lugar do pacote, o app recebe dois módulos pequenos:
  //   - um CommonJS que pega o módulo no registro que o pacote de dependências preenche
  //     (`globalThis.__odeteDep`), igual a um `require` — então o `import` do app passa
  //     pela mesma interoperação CJS↔ESM do esbuild que teria se o pacote estivesse junto;
  //   - a fachada ESM na frente dele (`fachada`, abaixo), para que `default` siga o
  //     `__esModule` como no Vite (e num pacote ESM seja o default de verdade).
  // Os caminhos virtuais não podem terminar em `.mjs`: a extensão decide o formato mesmo
  // fora do disco. Por isso o sufixo.
  const SUFIXO_DEP = "?odete", SUFIXO_DEP_CJS = "?odete.cjs";

  // ---- a fachada ESM de um pacote CommonJS ----
  // O `default` de um CommonJS muda conforme quem importa. O esbuild dá o `default` do
  // Vite (e do Babel) — `exports.default` se o módulo tem `__esModule`, senão o
  // `module.exports` — a quem importa de um módulo comum; a quem é ESM do Node, a regra
  // do Node: o `module.exports` inteiro, sempre. E ESM do Node, aqui, é só `.mjs` e
  // `.mts`: o esbuild do motor não lê arquivo nenhum (tudo passa por este plugin), então
  // não vê o `"type": "module"` do package.json. Um `src/x.mjs` que importa o
  // react-transition-group recebia o objeto no lugar do componente.
  //
  // A fachada é um módulo virtual — comum, portanto — que reexporta o pacote: quem a
  // importa recebe o `default` que ela recebeu, pela regra do Vite. O dev server a põe na
  // frente de todo pacote; o `vite build`, só onde a regra do Node valeria (`fachadas`).
  const fachada = (alvo) => {
    const a = JSON.stringify(alvo);
    return `export * from ${a};\nexport { default } from ${a};\n`;
  };
  const CODIGO_DE_PACOTE = /\.([mc]?[jt]s|[jt]sx)$/i;
  const TIPOS_DE_IMPORT = new Set(["import-statement", "require-call", "dynamic-import"]);
  const dentroDePacote = (p) => p.indexOf("/node_modules/") >= 0 || p.indexOf("/node_modules.nosync/") >= 0;

  // Só código de pacote instalado entra: CSS e JSON de pacote seguem no bundle do app (a
  // folha dele sai junto com a do app), e um pacote ligado (`npm link`, workspace) é
  // código que a pessoa edita, então continua no app e é refeito como o resto.
  function vaiParaAsDependencias(abs, kind) {
    if (!TIPOS_DE_IMPORT.has(kind) || !CODIGO_DE_PACOTE.test(abs) || !dentroDePacote(abs)) return false;
    try { return dentroDePacote(fs.realpathSync(abs)); } catch (e) { return false; }
  }

  // Quem importa é ESM do Node para o esbuild (ver `fachada`).
  const ehESMDoNode = (p) => /\.m[jt]s$/i.test(p);

  // Código do app: fora de node_modules, ou um pacote ligado (`npm link`), que o dev
  // server também trata como código do app.
  function ehCodigoDoApp(p) {
    if (!dentroDePacote(p)) return true;
    try { return !dentroDePacote(fs.realpathSync(p)); } catch (e) { return false; }
  }

  // Se o esbuild vai ler o arquivo como CommonJS, pelo mesmo critério dele: a extensão
  // manda (`.cjs`/`.cts` é CommonJS, `.mjs`/`.mts` é ESM); fora isso, CommonJS é o que
  // não tem sintaxe de ESM e usa `module`, `exports` ou `require`. A procura é por
  // `indexOf`, que é nativo: expressão regular no arquivo inteiro, sem JIT, anda
  // caractere por caractere. Na dúvida (um `export ` num comentário), ESM — sem fachada,
  // o import fica como era, e uma fachada num ESM sem `default` quebraria o build.
  function ehCommonJS(abs) {
    if (/\.c[jt]s$/i.test(abs)) return true;
    if (/\.m[jt]s$/i.test(abs)) return false;
    let t;
    try { t = fs.readFileSync(abs, "utf8"); } catch (e) { return false; }
    if (temSintaxeESM(t)) return false;
    return t.indexOf("exports") >= 0 || t.indexOf("module") >= 0 || t.indexOf("require") >= 0;
  }

  function temSintaxeESM(t) {
    const ident = /[\w$.]/;
    for (const [palavra, depois] of [["export", " \t\r\n{*"], ["import", " \t\r\n{*\"'."]]) {
      for (let i = t.indexOf(palavra); i >= 0; i = t.indexOf(palavra, i + 1)) {
        if (i > 0 && ident.test(t[i - 1])) continue;
        const c = t[i + palavra.length];
        if (c === undefined || depois.indexOf(c) < 0) continue;
        // `import.x` só é sintaxe de módulo como `import.meta`.
        if (c === "." && !t.startsWith(".meta", i + palavra.length)) continue;
        return true;
      }
    }
    return false;
  }

  // O que o bundle do app pediu ao pacote de dependências, a partir do metafile.
  function dependenciasDe(metafile) {
    if (!metafile) return null;
    const out = [];
    for (const k of Object.keys(metafile.inputs)) {
      if (k.startsWith("odete-dep:")) out.push(k.slice("odete-dep:".length, -SUFIXO_DEP.length));
    }
    return out;
  }

  // Os módulos do Node (a mesma lista do ResolucaoDoNavegador.swift).
  const EMBUTIDOS_DO_NODE = new Set(["assert", "assert/strict", "async_hooks", "buffer", "child_process", "cluster", "console", "constants",
    "crypto", "dgram", "diagnostics_channel", "dns", "dns/promises", "domain", "events", "fs", "fs/promises", "http", "http2", "https",
    "inspector", "module", "net", "os", "path", "path/posix", "path/win32", "perf_hooks", "process", "punycode", "querystring", "readline",
    "readline/promises", "repl", "stream", "stream/consumers", "stream/promises", "stream/web", "string_decoder", "sys", "timers",
    "timers/promises", "tls", "trace_events", "tty", "url", "util", "util/types", "v8", "vm", "wasi", "worker_threads", "zlib"]);

  // Como o esbuild chama a importação: o `@import` de CSS resolve com a condição `style`, e
  // o `require()` com `require` no lugar de `import`.
  const modoDe = (kind) => (kind === "import-rule" || kind === "composes-from" ? "style" : kind === "require-call" || kind === "require-resolve" ? "require" : "import");

  // O módulo do Node que o código do navegador importou (`fs`, `node:crypto`), como o
  // `__vite-browser-external` do Vite: existe, é vazio, e diz no console quem tentou usar
  // o quê — em vez de derrubar a página com "Dynamic require of … is not supported".
  const moduloEmbutido = (nome) => "module.exports = new Proxy({}, { get(_, k) {\n" +
    '  if (typeof k === "symbol" || k === "__esModule" || k === "then" || k === "default") return undefined;\n' +
    "  console.warn(" + JSON.stringify("[odete] " + texto("embutidoNoNavegador", nome) + " (" + nome + ".") + " + String(k) + \")\");\n" +
    "  return undefined;\n} });\n";

  // plugin: resolve como o navegador (ou como o Node, no pacote do servidor do Next) e lê
  // do disco
  const fsPlugin = (root, opts = {}) => ({
    name: "odete-fs",
    setup(build) {
      // Com memória, a resolução de cada import também fica guardada entre rebuilds: são
      // centenas de idas ao nativo por build num projeto de verdade, para a mesma resposta.
      let resolvidos = new Map(), geracao = geracaoDeResolucao, versaoDosAliases = -1;
      // O pacote que roda no navegador resolve como navegador: condição `browser`, campo
      // `browser`, versão ESM. O do servidor do Next (`platform: "node"`) segue como Node.
      const navegador = (opts.platform || "browser") !== "node";
      let declaradas = null;
      // Os aliases conferem a config uma vez por build; se ela mudou, o que estava guardado
      // pode ter resolvido pelo alias velho.
      build.onStart(() => {
        if (!opts.vigiados) opts.vigiados = new Set();
        declaradas = null;
        const v = globalThis.__odeteAlias.prepara(root, opts.vigiados);
        if (v !== versaoDosAliases) { versaoDosAliases = v; resolvidos = new Map(); }
      });
      build.onResolve({ filter: /.*/ }, (args) => {
        if (!opts.memoria) return resolve(args);
        if (geracao !== geracaoDeResolucao) { resolvidos = new Map(); geracao = geracaoDeResolucao; }
        const chave = args.importer + "\0" + args.kind + "\0" + args.path;
        const guardado = resolvidos.get(chave);
        if (guardado) return guardado;
        const r = resolve(args);
        if (r && !r.errors) resolvidos.set(chave, r);
        return r;
      });
      // O que o CSS e os recursos do Vite leem fora do esbuild vai para `vigiados` (o dev
      // server vigia), e as pastas onde arquivo novo importa, para `faltando`.
      const ctx = () => ({
        root, vigiados: opts.vigiados || (opts.vigiados = new Set()), pastas: opts.faltando || new Set(),
        dev: opts.dev !== false, novo: opts.dev === false, limiteDeInline: opts.limiteDeInline,
      });
      // Pacote que está no package.json e ainda não foi instalado: no dev ele vem do esm.sh,
      // mesmo que tenha nome de módulo do Node (o `buffer` e o `events` do npm).
      const declarada = (nome) => {
        if (!declaradas) {
          declaradas = new Set();
          try {
            const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
            for (const k of Object.keys(Object.assign({}, pkg.dependencies || {}, pkg.devDependencies || {}))) declaradas.add(k);
          } catch (e) { /* sem package.json */ }
        }
        return declaradas.has(nome);
      };
      const resolveNoHost = (spec, importer, kind) => (navegador ? H.resolveNavegador(spec, importer, modoDe(kind)) : H.resolve(spec, importer));
      const resolve = (args) => {
        // `?raw`, `?url`, `?inline`, `?worker`: o arquivo resolve como sempre e o conteúdo
        // sai por outro caminho (vite-recursos.js).
        const consulta = navegador && args.path.indexOf("?") > 0 ? globalThis.__odeteVite.separa(args.path) : null;
        if (consulta) {
          // Com um `kind` que não é import de código: o arquivo de um pacote
          // (`pdfjs-dist/…/pdf.worker.mjs?url`) não vai para o pacote de dependências.
          const r = resolve(Object.assign({}, args, { path: consulta.caminho, kind: "odete-consulta" }));
          if (!r || r.errors || r.external || r.namespace !== "file") return r;
          // Um namespace por tipo: o mesmo arquivo com `?raw` e com `?url` são dois módulos. E o
          // caminho vai sem o `?` — com ele, o esbuild levava o `?url` para o nome do arquivo
          // que sai em dist/.
          return { path: r.path, namespace: "odete-consulta-" + consulta.consulta, pluginData: { params: consulta.params } };
        }
        // O arquivo real por trás de uma ilha. Precisa ser tratado aqui, e não num
        // `onResolve` próprio: o genérico é registrado primeiro e engoliria o prefixo.
        if (args.path.startsWith("odete-real:")) {
          return { path: args.path.slice("odete-real:".length), namespace: "odete-real" };
        }
        if (args.path.startsWith("odete-dep-cjs:")) {
          return { path: args.path.slice("odete-dep-cjs:".length), namespace: "odete-dep-cjs" };
        }
        // O pacote por trás de uma fachada do build: o arquivo de sempre, no namespace de
        // sempre — o mesmo módulo que outro pacote importa direto, e não uma segunda cópia.
        if (args.path.startsWith("odete-pacote:")) {
          return { path: args.path.slice("odete-pacote:".length), namespace: "file" };
        }
        // Módulos que só existem em memória: a entrada das ilhas e o mapa delas são
        // gerados por rota, e não faz sentido escrever isso no projeto de quem usa.
        // O ponto de entrada chega como caminho absoluto, porque o esbuild junta com a
        // raiz antes de resolver; os imports de dentro chegam como foram escritos.
        if (opts.virtuais) {
          const chave = Object.prototype.hasOwnProperty.call(opts.virtuais, args.path)
            ? args.path
            : path.relative(root, args.path);
          if (Object.prototype.hasOwnProperty.call(opts.virtuais, chave)) {
            return { path: chave, namespace: "odete-virtual" };
          }
        }
        if (navegador && args.path.startsWith("node:")) return embutido(args.path.slice(5), args);
        if (/^(https?:|data:|node:)/.test(args.path)) return { path: args.path, external: true };
        // Externos pedidos por quem chamou: no render do Next o React precisa ser o
        // mesmo do servidor, e `next/*` é atendido por substitutos nossos. Empacotar
        // uma segunda cópia do React quebra hooks e contexto.
        if (opts.external && opts.external.some((e) => e.endsWith("/*") ? args.path.startsWith(e.slice(0, -1)) : args.path === e)) {
          return { path: args.path, external: true };
        }
        if (args.path.startsWith("virtual:") ) return { path: args.path, namespace: "virtual" };
        const importer = args.importer || path.join(root, "index.js");
        const bare = !args.path.startsWith(".") && !args.path.startsWith("/");
        // `@/components/Botao`: o alias do vite.config ou o `paths` do tsconfig, antes de
        // procurar pacote. Cada alvo em ordem; o primeiro que existe ganha. Nenhum existindo,
        // vale a resolução comum (o `paths` do TypeScript também cai nela), e só se ela
        // também falhar o erro fala do alias — é ele que a pessoa escreveu errado.
        if (bare) {
          const alvos = globalThis.__odeteAlias.aplica(root, args.path, opts.vigiados, importer);
          if (alvos) {
            for (const alvo of alvos) {
              const r = resolveCaminho(alvo, args, importer, !path.isAbsolute(alvo), true);
              if (r && !r.errors) return r;
            }
            const comum = resolveCaminho(args.path, args, importer, bare, true);
            if (comum && !comum.errors) return comum;
            if (opts.externalMissing && !path.isAbsolute(alvos[0]) && !alvos[0].startsWith(".")) return { path: alvos[0], external: true };
            const onde = path.isAbsolute(alvos[0]) ? path.relative(root, alvos[0]) : alvos[0];
            return { errors: [{ text: texto("aliasSemArquivo", args.path, onde, path.relative(root, importer)) }] };
          }
        }
        return resolveCaminho(args.path, args, importer, bare);
      };
      const embutido = (nome, args) => {
        const r = { path: nome, namespace: "odete-embutido" };
        // No build de produção o aviso sai também no terminal, como o Vite faz.
        if (opts.dev === false && args.importer) r.warnings = [{ text: texto("embutidoAviso", nome, path.relative(root, args.importer)) }];
        return r;
      };
      // `tentativa`: um dos alvos de um alias. Não achar não vira externo (o import map não
      // conhece `@/lib/utils`), e quem chamou decide o erro.
      const resolveCaminho = (spec, args, importer, bare, tentativa) => {
        let r = resolveNoHost(spec, importer, args.kind);
        // No pacote do Node (o servidor do Next, o `@plugin` do Tailwind), `path` e `fs` são
        // do runtime: ficam de fora e o `require` dele atende.
        if (!navegador && r && typeof r === "object" && EMBUTIDOS_DO_NODE.has(spec)) return { path: spec, external: true };
        if (r && typeof r === "object" && r.vazio) return { path: spec, namespace: "odete-vazio" };
        if (r && typeof r === "object" && r.embutido) {
          if (opts.externalMissing && declarada(spec.split("/")[0])) return { path: spec, external: true };
          return embutido(r.embutido, args);
        }
        // `baseUrl` do tsconfig: `import "components/Botao"` com `baseUrl: "src"`.
        if (r && typeof r === "object" && bare) {
          const daBase = globalThis.__odeteAlias.daBase(root, spec);
          const rb = daBase ? resolveNoHost(daBase, importer, args.kind) : null;
          if (typeof rb === "string") { r = rb; bare = false; }
        }
        // Caminho absoluto que não existe no disco é da raiz do projeto, como no Vite
        // (`import "/src/util"`, `url(/src/fundo.png)`). E no CSS, se nem lá existe, é um
        // endereço do site — o `url(/fundo.png)` de um arquivo de public/ —, que fica como
        // está (com o `base` na frente); antes derrubava o build inteiro por "não achei".
        if (r && typeof r === "object" && spec.startsWith("/") && !spec.startsWith(root + "/")) {
          const daRaiz = resolveNoHost(path.join(root, spec), importer, args.kind);
          if (typeof daRaiz === "string") r = daRaiz;
          else if (args.kind === "url-token") {
            const pre = opts.base && opts.base !== "./" ? opts.base : "/";
            return { path: pre + spec.slice(1), external: true };
          }
        }
        if (r && typeof r === "object") {
          // Vai pelo import map (esm.sh) — só JS: um `@import "pacote"` de CSS externo chegava
          // ao navegador cru, e a folha sumia calada em vez de dizer que falta instalar.
          if (opts.externalMissing && bare && !tentativa && modoDe(args.kind) !== "style" && args.kind !== "url-token") return { path: spec, external: true };
          // Pacote para rodar no motor (o Tailwind 3, um `@plugin`): o que falta fica para o
          // `require` dele, como no Node — o `require("@tailwindcss/line-clamp")` opcional,
          // dentro de um try, não pode derrubar o build.
          if (opts.pacoteFaltandoFora && bare) return { path: spec, external: true };
          // A pasta onde o arquivo que falta nasceria: o observador passa a olhar lá, e o
          // import quebrado se conserta sozinho quando o arquivo aparece.
          if (!bare && opts.faltando) opts.faltando.add(path.dirname(path.resolve(path.dirname(importer), spec)));
          return { errors: [{ text: bare ? `Não achei o pacote "${spec}" (importado por ${path.relative(root, importer)}). Rode npm install.` : `Não achei "${spec}" importado por ${path.relative(root, importer)}.` }] };
        }
        if (r.startsWith("node:")) return { path: r, external: true };
        // O resolvedor do runtime devolve `src/./App.tsx` para `./App`. Normalizado, o
        // caminho é o mesmo que o metafile e o observador usam — senão a memória de
        // leituras guardava por uma chave e era esquecida por outra, e o rebuild servia o
        // arquivo velho. E um mesmo arquivo importado por dois caminhos não vira dois módulos.
        const abs = path.resolve(r);
        // A chave no registro é o arquivo resolvido, não o nome importado: dois nomes que
        // chegam ao mesmo arquivo são o mesmo módulo, e o pacote de dependências o carrega
        // pelo mesmo caminho que o react-dom usa por dentro — uma cópia só do React.
        if (opts.preempacota && bare && vaiParaAsDependencias(abs, args.kind)) {
          return { path: path.relative(root, abs) + SUFIXO_DEP, namespace: "odete-dep" };
        }
        // Sem pacote de dependências, a fachada vai só onde a regra do Node valeria: um
        // `.mjs` do app importando um pacote CommonJS. No resto o esbuild já dá o mesmo
        // `default` que ela, e o bundle fica como sempre foi. `require` fica de fora: ele
        // é o `module.exports`, em qualquer regra.
        if (opts.fachadas && bare && args.kind !== "require-call" && ehESMDoNode(importer) && ehCodigoDoApp(importer) &&
            vaiParaAsDependencias(abs, args.kind) && ehCommonJS(abs)) {
          return { path: abs + SUFIXO_DEP, namespace: "odete-fachada" };
        }
        // O esbuild só lê o `"sideEffects": false` do package.json quando ele mesmo resolve
        // o import; aqui quem resolve é o plugin, então o build de produção diz por ele.
        // Sem isso, importar um ícone de um pacote com barril (`export * from "./icones"`)
        // levava para o bundle todo módulo cujo topo chama uma função — o Vite (Rollup)
        // deixa de fora.
        if (opts.dev === false && CODIGO_DE_PACOTE.test(abs) && dentroDePacote(abs) && semEfeitos(abs)) {
          return { path: abs, namespace: "file", sideEffects: false };
        }
        return { path: abs, namespace: "file" };
      };
      // O package.json mais perto do arquivo, como o esbuild: `sideEffects: false` vale; uma
      // lista de arquivos não é interpretada aqui, e fica como sem a informação.
      // A resposta fica guardada para cada pasta do caminho: os arquivos de `cjs/` e `esm/`
      // não voltam a procurar package.json onde não há.
      const efeitosPorPasta = new Map();
      const semEfeitos = (abs) => {
        const vistas = [];
        let v = false;
        for (let dir = path.dirname(abs); dir && dir !== path.dirname(dir); dir = path.dirname(dir)) {
          if (efeitosPorPasta.has(dir)) { v = efeitosPorPasta.get(dir); break; }
          vistas.push(dir);
          let pkg;
          try { pkg = fs.readFileSync(path.join(dir, "package.json"), "utf8"); } catch (e) { continue; }
          try { v = JSON.parse(pkg).sideEffects === false; } catch (e) { /* package.json quebrado */ }
          break;
        }
        for (const d of vistas) efeitosPorPasta.set(d, v);
        return v;
      };
      build.onLoad({ filter: /.*/, namespace: "odete-dep" }, (args) => ({
        contents: fachada("odete-dep-cjs:" + args.path.slice(0, -SUFIXO_DEP.length) + SUFIXO_DEP_CJS), loader: "js", resolveDir: root,
      }));
      build.onLoad({ filter: /.*/, namespace: "odete-fachada" }, (args) => ({
        contents: fachada("odete-pacote:" + args.path.slice(0, -SUFIXO_DEP.length)), loader: "js", resolveDir: root,
      }));
      build.onLoad({ filter: /.*/, namespace: "odete-dep-cjs" }, (args) => {
        const chave = JSON.stringify(args.path.slice(0, -SUFIXO_DEP_CJS.length));
        return { contents: `module.exports = globalThis.__odeteDep(${chave});\n`, loader: "js" };
      });
      // `"browser": { "./node.js": false }`: o pacote diz que no navegador isto não existe.
      // Módulo vazio, como o esbuild faz.
      build.onLoad({ filter: /.*/, namespace: "odete-vazio" }, () => ({ contents: "module.exports = {};\n", loader: "js" }));
      build.onLoad({ filter: /.*/, namespace: "odete-embutido" }, (args) => ({ contents: moduloEmbutido(args.path), loader: "js" }));
      for (const tipo of ["raw", "url", "inline", "worker", "sharedworker"]) {
        build.onLoad({ filter: /.*/, namespace: "odete-consulta-" + tipo }, (args) =>
          globalThis.__odeteVite.carrega(args.path, tipo, (args.pluginData && args.pluginData.params) || [tipo], ctx()));
      }
      // Fronteira de cliente: um módulo que começa com "use client" roda nos dois lados.
      // No servidor ele vira uma ilha — o componente real renderiza dentro de uma marca
      // que diz ao navegador qual módulo montar ali e com que props. Sem isso o Preview
      // mostra a página certa e ela não responde a clique nenhum.
      build.onLoad({ filter: /.*/, namespace: "odete-virtual" }, (args) => ({
        contents: opts.virtuais[args.path], loader: "js", resolveDir: root,
      }));
      build.onLoad({ filter: /.*/, namespace: "odete-real" }, (args) => {
        anotaMtime(args.path);
        return { contents: fs.readFileSync(args.path, "utf8"), loader: loaderFor(args.path), resolveDir: path.dirname(args.path) };
      });
      build.onLoad({ filter: /.*/, namespace: "file" }, (args) => {
        if ((opts.ilhas || opts.acoes) && /\.(tsx|jsx|ts|js|mjs)$/i.test(args.path)) {
          anotaMtime(args.path);
          const src = fs.readFileSync(args.path, "utf8");
          const rel = path.relative(root, args.path);
          if (opts.ilhas && /^\s*(["'])use client\1\s*;?/.test(src)) {
            const nomes = exportadosDe(src);
            opts.ilhas[rel] = nomes;
            const linhas = [`import * as __real from ${JSON.stringify("odete-real:" + args.path)};`];
            for (const n of nomes) {
              const alvo = `__real[${JSON.stringify(n)}]`;
              const marca = `globalThis.__odeteIlha(${JSON.stringify(rel)}, ${JSON.stringify(n)}, ${alvo})`;
              linhas.push(n === "default" ? `export default ${marca};` : `export const ${n} = ${marca};`);
            }
            return { contents: linhas.join("\n"), loader: "js", resolveDir: path.dirname(args.path) };
          }
          // Fronteira de servidor: "use server" marca funções que só rodam aqui. No
          // pacote do servidor elas continuam sendo elas mesmas, com uma identidade
          // pendurada para o formulário poder dizer qual chamar; no pacote do navegador
          // viram um talão que chama a de cá pela rede, porque o corpo delas não pode
          // descer para o navegador.
          if (opts.acoes && /^\s*(["'])use server\1\s*;?/.test(src)) {
            const nomes = exportadosDe(src);
            const linhas = [];
            if (opts.acoes === "cliente") {
              // O talão é escrito inteiro aqui, e não apoiado num global: um módulo ESM
              // roda antes de quem o importa, então um global posto pela entrada ainda
              // não existiria na hora em que este corpo é avaliado.
              linhas.push(TALAO);
              for (const n of nomes) {
                const talao = `__odeteChama(${JSON.stringify(rel + "#" + n)})`;
                linhas.push(n === "default" ? `export default ${talao};` : `export const ${n} = ${talao};`);
              }
            } else {
              linhas.push(`import * as __real from ${JSON.stringify("odete-real:" + args.path)};`);
              for (const n of nomes) {
                const alvo = `__real[${JSON.stringify(n)}]`;
                const marca = `globalThis.__odeteAcaoServidor(${JSON.stringify(rel)}, ${JSON.stringify(n)}, ${alvo})`;
                linhas.push(n === "default" ? `export default ${marca};` : `export const ${n} = ${marca};`);
              }
            }
            return { contents: linhas.join("\n"), loader: "js", resolveDir: path.dirname(args.path) };
          }
        }
        // Sass, Less, CSS Modules e CSS com Tailwind (estilos.js). O `.css` comum segue pelo
        // carregador de sempre.
        if (globalThis.__odeteEstilos.ehEstilo(args.path) && globalThis.__odeteEstilos.precisa(args.path)) {
          anotaMtime(args.path);
          return globalThis.__odeteEstilos.carrega(args.path, ctx());
        }
        return carregaArquivo(args);
      });
      // `import.meta.glob` num arquivo do app: a lista de arquivos vira imports comuns. Sai
      // de novo a cada build, sem a memória de bytes — um arquivo novo na pasta muda a lista
      // sem mudar o arquivo que importa.
      // A resposta "não tem" fica guardada com a data do arquivo: o `vite build` não passa
      // pelo observador, e um glob escrito entre dois builds tem de ser visto.
      const comGlobDoApp = (p) => {
        if (!CODIGO_DE_PACOTE.test(p) || !ehDoProjeto(p)) return null;
        let mt = null;
        try { mt = fs.statSync(p).mtimeMs; } catch (e) { return null; }
        const g = comGlob.get(p);
        if (g && g.mt === mt && !g.tem) return null;
        let t;
        try { t = fs.readFileSync(p, "utf8"); } catch (e) { return null; }
        const tem = t.indexOf("import.meta.glob") >= 0;
        comGlob.set(p, { mt, tem });
        if (!tem) return null;
        anotaMtime(p);
        return globalThis.__odeteVite.transformaGlob(t, p, root, ctx());
      };
      const carregaArquivo = (args) => {
        const loader = loaderFor(args.path);
        const final = loader === "file" ? "dataurl" : loader;
        const glob = comGlobDoApp(args.path);
        if (glob != null) return { contents: glob, loader: final, resolveDir: path.dirname(args.path) };
        // Com memória, o que vai ao esbuild são bytes: texto seria recodificado em UTF-8 a
        // cada build, e bytes atravessam para o wasm como estão.
        if (opts.memoria) {
          let bytes = leituras.get(args.path);
          if (!bytes) {
            anotaMtime(args.path);
            bytes = fs.readFileSync(args.path);
            leituras.set(args.path, bytes);
          }
          return { contents: bytes, loader: final, resolveDir: path.dirname(args.path) };
        }
        // Bytes sem guardar: o pacote de dependências lê o react-dom inteiro, e raramente.
        // Guardar seria segurar um megabyte que nenhum rebuild do app vai pedir.
        if (opts.bytes) {
          anotaMtime(args.path);
          return { contents: fs.readFileSync(args.path), loader: final, resolveDir: path.dirname(args.path) };
        }
        anotaMtime(args.path);
        if (loader === "dataurl" || loader === "file") {
          // O `vite build` embute no JS só o arquivo pequeno (o `assetsInlineLimit` do Vite,
          // 4 KB); o resto sai como arquivo à parte, com hash no nome — a foto de 2 MB não
          // vai em base64 dentro do bundle que o navegador precisa ler antes de desenhar.
          const bytes = fs.readFileSync(args.path);
          const limite = opts.limiteDeInline;
          const comoArquivo = typeof limite === "number" && bytes.length > limite;
          return { contents: bytes, loader: comoArquivo ? "file" : "dataurl", resolveDir: path.dirname(args.path) };
        }
        if (loader === "binary") return { contents: fs.readFileSync(args.path), loader, resolveDir: path.dirname(args.path) };
        return { contents: fs.readFileSync(args.path, "utf8"), loader, resolveDir: path.dirname(args.path) };
      };
    },
  });


  // O talão que o navegador recebe no lugar de uma Server Action: a função de verdade
  // fica no servidor, e daqui vai uma chamada pela rede com os argumentos em JSON.
  const TALAO = `
const __odeteSerializa = (v) => {
  if (typeof FormData !== "undefined" && v instanceof FormData) {
    const pares = [];
    v.forEach((x, k) => { if (typeof x === "string") pares.push([k, x]); });
    return { __odeteFormData: pares };
  }
  return v;
};
const __odeteChama = (id) => async (...args) => {
  const r = await fetch("/@odete/acao/" + encodeURIComponent(id), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(args.map(__odeteSerializa)),
  });
  const t = await r.text();
  let j = null;
  try { j = JSON.parse(t); } catch (e) { throw new Error(t || ("acao " + id + " falhou")); }
  if (!r.ok || j.erro) throw new Error(j && j.erro ? j.erro : "acao " + id + " falhou");
  if (j.redireciona) { location.assign(j.redireciona); return undefined; }
  return j.valor;
};
`;

  // Nomes exportados, para a ilha reexportar os mesmos. Cobre o que um componente de
  // cliente usa: `export default`, `export function X`, `export const X`.
  function exportadosDe(src) {
    const nomes = new Set();
    if (/^\s*export\s+default\b/m.test(src)) nomes.add("default");
    for (const m of src.matchAll(/^\s*export\s+(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/gm)) nomes.add(m[1]);
    for (const m of src.matchAll(/^\s*export\s+(?:const|let|var)\s+([A-Za-z_$][\w$]*)/gm)) nomes.add(m[1]);
    for (const m of src.matchAll(/^\s*export\s*\{([^}]*)\}/gm)) {
      for (const parte of m[1].split(",")) {
        const nome = parte.trim().split(/\s+as\s+/).pop().trim();
        if (nome) nomes.add(nome);
      }
    }
    return [...nomes];
  }

  globalThis.__transform = async (code, options) => {
    await ready;
    const r = await globalThis.esbuild.transform(code, options);
    return { code: r.code, map: r.map, warnings: r.warnings.map(fmtMsg) };
  };

  // Só checa sintaxe. O esbuild não tem modo "só analisar": a transformação sempre
  // imprime código. Então ela imprime o mínimo — sem espaço, sem comentário legal, sem
  // mapa — porque esse texto atravessa do wasm para o JS e é decodificado a cada pausa na
  // digitação, para ser jogado fora. Daqui para o Swift só vão os diagnósticos.
  globalThis.__lint = async (code, loader, file) => {
    await ready;
    try {
      const r = await globalThis.esbuild.transform(code, { loader, sourcefile: file, logLevel: "silent", minifyWhitespace: true, legalComments: "none", sourcemap: false });
      return { errors: [], warnings: r.warnings.map(fmtMsg) };
    } catch (e) {
      return { errors: (e.errors || [{ text: e.message }]).map(fmtMsg), warnings: (e.warnings || []).map(fmtMsg) };
    }
  };

  // transforma TS/ESM → CJS para o require do runtime
  //
  // `import()` vira `Promise.resolve().then(() => require(…))`: o JSContext do runtime não
  // tem carregador de módulos, e o `import()` nativo rejeita com "No module loader
  // provided". Deixado como estava, a CLI do vitest (que carrega tudo por `import()`)
  // rejeitava, a rejeição não aparecia em lugar nenhum e o processo saía com 0, mudo.
  globalThis.__transformCJS = async (code, file) => {
    await ready;
    const ext = path.extname(file).toLowerCase();
    const loader = { ".ts": "ts", ".tsx": "tsx", ".jsx": "jsx", ".mts": "ts", ".cts": "ts" }[ext] || "js";
    const r = await globalThis.esbuild.transform(code, { loader, format: "cjs", target: "es2022", sourcefile: file, platform: "node", supported: { "dynamic-import": false }, define: { "import.meta.url": JSON.stringify("file://" + file), "import.meta.dirname": JSON.stringify(path.dirname(file)), "import.meta.filename": JSON.stringify(file) } });
    return r.code;
  };

  const fmtMsg = (m) => ({ text: m.text, file: m.location ? m.location.file : null, line: m.location ? m.location.line : null, column: m.location ? m.location.column : null, lineText: m.location ? m.location.lineText : null });

  // As opções do esbuild para um pedido de build, iguais no build avulso e no contexto.
  //
  // Sourcemap só quando pedido. O padrão era `inline` para tudo: o `vite build` saía com
  // o mapa embutido no JS de produção, e o dev server gerava, codificava em base64 e
  // decodificava no JS interpretado um mapa que dobrava o tamanho do bundle — para
  // ninguém ler: o console do Preview pega arquivo e linha do evento de erro do WebKit,
  // que não passa por sourcemap.
  function opcoes(opts) {
    const root = opts.root;
    const o = {
      entryPoints: opts.entries.map((e) => (path.isAbsolute(e) ? e : path.join(root, e))),
      bundle: true, write: false, format: opts.format || "esm", platform: opts.platform || "browser", target: opts.target || "es2022",
      sourcemap: opts.sourcemap || false, outdir: path.join(root, opts.outdir || "dist"), outbase: root,
      jsx: "automatic", jsxDev: opts.dev !== false, minify: !!opts.minify, splitting: false, metafile: !!opts.metafile, logLevel: "silent", absWorkingDir: root,
      define: Object.assign(definesDoVite(opts), opts.define || {}),
      loader: { ".png": "dataurl", ".jpg": "dataurl", ".svg": "dataurl", ".gif": "dataurl", ".webp": "dataurl", ".woff": "dataurl", ".woff2": "dataurl", ".ttf": "dataurl" },
      plugins: [fsPlugin(root, opts)], nodePaths: [path.join(root, "node_modules")], resolveExtensions: [".tsx", ".ts", ".jsx", ".js", ".mjs", ".cjs", ".json", ".css"], mainFields: opts.platform === "node" ? ["module", "main"] : ["browser", "module", "main"], conditions: opts.platform === "node" ? ["node", "import", "default"] : ["browser", "import", "default"],
    };
    // O bundle do app com dependências pré-empacotadas começa importando o pacote delas:
    // pela regra do ESM, ele roda antes de qualquer linha do app.
    if (opts.banner) o.banner = { js: opts.banner };
    // Produção sai com o CSS aninhado achatado, como o Vite (lightningcss) entrega para os
    // navegadores que ele mira: o `@apply hover:x` do Tailwind escreve `&:hover { … }`.
    if (opts.dev === false && o.platform === "browser") o.supported = { nesting: false };
    // Os nomes do `vite build`: `assets/index-<hash>.js`, e o que o bundle referencia
    // pelo endereço de onde o site é servido (o `base`).
    if (opts.entryNames) o.entryNames = opts.entryNames;
    if (opts.assetNames) o.assetNames = opts.assetNames;
    if (opts.publicPath) o.publicPath = opts.publicPath;
    return o;
  }

  // `import.meta.env` como no Vite: MODE, DEV, PROD, BASE_URL, SSR e as variáveis dos
  // `.env`. Além de cada chave, o objeto inteiro: sem ele, `import.meta.env.VITE_X ?? "p"`
  // com VITE_X ausente virava `import.meta.env` de verdade no navegador — `undefined`, e
  // o `.VITE_X` dele, um TypeError em vez do valor padrão. O esbuild põe o objeto numa
  // variável só, e só se alguém o usar inteiro.
  function definesDoVite(opts) {
    const prod = opts.dev === false;
    const env = envDoVite(opts.root, opts.mode || (prod ? "production" : "development"), opts.base || "/", !prod);
    const d = {
      "process.env.NODE_ENV": JSON.stringify(prod ? "production" : "development"),
      "import.meta.env": JSON.stringify(env),
      "import.meta.hot": "undefined",
      "global": "globalThis",
    };
    for (const k of Object.keys(env)) {
      d["import.meta.env." + k] = JSON.stringify(env[k]);
      if (!(k in ENV_FIXAS)) d["process.env." + k] = JSON.stringify(env[k]);
    }
    return d;
  }
  const ENV_FIXAS = { BASE_URL: 1, MODE: 1, DEV: 1, PROD: 1, SSR: 1 };

  // O que, nas opções, muda o que sai do esbuild: entra na chave do cache do pacote de
  // dependências. Um `.env` com VITE_X novo, por exemplo, muda os defines e a chave.
  globalThis.__opcoesQueMudamASaida = (opts) => {
    const o = opcoes(opts);
    // `RESOLUCAO` muda quando a resolução muda de regra: um pacote guardado com a versão
    // de Node dos pacotes (antes da resolução de navegador) não serve mais.
    return JSON.stringify([RESOLUCAO, o.format, o.platform, o.target, o.jsx, o.jsxDev, o.minify, o.define, o.loader, o.resolveExtensions, o.mainFields, o.conditions, !!opts.externalMissing]);
  };

  // Os arquivos que o build leu, em caminho absoluto, a partir do metafile. Módulos que
  // só existem em memória (as entradas virtuais das ilhas) não são arquivo e ficam de fora.
  function entradasDe(root, metafile) {
    if (!metafile) return null;
    const out = [];
    for (const k of Object.keys(metafile.inputs)) {
      if (k.startsWith("odete-real:")) { out.push(k.slice("odete-real:".length)); continue; }
      if (k.startsWith("file:")) { out.push(path.resolve(root, k.slice(5))); continue; }
      if (/^[a-z][a-z0-9-]*:/i.test(k)) continue;
      out.push(path.resolve(root, k));
    }
    return out;
  }

  const RESOLUCAO = "navegador-1";

  // Os arquivos lidos fora do esbuild (o `@use` do Sass, os arquivos que o Tailwind
  // varreu, o tsconfig dos aliases) são dependência do build tanto quanto os do metafile.
  function comVigiados(entradas, vigiados) {
    if (!entradas || !vigiados || !vigiados.size) return entradas;
    const todos = new Set(entradas);
    for (const f of vigiados) todos.add(f);
    return [...todos];
  }

  // Resultado cru, para quem está no JS: as saídas continuam sendo os objetos do esbuild,
  // com `contents` (bytes), `hash` e o `text` preguiçoso. Comparar o hash diz se a saída
  // mudou sem decodificar nada; servir os bytes evita decodificar e recodificar o bundle.
  const sucesso = (r, opts) => ({
    ok: true, saidas: r.outputFiles || [], warnings: r.warnings.map(fmtMsg), errors: [],
    entradas: comVigiados(entradasDe(opts.root, r.metafile), opts.vigiados), faltando: opts.faltando ? [...opts.faltando] : [],
    dependencias: opts.preempacota ? dependenciasDe(r.metafile) : null,
  });
  const falha = (e, opts) => ({
    ok: false, saidas: [], warnings: (e.warnings || []).map(fmtMsg), errors: (e.errors || [{ text: e.message }]).map(fmtMsg),
    entradas: null, faltando: opts.faltando ? [...opts.faltando] : [], dependencias: null,
  });

  globalThis.__buildBruto = async (opts) => {
    await ready;
    if (opts.metafile) opts.faltando = new Set();
    opts.vigiados = new Set();
    try {
      return sucesso(await globalThis.esbuild.build(opcoes(opts)), opts);
    } catch (e) {
      return falha(e, opts);
    }
  };

  // Para o Swift (`Esbuild.build`): o que o `vite build` grava em dist/. JS e CSS vão como
  // texto; o resto (a imagem que saiu como arquivo) em base64, que texto a estragaria.
  // `env` é o `import.meta.env` do build, para o `%VITE_X%` do index.html.
  globalThis.__build = async (opts) => {
    const r = await globalThis.__buildBruto(opts);
    const files = r.saidas.map((f) => {
      const p = path.relative(opts.root, f.path);
      return /\.(js|css|map)$/.test(p) ? { path: p, text: f.text } : { path: p, base64: Buffer.from(f.contents).toString("base64") };
    });
    const env = r.ok ? envDoVite(opts.root, opts.mode || (opts.dev === false ? "production" : "development"), opts.base || "/", opts.dev !== false) : {};
    return { ok: r.ok, files, env, warnings: r.warnings, errors: r.errors };
  };

  // ---- contextos incrementais ----
  // Um contexto do esbuild por chave (o dev server usa um por entrada servida). O
  // `rebuild()` reaproveita a análise de todo módulo cujo conteúdo não mudou, e é isso
  // que faz o rebuild depois de editar o App.tsx não reanalisar o react-dom inteiro.
  //
  // Um rebuild por vez em cada contexto, em fila: pedir outro enquanto um corre devolve
  // o resultado do que já estava correndo — que pode ter lido o arquivo antes da mudança.
  const contextos = new Map(); // chave → { ctx, opts, fila }

  // Com memória por padrão; quem não quer guardar leituras diz `memoria: false`. Os
  // módulos virtuais podem mudar entre rebuilds (a entrada do pacote de dependências
  // ganha um pacote novo): os de agora substituem os da criação.
  globalThis.__rebuild = (chave, opts) => {
    let c = contextos.get(chave);
    if (!c) {
      const o = Object.assign({ memoria: true }, opts, { metafile: true });
      const ctx = (async () => { await ready; return globalThis.esbuild.context(opcoes(o)); })();
      ctx.catch(() => {});
      c = { opts: o, fila: Promise.resolve(), ctx };
      contextos.set(chave, c);
    } else if (opts && opts.virtuais) {
      c.opts.virtuais = opts.virtuais;
    }
    const vez = c.fila.then(async () => {
      c.opts.faltando = new Set();
      c.opts.vigiados = new Set();
      try {
        const ctx = await c.ctx;
        return sucesso(await ctx.rebuild(), c.opts);
      } catch (e) {
        return falha(e, c.opts);
      }
    });
    c.fila = vez.catch(() => {});
    return vez;
  };

  // Descarta os contextos cujas chaves começam com o prefixo. Contexto vivo segura a
  // memória de tudo o que analisou; servidor que para não pode deixá-los para trás.
  globalThis.__descartaContextos = async (prefixo) => {
    const alvos = [];
    for (const [k, c] of contextos) if (k.startsWith(prefixo)) { contextos.delete(k); alvos.push(c); }
    for (const c of alvos) {
      try { await c.fila; const ctx = await c.ctx; await ctx.dispose(); } catch (e) { /* já era */ }
    }
    return alvos.length;
  };
  globalThis.__contextosVivos = () => contextos.size;

  // O `import.meta.env` de um modo: as fixas e as variáveis públicas dos `.env`.
  //
  // Os arquivos na ordem do `loadEnv` do Vite, o de depois ganhando: `.env`, `.env.local`,
  // `.env.<modo>`, `.env.<modo>.local`. Antes o `.env.local` vinha por último e passava
  // por cima do `.env.production`, e o `.env.production.local` nem era lido. Públicas são
  // as com o prefixo do Vite (`VITE_`), e as do Astro e do Next, que usam o mesmo motor.
  function envDoVite(root, modo, base, dev) {
    const lidas = {};
    for (const f of [".env", ".env.local", ".env." + modo, ".env." + modo + ".local"]) {
      let texto;
      try { texto = fs.readFileSync(path.join(root, f), "utf8"); } catch (e) { continue; }
      leEnv(texto, lidas);
    }
    const env = { BASE_URL: base, MODE: modo, DEV: dev, PROD: !dev, SSR: false };
    for (const k of Object.keys(lidas)) {
      // O nome vira chave de define: `VITE_A-B` quebraria o build inteiro.
      if (!/^\w+$/.test(k)) continue;
      if (k.startsWith("VITE_") || k.startsWith("PUBLIC_") || k.startsWith("NEXT_PUBLIC_")) env[k] = expande(lidas, k);
    }
    return env;
  }
  globalThis.__envDoVite = envDoVite;

  // Um `.env` como o dotenv lê: `export` na frente, aspas (simples, duplas ou crase)
  // guardando `#` e espaços, `\n` dentro de aspas duplas, e comentário depois do valor sem
  // aspas — `VITE_API=/api # produção` é `/api`, não a linha inteira.
  function leEnv(texto, destino) {
    for (const linha of texto.split("\n")) {
      const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*(.*?)\s*$/.exec(linha);
      if (!m) continue;
      let v = m[2];
      const q = v[0];
      const fim = (q === '"' || q === "'" || q === "`") ? v.indexOf(q, 1) : -1;
      if (fim > 0) {
        v = v.slice(1, fim);
        if (q === '"') v = v.replace(/\\n/g, "\n").replace(/\\r/g, "\r");
        destino[m[1]] = { valor: v, expande: q !== "'" };
      } else {
        const c = v.search(/\s#/);
        if (c >= 0) v = v.slice(0, c);
        destino[m[1]] = { valor: v.trim(), expande: true };
      }
    }
  }

  // `${VAR}`, `${VAR:-padrão}` e `$VAR`, com as outras variáveis dos `.env` (o
  // dotenv-expand do Vite). `\$` é um cifrão. Uma variável que se referencia não trava.
  function expande(lidas, k, visitadas) {
    const item = lidas[k];
    if (!item) return "";
    if (!item.expande || item.valor.indexOf("$") < 0) return item.valor;
    const vis = new Set(visitadas || []);
    vis.add(k);
    return item.valor.replace(/\\\$|\$\{([A-Za-z_][\w.-]*)(?::?-([^}]*))?\}|\$([A-Za-z_]\w*)/g, (tudo, a, padrao, b) => {
      if (tudo === "\\$") return "$";
      const nome = a || b;
      const v = vis.has(nome) ? "" : expande(lidas, nome, vis);
      return v === "" && padrao !== undefined ? padrao : v;
    });
  }
})();
