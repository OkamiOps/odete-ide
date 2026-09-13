# Odete iOS Fase 1 — Fundação visual — Plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App SwiftUI universal (iPad primário, iPhone) com hub de projetos, árvore de arquivos, editor de código, busca, paleta, ajustes e temas, navegável de ponta a ponta no simulador iPad Air 11".

**Architecture:** Xcode project gerado por XcodeGen com cinco pacotes SwiftPM locais em camadas (`OdeteApp → OdeteUI → {OdeteEditor, OdeteFiles} → OdeteCore`). Estado com `@Observable`; arquivos via `FileManager` em `Documents/Projects`; editor via Runestone atrás de `CodeEditorView`; design system em `OdeteUI` com os 11 temas da versão web.

**Tech Stack:** Swift 6, SwiftUI, iOS/iPadOS 26, XcodeGen, Runestone, Swift Testing, XCUITest, SwiftFormat, SwiftLint.

**Spec:** `docs/superpowers/specs/2026-09-14-odete-ios-fase1-fundacao-design.md`

## Global Constraints

- Deployment target: iOS 26.0. Swift 6, `SWIFT_STRICT_CONCURRENCY = complete`.
- Nenhuma dependência de rede, servidor ou Mac em runtime.
- Sem WKWebView nesta fase.
- Textos da interface em português do Brasil, como a versão web.
- Toque mínimo 44 pt; itens de lista 40 pt.
- Cada pacote importa só camadas abaixo.
- Build/teste sempre no destino `platform=iOS Simulator,name=iPad Air 11-inch (M4),OS=26.5`.
- Commits pequenos em português, com trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

## Mapa de arquivos

```
ios/project.yml
ios/Odete/OdeteApp.swift                 # @main, WindowGroup(for: Project.ID), comandos de menu
ios/Odete/Info.plist                     # UIFileSharingEnabled, LSSupportsOpeningDocumentsInPlace, fontes
ios/Odete/Assets.xcassets                # ícone, cor de acento
ios/Odete/Fonts/IBMPlex{Sans,Mono}-*.ttf
ios/Packages/OdeteCore/Sources/OdeteCore/
  Project.swift            # struct Project: Identifiable, Codable {id, name, url, createdAt, lastOpenedAt}
  FileNode.swift           # struct FileNode {path, name, isDirectory, children}
  EditorTab.swift          # struct EditorTab {path, isDirty}
  ThemeId.swift            # enum ThemeId: String, CaseIterable (11)
  ChromeState.swift        # @Observable: side, center, sideWidth, agentWidth, agentVisible, termVisible, termHeight, tabs por projeto, theme, editor prefs
  StateStore.swift         # load/save JSON debounced em Application Support
  Ignore.swift             # isNoisePath(_:) portado de ignore.ts
  Language.swift           # enum Language + detect(path:)
  Stack.swift              # detectStack(files:) vite/next/astro/nest/swift/static
ios/Packages/OdeteFiles/Sources/OdeteFiles/
  ProjectStore.swift       # lista/cria/renomeia/duplica/apaga projetos em Documents/Projects
  FileTreeBuilder.swift    # FileNode tree a partir de URL, ordenado pastas>arquivos, ignore
  FileOps.swift            # create file/dir, rename, move, delete (para Lixeira quando possível)
  DirectoryWatcher.swift   # DispatchSource, callback debounced
  TextSearch.swift         # busca literal/regex nos arquivos do projeto
  Templates.swift          # blank, vite-react, astro, swift-playground
ios/Packages/OdeteEditor/Sources/OdeteEditor/
  CodeEditorView.swift     # UIViewRepresentable sobre Runestone.TextView
  EditorTheme.swift        # Runestone Theme a partir de OdeteUI.Theme tokens
  LanguageMode.swift       # Language -> TreeSitterLanguage
ios/Packages/OdeteUI/Sources/OdeteUI/
  Theme.swift              # struct Theme + Theme.all + tokens
  Fonts.swift              # registro das fontes, Font.plexSans/plexMono
  Rail.swift, SidebarPanel.swift, EditorTabs.swift, ModePicker.swift,
  Splitter.swift, PickList.swift, CommandPalette.swift, FileGlyph.swift,
  KeyboardBar.swift, ShellPanel.swift (casca "chega na Fase N"), Wordmark.swift
ios/Packages/OdeteApp/Sources/OdeteApp/
  RootView.swift           # decide Welcome / Hub / Workspace
  WelcomeView.swift, HubView.swift, ProjectCard.swift, NewProjectSheet.swift
  WorkspaceView.swift      # layout iPad
  PhoneShell.swift         # layout iPhone
  FileTreeView.swift, SearchPane.swift, SettingsView.swift, CenterPane.swift
  WorkspaceModel.swift     # @Observable por projeto: tree, tabs, buffers, save
ios/Tests/OdeteCoreTests, OdeteFilesTests (Swift Testing), OdeteUITests (XCUITest)
```

---

### Task 1: Scaffolding, XcodeGen, pacotes vazios, build no simulador

**Files:** `ios/project.yml`, `ios/Odete/OdeteApp.swift`, `ios/Odete/Info.plist`, `ios/Packages/*/Package.swift` com um `Sources` mínimo cada, `ios/.swiftformat`, `ios/.swiftlint.yml`, `ios/Makefile`.

**Produces:** `make gen`, `make build`, `make test`, `make run` funcionando; app abre no simulador mostrando "Odete".

- [ ] Criar `project.yml` com target `Odete` (iOS 26.0, `SWIFT_VERSION 6.0`, bundle `com.okamiops.odete`), pacotes locais e Runestone via SPM (`https://github.com/simonbs/Runestone`, from 0.5.0).
- [ ] Criar os cinco `Package.swift` (swift-tools 6.0, platforms `.iOS(.v26)`) com dependências em camadas e alvos de teste para Core e Files.
- [ ] `OdeteApp.swift` com `WindowGroup { Text("Odete") }`.
- [ ] `Makefile`: `gen` (xcodegen), `build`, `test`, `run` (build + `simctl boot/install/launch`).
- [ ] Rodar `make build`; esperado: `BUILD SUCCEEDED`.
- [ ] Commit: `ios: scaffolding XcodeGen, pacotes e build no simulador`.

### Task 2: OdeteCore — modelos, temas, ignore, linguagem, estado

**Files:** os de `OdeteCore` listados; testes `IgnoreTests`, `LanguageTests`, `ThemeIdTests`, `StateStoreTests`, `StackTests`.

**Produces:** `Project`, `FileNode`, `EditorTab`, `ThemeId`, `ChromeState`, `StateStore`, `isNoisePath(_:)`, `Language.detect(path:)`, `detectStack(paths:packageJSON:)`.

- [ ] Testes: `isNoisePath("node_modules/x") == true`, `.git`, `dist`, `.DS_Store`; `"src/a.ts" == false`.
- [ ] Testes: `Language.detect(path: "a.tsx") == .tsx`, `.swift`, `.md`, desconhecido == `.plain`.
- [ ] Testes: `StateStore` grava e lê `ChromeState` em diretório temporário; debounce coalesce duas gravações.
- [ ] Testes: `detectStack` com `package.json` contendo `next`, `astro`, `@nestjs/core`, `vite`; `Package.swift` → `.swift`.
- [ ] Implementar até passar. Commit: `core: modelos, ignore, linguagem, estado persistido`.

### Task 3: OdeteFiles — ProjectStore, árvore, operações, watcher, busca, templates

**Files:** os de `OdeteFiles`; testes `ProjectStoreTests`, `FileTreeBuilderTests`, `FileOpsTests`, `TextSearchTests`, `TemplatesTests` (todos em diretório temporário).

**Produces:** `ProjectStore(root:)` com `list() -> [Project]`, `create(name:template:)`, `rename`, `duplicate`, `delete`; `FileTreeBuilder.build(at:) -> FileNode`; `FileOps.createFile/createDirectory/rename/move/delete`; `DirectoryWatcher(url:onChange:)`; `TextSearch.search(root:query:regex:) -> [SearchHit]`; `Template.all`.

- [ ] Testes por operação (criar, listar ordenado, renomear conflito, apagar), árvore ignora `node_modules`, busca acha linha e coluna, template `vite-react` gera `package.json` + `index.html` + `src/main.tsx`.
- [ ] Implementar até passar. Commit: `files: projetos, árvore, operações, busca, modelos`.

### Task 4: OdeteUI — Theme, fontes, componentes base (Marco 1: casca)

**Files:** `Theme.swift` (11 temas com valores de `src/styles.css`), `Fonts.swift`, `Rail`, `SidebarPanel`, `EditorTabs`, `ModePicker`, `Splitter`, `ShellPanel`, `Wordmark`; `OdeteApp/WorkspaceView.swift` montando a casca; `RootView` abrindo direto o workspace com projeto fake.

**Produces:** app no simulador com rail, sidebar, centro com abas e modo, coluna do agente, gaveta do terminal, Liquid Glass, tema Odete; seletor de tema temporário.

- [ ] Teste: `Theme.all.count == 11` e todo tema tem tokens não vazios.
- [ ] Implementar componentes + layout com `Splitter` arrastável e larguras em `ChromeState`.
- [ ] Rodar no simulador, screenshot. Commit: `ui: design system, temas e casca do workspace`.

### Task 5: Hub de projetos (Marco 2)

**Files:** `WelcomeView`, `HubView`, `ProjectCard`, `NewProjectSheet`, `RootView`.

- [ ] Grade de cartões, criar (nome + template), renomear, duplicar, apagar com confirmação, abrir → workspace. Última abertura salva em `ChromeState`.
- [ ] XCUITest: criar projeto "Teste" aparece no hub.
- [ ] Screenshot. Commit: `app: hub de projetos`.

### Task 6: Árvore de arquivos (Marco 3)

**Files:** `FileTreeView`, `FileGlyph`, `WorkspaceModel` (tree + watcher).

- [ ] `OutlineGroup`/`List` com glyphs, menu de contexto (novo arquivo, nova pasta, renomear, apagar, revelar), arrastar para mover, recarregar no watcher.
- [ ] Screenshot. Commit: `app: árvore de arquivos com operações`.

### Task 7: Editor com abas (Marco 4)

**Files:** `OdeteEditor/*`, `EditorTabs` ligado a `WorkspaceModel.tabs`, `KeyboardBar`, `CenterPane`.

- [ ] `CodeEditorView` com Runestone, tema derivado, linguagem por extensão; abrir por toque na árvore; ponto de modificado; ⌘S e auto-save; fechar com confirmação.
- [ ] Testes: `WorkspaceModel` abre/fecha abas, marca dirty, salva no disco.
- [ ] Screenshot. Commit: `editor: Runestone, abas, salvar, barra de teclado`.

### Task 8: Busca, paleta, ajustes (Marco 5)

**Files:** `SearchPane`, `CommandPalette`, `PickList`, `SettingsView`.

- [ ] Busca com resultados agrupados por arquivo e abrir na linha; paleta ⌘P (arquivos + comandos); Ajustes com tema, fonte, tamanho, auto-save, quebra, minimap e seções casca.
- [ ] Screenshot. Commit: `app: busca, paleta e ajustes`.

### Task 9: iPhone e barra de menus (Marco 6)

**Files:** `PhoneShell`, `OdeteApp.swift` (`.commands`).

- [ ] `horizontalSizeClass == .compact` → `PhoneShell` com 6 abas; menus Arquivo/Editar/Ver/Ir/Terminal/Ajuda com atalhos ⌘P ⌘S ⌘B ⌘J ⌘W ⌘⇧F ⌘,.
- [ ] Screenshot iPhone 17 e iPad. Commit: `app: layout de iPhone e barra de menus`.

### Task 10: Fechamento

- [ ] `swiftformat --lint ios`, `swiftlint ios`, `make test` verdes.
- [ ] Atualizar `AGENTS.project.md`/README com `make` e estrutura.
- [ ] Commit: `ios: fase 1 concluída`.
