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
make unit    # testes unitários dos pacotes (Core, Files, UI, App)
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
  OdeteUI              design system: Theme, Rail, PaneHeader, EditorTabs, ModePicker, Splitter, FileGlyph
  OdeteApp             telas: RootView, HubView, WorkspaceView, PhoneShell, FileTreeView,
                       CenterPane, SearchPane, CommandPalette, SettingsShell, Commands,
                       Git/ (GitModel, GitPane, DiffView, ConflictView, CloneSheet,
                       AccountsSettings, GhSheet)
Vendor/libgit2         build-libgit2.sh + libgit2.xcframework (1.9.7, SecureTransport, sem SSH)
Tests/OdeteUITests     XCUITest de fumaça
```

Dependências entre pacotes: `OdeteApp → OdeteUI → {OdeteEditor, OdeteFiles} → OdeteCore`.
Fases futuras entram como `OdeteGit`, `OdeteRuntime`, `OdeteAgent`, `OdeteSwift`.

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

## Pendências conhecidas

- Painéis Problemas, Agente, Terminal e Preview são cascas ("chega na Fase N").
- Marcas de git na margem do editor ainda não existem (o Diff cobre isso por enquanto).
- `GitHubDeviceFlow.defaultClientId` vazio até registrar o OAuth App; por ora, token.
