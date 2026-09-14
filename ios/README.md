# Odete para iPad e iPhone

App nativo SwiftUI da Odete. iOS/iPadOS 26 ou superior, Swift 6.

Spec e plano: `../docs/superpowers/specs/2026-09-14-odete-ios-fase1-fundacao-design.md`
e `../docs/superpowers/plans/2026-09-14-odete-ios-fase1-fundacao.md`.

## Requisitos

- Xcode 26.6 ou superior, com o runtime de simulador iOS 26.5.
- `brew install xcodegen swiftformat swiftlint`

## Comandos

```bash
make gen     # gera Odete.xcodeproj a partir de project.yml
make build   # compila para o simulador iPad Air 11-inch (M4)
make run     # compila, instala e abre no simulador
make unit    # testes unitários de todos os pacotes
make test    # testes de interface (XCUITest)
make lint    # swiftformat --lint + swiftlint
make format  # swiftformat
```

Outro simulador: `make run SIM="iPhone 17"`.

## Estrutura

```
project.yml            XcodeGen
Odete/                 target do app: OdeteApp.swift, Info.plist, Assets
Packages/
  OdeteCore            modelos puros, temas, ignore, linguagem, estado persistido
  OdeteFiles           projetos em Documents/Projects, árvore, operações, watcher, busca, modelos
  OdeteEditor          CodeEditorView (Runestone + tree-sitter), tema do editor, barra do teclado
  OdeteGit             libgit2 (Vendor/libgit2/libgit2.xcframework): Repository actor, diff/hunks,
                       branches, merge, stash, remotos HTTPS
  OdeteAccounts        Keychain, contas por host, device flow e API REST do GitHub
  OdeteRuntime         JavaScriptCore com camada Node (fs, path, events, buffer, stream,
                       timers, fetch, http real em 127.0.0.1 via Network.framework, require)
  OdeteNpm             npm de verdade: registro, semver, package-lock v3, tarballs, .bin,
                       fallback esm.sh para o que não instalar
  OdeteBundler         esbuild-wasm dentro do JSC: transform TS/ESM, build, dev server com reload
  OdeteShell           shell da Odete: parser (| > >> < && || ; & $VAR), builtins, git, npm,
                       node, binários de .bin, vite/astro/next, jobs, histórico, Tab
  OdetePreview         WKWebView do preview, esquema odete://static/ e ponte de console
  OdeteUI              design system: Theme, Rail, PaneHeader, EditorTabs, ModePicker, Splitter, FileGlyph
  OdeteApp             telas: RootView, HubView, WorkspaceView, PhoneShell, FileTreeView,
                       CenterPane, SearchPane, CommandPalette, SettingsShell, Commands,
                       Git/ (GitModel, GitPane, DiffView, ConflictView, CloneSheet,
                       AccountsSettings, GhSheet), Terminal/ (RunModel, TerminalPane),
                       Preview/ (PreviewPane, ProblemsPane)
Vendor/libgit2         build-libgit2.sh + libgit2.xcframework (1.9.7, SecureTransport, sem SSH)
Tests/OdeteUITests     XCUITest de fumaça
```

Dependências entre pacotes: `OdeteApp → {OdeteUI, OdeteGit, OdeteAccounts, OdeteShell, OdetePreview}`,
`OdeteShell → {OdeteGit, OdeteNpm, OdeteRuntime, OdeteBundler}`, `OdeteBundler → OdeteRuntime`,
tudo sobre `OdeteCore`. Fases futuras entram como `OdeteAgent` e `OdeteSwift`.

## Fontes

IBM Plex Sans e Mono em `Odete/Fonts/` (licença OFL em `LICENSE-IBM-Plex.txt`).

## Onde ficam os dados

- Projetos: `Documents/Projects/<nome>/`, visíveis no app Arquivos (`UIFileSharingEnabled`,
  `LSSupportsOpeningDocumentsInPlace`). Cada projeto tem `.odete/project.json`.
- Layout e preferências: `Application Support/Odete/state.json`.

## Git (Fase 2)

- Repositório real por projeto. `.odete/` fica em `.git/info/exclude`.
- Contas em Ajustes → Contas: GitHub por device flow (quando `GitHubDeviceFlow.defaultClientId`
  estiver preenchido com o OAuth App da Odete) ou token pessoal; outros hosts por token.
- Sem SSH, rebase interativo, submódulos, cherry-pick ou blame.

## Runtime, terminal e preview (Fase 3)

- Tudo roda no dispositivo: Node compatível em JavaScriptCore, npm contra o registro real,
  esbuild em WebAssembly e servidor HTTP em `127.0.0.1`. Sem Mac, VPS ou runner remoto.
- Terminal (⌘J): `npm install`, `npm run dev`, `node arquivo.ts`, `git ...`, pipes e redirects.
  Processos que abrem porta viram jobs (`jobs`, `kill %1`); o Preview segue a última porta.
- Preview: dev server com reload ao salvar, viewport iPhone/iPad, console do app e abrir no
  Safari. Sem servidor, `index.html` é servido direto do disco em `odete://static/`.
- Problemas: erros do esbuild e do preview, toque abre o arquivo na linha.
- Presets: Vite (`vite`, `vite build`, `vite preview`), Astro e Next só em `dev` (SSR
  completo fica para depois), Nest via `node`. Pacotes com binário nativo (esbuild, swc,
  rolldown, lightningcss) não rodam no iPad; a Odete usa os equivalentes embutidos.
- Spec e plano: `../docs/superpowers/specs/2026-09-14-odete-ios-fase3-runtime-design.md`,
  `../docs/superpowers/plans/2026-09-14-odete-ios-fase3-runtime.md`.

## Pendências conhecidas

- Painel Agente é casca ("chega na Fase 4").
- `astro build` e `next build` ainda não rodam; Next e Astro só como SPA de desenvolvimento.
- Marcas de git na margem do editor ainda não existem (o Diff cobre isso por enquanto).
- `GitHubDeviceFlow.defaultClientId` vazio até registrar o OAuth App; por ora, token.
