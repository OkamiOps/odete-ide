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
  OdeteAgent           agente: contas (Claude OAuth, Codex e Grok por device code, chaves
                       OpenAI/Anthropic-compatíveis), streaming dos três formatos, loop com
                       sete ferramentas, patches, checkpoints, conversas, regras e skills
  OdeteSwift           Swift no iPad: parser e interpretador do subconjunto de SwiftUI,
                       render nativo, pacote .swiftpm e abertura no Swift Playgrounds
  OdeteUI              design system: Theme, Rail, PaneHeader, EditorTabs, ModePicker, Splitter, FileGlyph
  OdeteApp             telas: RootView, HubView, WorkspaceView, PhoneShell, FileTreeView,
                       CenterPane, SearchPane, CommandPalette, SettingsShell, Commands,
                       Git/ (GitModel, GitPane, DiffView, ConflictView, CloneSheet,
                       AccountsSettings, GhSheet), Terminal/ (RunModel, TerminalPane),
                       Preview/ (PreviewPane, SwiftPreviewPane, ProblemsPane), Agent/ (AgentModel, AgentPane,
                       ChatList, Composer, AIAccountsSettings, AppToolHost)
Vendor/libgit2         build-libgit2.sh + libgit2.xcframework (1.9.7, SecureTransport, sem SSH)
Tests/OdeteUITests     XCUITest de fumaça
```

Dependências entre pacotes: `OdeteApp → {OdeteUI, OdeteGit, OdeteAccounts, OdeteShell, OdetePreview, OdeteAgent}`,
`OdeteShell → {OdeteGit, OdeteNpm, OdeteRuntime, OdeteBundler}`, `OdeteBundler → OdeteRuntime`,
`OdeteApp → OdeteSwift`, tudo sobre `OdeteCore`.

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

## Agente (Fase 4)

- Contas em Ajustes → Contas de IA: Claude pela assinatura (OAuth do Claude Code, cola o
  código), Codex e Grok por device code (mesmos clients do Codex CLI e do Grok CLI), e
  quantas contas OpenAI-compatíveis ou Anthropic-compatíveis quiser, por chave e URL base.
  Tokens só no Keychain; renovação automática; `invalid_grant` pede reconectar.
- O agente fala direto com os provedores (Chat Completions, Messages e Responses por SSE).
  Ferramentas rodam no projeto real: ler, editar (vira patch), listar, grep, ler o terminal e
  rodar no shell da Odete numa aba própria. Modos Chat/Plan/Build; permissões Ask/Auto/Full.
- Patches: aceitar, rejeitar, aceitar por hunk, desfazer; faixa no editor e cards no chat.
  Checkpoint antes de cada turno em `.odete/checkpoints/` com "desfazer último turno".
- Conversas em `.odete/chats/`, regras em `AGENTS.md`/`CLAUDE.md`/`.odete/rules.md`, skills
  em `.odete/skills/*.md` por `/nome`, `@arquivo` cola o conteúdo, anexos de foto e print do
  preview. Redirecionar no meio: mande outra mensagem enquanto roda.
- Atenção: entrar com a assinatura usa os clients OAuth do Claude Code e do Codex CLI, que
  a Anthropic e a OpenAI restringem a seus próprios apps. É escolha do usuário.
- Spec e plano: `../docs/superpowers/specs/2026-09-14-odete-ios-fase4-agente-design.md`,
  `../docs/superpowers/plans/2026-09-14-odete-ios-fase4-agente.md`.

## Swift (Fase 5)

- Templates "Swift Playground" (pacote `.swiftpm` que o Swift Playgrounds abre e compila) e
  "SwiftUI (uma view)" (um `ContentView.swift` para brincar).
- Sem compilador no iPad. O Preview interpreta um subconjunto de SwiftUI e renderiza como
  SwiftUI de verdade: stacks, List/Form/Section, ScrollView, NavigationStack/Link, Text,
  Button, Toggle, TextField, Slider, Stepper, Image(systemName:), Label, ForEach, if/else,
  `@State`/`@Binding`, funcs, strings com interpolação e os modificadores comuns. O estado
  sobrevive ao salvar; "zerar" reinicia. Fora do subconjunto vira um placeholder tracejado e
  um aviso em Problemas com a linha.
- Botão "Playgrounds" abre a folha do sistema com o pacote (Swift Playgrounds, Arquivos…).
- Layout: iPad em retrato (ou janela estreita) vira "iPhone grande": abas embaixo (Arquivos com
  Busca/Git/Problemas, Editar, Terminal, Preview, Ajustes) e, no máximo, o agente dividindo a tela.
- Spec e plano: `../docs/superpowers/specs/2026-09-14-odete-ios-fase5-swift-design.md`,
  `../docs/superpowers/plans/2026-09-14-odete-ios-fase5-swift.md`.

## Pendências conhecidas

- Dois agentes em paralelo, MCP e voz ficam para depois.
- SourceKit/autocompletar Swift e GeometryReader/Canvas no preview não existem; use o Playgrounds.
- `astro build` e `next build` ainda não rodam; Next e Astro só como SPA de desenvolvimento.
- Marcas de git na margem do editor ainda não existem (o Diff cobre isso por enquanto).
- `GitHubDeviceFlow.defaultClientId` vazio até registrar o OAuth App; por ora, token.
