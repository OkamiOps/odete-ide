# Odete iOS Fase 3 — Runtime, npm, terminal e preview — Plano

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `npm install`, `npm run dev`, servidores em localhost, terminal com pipes e preview com console, tudo no iPad.

**Architecture:** JavaScriptCore + camada Node própria (`OdeteRuntime`), esbuild-wasm (`OdeteBundler`), registro npm real (`OdeteNpm`), shell próprio (`OdeteShell`), WKWebView (`OdetePreview`).

**Spec:** `docs/superpowers/specs/2026-09-14-odete-ios-fase3-runtime-design.md`

## Global Constraints

- iOS 26, Swift 6 strict; sem servidor remoto; sem Node embutido; testes sem rede (registro/servidores fake locais).
- Textos em português; commits na branch `iOS` com o trailer de coautoria.
- Destino: `platform=iOS Simulator,id=7B54EEE5-3B0E-40E8-98CA-D14509F539DD`.

---

### Task 1: OdeteRuntime núcleo (Marco 1)
**Files:** `Packages/OdeteRuntime/{Package.swift, Sources/OdeteRuntime/{JSRuntime,Process,ModuleLoader,Host/*}.swift, Sources/OdeteRuntime/Resources/node/*.js}`, `Tests/OdeteRuntimeTests/*`.
- [ ] `JSRuntime`: contexto em fila serial, `evaluate`, exceções → `RuntimeError{message, stack}`, `console` → callback, timers (`setTimeout/Interval/Immediate`, `queueMicrotask`), `TextEncoder/Decoder`, `URL/URLSearchParams`, `atob/btoa`, `structuredClone`, `crypto.randomUUID/getRandomValues`, `performance.now`, `AbortController`.
- [ ] Módulos JS: `events`, `buffer`, `path`, `util`, `os`, `process`, `fs` (sync + promises + `existsSync/readdirSync/statSync/mkdirSync/writeFileSync/rmSync/copyFileSync/renameSync` + `readFile/writeFile/readdir/stat/mkdir/rm` + `watch` no-op), `stream` (Readable/Writable/Transform/PassThrough mínimos), `url`, `querystring`, `assert`, `string_decoder`, `zlib` (gzip via Compression), `child_process` (só `spawn('node', …)`).
- [ ] `ModuleLoader`: `require` CJS com cache, resolução Node (`exports` com condições `node`/`require`/`import`/`default`, `main`, `module`, index, extensões), JSON, `node:` prefix, `require.resolve`, `module.paths`.
- [ ] `fetch` via URLSession (Request/Response/Headers, text/json/arrayBuffer, streaming simples).
- [ ] Testes com scripts JS reais em diretório temporário.
- [ ] Commit: `runtime: JavaScriptCore com camada Node (fs, path, events, buffer, timers, fetch, require)`.

### Task 2: OdeteNpm (Marco 2)
**Files:** `Packages/OdeteNpm/**`, testes com registro fake (packuments JSON + tarballs gerados).
- [ ] `Semver` (parse, compare, satisfies para `^ ~ >= <= > < = x * || -`), `Registry` (packument abreviado com cache), `Lockfile` v3, `Tar` (gunzip via `Compression` + tar), `Installer` (resolver com hoisting, baixar em paralelo, extrair, `.bin` com symlink ou script), `EsmFallback` (import map).
- [ ] Commit: `npm: instalação real com registro, lock, tarballs e .bin`.

### Task 3: OdeteBundler (Marco 3)
**Files:** `Packages/OdeteBundler/**` com `esbuild.wasm` + `wasm_exec.js` (versão fixa, baixados no build via script `fetch-esbuild.sh` e versionados), `DevServer.swift`, `Frameworks.swift`; ESM no `ModuleLoader` via `transform`.
- [ ] `Esbuild.load()` no JSC; `transform(code, loader)`; `build(entry, outdir?, define, plugins fs)`; erros → `Diagnostic`.
- [ ] `DevServer`: `NWListener` em `127.0.0.1:porta`, serve `index.html` com `<script type=module src="/@bundle.js">`, bundle em memória, CSS, assets do projeto, WebSocket de reload, watch por `DirectoryWatcher`.
- [ ] Presets: `vite` (index.html + entry), `astro` (build estático das páginas `.astro` simples via transform + client), `next` (páginas em `app/`/`pages/` client-only + API routes via `http`), `plain`.
- [ ] Commit: `bundler: esbuild-wasm, dev server com reload e presets`.

### Task 4: OdeteShell e TerminalPane (Marco 4)
**Files:** `Packages/OdeteShell/**`, `OdeteApp/TerminalPane.swift`, `RunModel.swift`.
- [ ] Parser com testes; builtins; `git` (subcomandos sobre `OdeteGit`); `npm/npx/pnpm`; `node`; `.bin`; `npm run` com scripts; jobs (`&`, Ctrl+C, botão), histórico, `Tab` completa caminhos; abas.
- [ ] `TerminalPane`: linhas coloridas (in/out/err/ok), input com barra de teclado (Tab, ↑, Ctrl+C, `|`, `>`), job em execução com "parar", abas `+`.
- [ ] Commit: `shell: terminal com pipes, git, npm, node e jobs`.

### Task 5: http real, preview e problemas (Marco 5)
**Files:** `OdeteRuntime/Host/HttpServer.swift`, `Resources/node/http.js`, `Packages/OdetePreview/**`, `OdeteApp/{PreviewPane,ProblemsPane}.swift`.
- [ ] `http.createServer` → `NWListener`; `req/res` compatíveis com Express/Nest; `https` cliente; `net` mínimo.
- [ ] `PreviewView` (WKWebView) com barra, viewport, reload, Safari, `odete://` estático, console bridge.
- [ ] `ProblemsPane` com diagnósticos do esbuild, runtime e preview; toque abre `ws.open(path, line)`.
- [ ] Verificar no simulador: Vite (`npm install`, `npm run dev`, preview), Nest exemplo (`npm start`, `curl` no terminal), HTML puro.
- [ ] Commit: `preview: WKWebView, servidor http real e painel de problemas`.

### Task 6: Fechamento
- [ ] `make unit`, `make test`, lint; README; commit `ios: fase 3 concluída`.
