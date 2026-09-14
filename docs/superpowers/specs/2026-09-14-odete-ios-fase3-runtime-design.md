# Odete iOS — Fase 3: Runtime, npm, terminal e preview

Data: 2026-09-14. Estado: aprovado. Depende das Fases 1 e 2.

## Objetivo

Rodar o projeto do usuário no próprio iPad: `npm install` real, `npm run dev` de Vite/Astro/Next,
servidores Nest/Express em `localhost`, terminal com pipes, e preview em WKWebView com console e
erros no painel Problemas. Sem Mac, sem servidor remoto.

## Decisões

| Tema | Decisão |
|---|---|
| Motor JS | JavaScriptCore do sistema (JIT, WebAssembly). Sem Node embutido. |
| Camada Node | Escrita por nós (JS + Swift), crescendo por demanda; API ausente gera erro claro com o nome do módulo/função. |
| Bundler | esbuild em WebAssembly dentro do JSC. Sem bundler próprio. |
| npm | Registro real, tarballs em `node_modules/`, `package-lock.json`. Fallback automático para esm.sh (import map) quando um pacote falha ou não há `node_modules`, com aviso. |
| Servidor | `http.createServer` abre porta real em `127.0.0.1` via Network.framework. Estático sem servidor via `odete://` (`WKURLSchemeHandler`). |
| Terminal | Shell da Odete com pipes, `>`/`>>`, `&&`/`\|\|`/`;`, comandos embutidos, `git`, `npm`, `node`, `.bin`, jobs, histórico, abas. |
| Preview | WKWebView, console e erros capturados, viewport selecionável, recarregar, abrir no Safari. |

## Módulos

```
ios/Packages/OdeteRuntime/
  Sources/OdeteRuntime/
    JSRuntime.swift        # JSContext em fila dedicada; stdout/stderr; exceções; cancelamento
    Process.swift          # um "processo": runtime + cwd + env + argv + exit code + jobs de timers
    Host/                  # pontes Swift: Timers, Fetch (URLSession), Fs, HttpServer (NWListener),
                           # HttpClient, Crypto, Os, ChildProcess (só scripts JS)
    Node/                  # JS embutido (Resources/node/*.js): globals, console, events, stream,
                           # buffer, path, util, fs, http, https, url, querystring, os, process,
                           # child_process, module loader (CJS + ESM), require.resolve
    ModuleLoader.swift     # resolução Node (exports/main/module, extensions), cache, transpile via esbuild
    NativeAddons.swift     # detecta .node / binários e explica que não rodam no iPad
ios/Packages/OdeteBundler/
    Esbuild.swift          # carrega esbuild.wasm (Resources) no JSC via wasm_exec.js; build/transform/watch
    DevServer.swift        # serve bundle + HTML + HMR simples (reload por WebSocket) em localhost
    Frameworks.swift       # presets: vite, astro (estático + client), next (static/client + SSR básico), plain
ios/Packages/OdeteNpm/
    Registry.swift         # packument abreviado, semver (max satisfying), cache
    Lockfile.swift         # package-lock v3 leitura/escrita
    Installer.swift        # resolve → baixa .tgz (cache em Library/Caches/odete-npm) → extrai → node_modules
    Bins.swift             # node_modules/.bin a partir de "bin" dos pacotes
    EsmFallback.swift      # import map esm.sh para pacotes que falharam
ios/Packages/OdeteShell/
    Parser.swift           # tokens, aspas, pipes, redirecionamentos, && || ;
    Shell.swift            # executa pipeline; cwd; env; histórico; jobs
    Commands/              # Builtins (ls cat cd pwd mkdir rm cp mv touch echo grep head tail wc find clear help env which),
                           # GitCommand (sobre OdeteGit), NpmCommand (OdeteNpm), NodeCommand (OdeteRuntime),
                           # BinCommand (.bin/*), ScriptRunner (npm run)
    TerminalSession.swift  # @Observable: linhas, prompt, job em execução, cancel
ios/Packages/OdetePreview/
    PreviewView.swift      # WKWebView + barra (URL, viewport, reload, Safari)
    StaticScheme.swift     # odete://project/... serve arquivos do projeto
    ConsoleBridge.swift    # console/erros da página → Problems/Terminal
ios/Packages/OdeteApp/    # TerminalPane (abas), PreviewPane, ProblemsPane, RunModel, ligação com WorkspaceModel
```

Dependências: `OdeteShell → {OdeteRuntime, OdeteBundler, OdeteNpm, OdeteGit, OdeteCore}`;
`OdeteBundler → OdeteRuntime`; `OdeteNpm → OdeteCore`; `OdetePreview → OdeteCore`.

## Runtime

- `JSRuntime` roda numa `DispatchQueue` serial própria; chamadas de host são síncronas quando o Node
  espera síncrono (`fs.readFileSync`) e assíncronas via promessa/callback quando não (`fetch`, timers).
- Event loop: timers e I/O agendam no `DispatchQueue`; `process.exit` e cancelamento derrubam o contexto.
- `console.*` vira linhas no `TerminalSession`; `stderr` em vermelho.
- Módulos: `require()` CJS com cache; `import` ESM transformado pelo esbuild para CJS (`format: cjs`)
  antes de avaliar, mantendo `import.meta.url`. `require.resolve` segue `exports`, `main`, `module`,
  `browser` ignorado, extensões `.js .mjs .cjs .ts .tsx .jsx .json`.
- `http`: `createServer(handler)` → `NWListener` em `127.0.0.1:porta` (porta livre se ocupada, com aviso);
  `req` e `res` com a superfície usada por Express/Nest/Next (`headers`, `url`, `method`, `on('data'|'end')`,
  `writeHead`, `setHeader`, `write`, `end`, `statusCode`). `fetch` e `http.request` via URLSession.
- Faltas reportam `Odete: módulo "X" não existe no iPad` com link para o painel Problemas.

## esbuild

- `esbuild.wasm` (versão fixa) e `wasm_exec.js` empacotados. Executa no JSC do bundler com um plugin
  `odete-fs` que lê do projeto e resolve `node_modules`. `transform` para TS/JSX rápido no loader;
  `build` para o dev server e para `vite build`.
- Watch: o `DirectoryWatcher` do projeto dispara rebuild com debounce de 200 ms; o dev server manda
  `reload` pelo WebSocket para a WKWebView.

## npm

- `npm install [pkg[@range]] [-D]`, `npm uninstall`, `npm ls`, `npm run <script>`, `npx <bin>`, `pnpm` como alias.
- Resolução: lê `package-lock.json` se houver; senão resolve com semver contra o registro (packument
  `application/vnd.npm.install-v1+json`), grava lock v3. Árvore achatada (hoisting simples) com
  `node_modules/<pkg>/node_modules` só em conflito.
- Download paralelo (4), cache por integridade, extração de tar.gz em Swift (`Compression` + tar próprio).
- Pacotes com `binding.gyp`, `.node` ou `optionalDependencies` de plataforma: instalam, mas marcados
  como "nativo, não roda no iPad"; esbuild e swc caem nos nossos equivalentes.
- Fallback: se um pacote falhar, o dev server injeta `<script type="importmap">` apontando para esm.sh
  para os pacotes ausentes e o terminal avisa "usando CDN para X".

## Terminal

- Gramática: palavras com aspas simples/duplas e escapes, `$VAR`, `|`, `>`, `>>`, `<`, `&&`, `||`, `;`, `&` no fim (job).
- Cada comando implementa `Command { func run(_ ctx: CommandContext) async -> Int32 }` com `stdin`/`stdout`
  como streams de texto; pipes conectam.
- `node x.js`, `npm run dev`, `.bin/vite` viram jobs: continuam rodando, o prompt volta, `Ctrl+C`/botão
  parar encerra. Abas de terminal independentes. Histórico por projeto em `.odete/history`.
- `git` reutiliza `OdeteGit` (`status`, `add`, `commit -m`, `log`, `diff`, `branch`, `checkout`, `merge`,
  `stash`, `fetch`, `pull`, `push`, `remote`, `clone`).

## Preview

- `PreviewPane` no centro (modos Preview e Split): URL atual, seletor de viewport (iPhone, iPad,
  desktop 1280), recarregar, abrir no Safari, console ligado/desligado.
- Fonte: se há job com servidor, `http://127.0.0.1:porta`; senão `odete://project/index.html`.
- Console e `window.onerror` chegam ao painel Problemas com arquivo:linha quando há sourcemap.

## Painel Problemas

Lista de diagnósticos (esbuild, runtime, preview) com ícone, mensagem, arquivo:linha; toque abre no editor.

## Testes

- `OdeteShellTests`: parser (aspas, pipes, redirecionamentos, operadores), cada builtin em diretório temporário, `git status` via shell.
- `OdeteRuntimeTests`: scripts JS que exercitam `fs`, `path`, `events`, `Buffer`, timers, `fetch` contra um servidor local do teste, `http.createServer` + `fetch` para ele, `require` de um `node_modules` fake com `exports`.
- `OdeteNpmTests`: registro fake em disco (packuments e tarballs gerados no teste), resolução semver, lock, extração, `.bin`.
- `OdeteBundlerTests`: `transform` de TSX; `build` de um projeto Vite mínimo gera bundle que roda no JSC.
- `OdetePreviewTests`: scheme handler serve `index.html` e 404.
- UI: criar projeto Vite → terminal `npm install` (registro fake? não: teste manual) → `npm run dev` → preview mostra "meu-app".

## Marcos

1. `OdeteRuntime`: JSC, globals, fs/path/events/buffer/timers/fetch, require CJS, `node x.js`.
2. `OdeteNpm`: install/uninstall/ls/lock/.bin + fallback esm.sh.
3. `OdeteBundler`: esbuild-wasm, transform/build, dev server em localhost com reload; ESM no loader.
4. `OdeteShell` + `TerminalPane` com abas e jobs; `git`/`npm`/`node`/`.bin`.
5. `http` servidor real (Nest/Express), `OdetePreview`, `ProblemsPane`; presets Vite/Astro/Next/Nest.

## Fora de escopo

Node embutido, binários nativos, HMR granular (só reload), `child_process` de executáveis, Docker,
bancos de dados (Postgres roda? não; sqlite via `node:sqlite` fica para depois), Deno/Bun.
