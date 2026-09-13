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
  OdeteUI              design system: Theme, Rail, PaneHeader, EditorTabs, ModePicker, Splitter, FileGlyph
  OdeteApp             telas: RootView, HubView, WorkspaceView, PhoneShell, FileTreeView,
                       CenterPane, SearchPane, CommandPalette, SettingsShell, Commands
Tests/OdeteUITests     XCUITest de fumaça
```

Dependências entre pacotes: `OdeteApp → OdeteUI → {OdeteEditor, OdeteFiles} → OdeteCore`.
Fases futuras entram como `OdeteGit`, `OdeteRuntime`, `OdeteAgent`, `OdeteSwift`.

## Onde ficam os dados

- Projetos: `Documents/Projects/<nome>/`, visíveis no app Arquivos (`UIFileSharingEnabled`,
  `LSSupportsOpeningDocumentsInPlace`). Cada projeto tem `.odete/project.json`.
- Layout e preferências: `Application Support/Odete/state.json`.

## Pendências conhecidas da Fase 1

- Fontes IBM Plex ainda não empacotadas (usa SF e SF Mono).
- Painéis Git, Problemas, Agente, Terminal, Preview e Diff são cascas ("chega na Fase N").
