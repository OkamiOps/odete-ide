# Odete iOS — Fase 1: Fundação visual

Data: 2026-09-14. Estado: aprovado.

## Objetivo

Reescrever a Odete (IDE web em `src/`) como aplicativo nativo SwiftUI para iPad
(primário) e iPhone. A Fase 1 entrega a casca completa da IDE, o hub de
projetos, o sistema de arquivos, o editor de código e o design system, de forma
que o usuário acompanhe o visual no simulador antes das fases de git, runtime,
agente e Swift.

Premissa do produto: o iPad é a máquina de desenvolvimento. Nada depende de
Mac, VPS ou servidor. O que não couber no dispositivo é declarado como
limitação, nunca contornado com máquina remota.

## Decisões estruturais (valem para todas as fases)

| Tema | Decisão |
|---|---|
| Nível nativo | SwiftUI puro. WKWebView só para o preview do app do usuário (Fase 3). |
| Execução de código | Só no dispositivo: bundler próprio + JavaScriptCore + npm por ESM do registro (Fase 3). |
| Agente | Assinaturas via OAuth/device code (Claude, Codex, Grok) e provedores OpenAI/Anthropic-compatíveis por chave; chaves no Keychain; zero backend (Fase 4). |
| Git | libgit2 real (SwiftGit2), `.git` no disco, HTTPS com token para qualquer host (Fase 2). |
| Swift | Pacotes `.swiftpm` + mini-preview SwiftUI→HTML + botão "Abrir no Playgrounds" (Fase 5). |
| Mínimo | iOS/iPadOS 26. Liquid Glass, barra de menus do iPadOS 26, janelas múltiplas. Subir para 27 quando o SDK estiver estável. |
| Ferramental | XcodeGen (`project.yml`) + pacotes SwiftPM locais, Swift 6 com concorrência estrita. |
| Editor | Runestone (tree-sitter) atrás de `CodeEditorView`; substituível depois. |
| Local | Pasta `ios/` neste repositório. |

## Fases

1. Fundação visual (esta spec).
2. Git: libgit2, painel Git, GitHub API.
3. Runtime e preview: bundler, npm ESM, terminal, JavaScriptCore, WKWebView.
4. Agente: loop de ferramentas, provedores, checkpoints, modos, skills.
5. Swift: `.swiftpm`, mini-preview, Playgrounds.
6. Extras: multiplayer P2P, ZIP, iCloud.

## Estrutura

```
ios/
  project.yml
  Odete/                 # target do app: OdeteApp.swift, Info.plist, Assets, fontes
  Packages/
    OdeteCore/           # modelos puros: Project, FileNode, EditorTab, ThemeId, ChromeState
    OdeteFiles/          # ProjectStore (FileManager), DirectoryWatcher, ignore, operações
    OdeteEditor/         # CodeEditorView (Runestone), Language, EditorTheme
    OdeteUI/             # Theme tokens, Rail, SidebarPanel, EditorTabs, ModePicker,
                         # Splitter, PickList, CommandPalette, FileGlyph, KeyboardBar
    OdeteApp/            # HubView, WorkspaceView, PhoneShell, SettingsView, WelcomeView
  Tests/                 # OdeteCoreTests, OdeteFilesTests, OdeteUITests (fumaça)
  .swiftformat, .swiftlint.yml
```

Dependências entre pacotes: `OdeteApp → OdeteUI → {OdeteEditor, OdeteFiles} → OdeteCore`.
Nenhum pacote importa um de cima. Fases futuras entram como `OdeteGit`,
`OdeteRuntime`, `OdeteAgent`, `OdeteSwift`.

## Layout

### iPad (largura regular)

Espelha a web: rail de ícones (Arquivos, Busca, Git, Problemas, Ajustes) à
esquerda; sidebar redimensionável; centro com abas do editor e seletor de modo
(Código, Diff, Dois, Split, Preview); coluna do agente à direita, ocultável;
terminal em gaveta inferior. Splitters arrastáveis; larguras persistidas.
Uma janela por projeto (`WindowGroup` com valor `Project.ID`). Barra de menus
com Arquivo, Editar, Ver, Ir, Terminal, Ajuda. Atalhos: ⌘P paleta, ⌘S salvar,
⌘B sidebar, ⌘J terminal, ⌘W fechar aba, ⌘⇧F busca, ⌘, ajustes.

Liquid Glass: rail, barra de abas, gaveta do terminal e paleta usam
`glassEffect`; painéis de conteúdo usam os tokens do tema.

### iPhone (largura compacta)

Barra inferior com Arquivos, Editar, Agente, Terminal, Preview, Ajustes. Cada
uma ocupa a tela toda.

### Painéis casca

Git, Problemas, Agente, Terminal, Preview e Diff existem com título, ícone e
mensagem "chega na Fase N", para o fluxo ser navegável por inteiro.

## Arquivos e persistência

- Projetos em `Documents/Projects/<nome>/`. `UIFileSharingEnabled` e
  `LSSupportsOpeningDocumentsInPlace` ligados: visíveis no app Arquivos, abríveis
  por Playgrounds e Working Copy.
- `DirectoryWatcher` via `DispatchSource` na raiz do projeto; mudanças externas
  recarregam árvore e abas não modificadas; abas modificadas mostram conflito.
- Metadados (ordem do hub, último projeto, tema, larguras, abas abertas por
  projeto, modo do centro) em JSON em `Application Support/Odete/state.json`,
  modelo `@Observable ChromeState` com gravação debounced de 300 ms.
- Regras de ignore portadas de `src/lib/workspace/ignore.ts`: `node_modules`,
  `.git`, `dist`, `.DS_Store`, etc. ficam fora da árvore e da busca.
- Sem segredos nesta fase; a API `Keychain` fica em `OdeteCore` pronta.

## Editor

- `CodeEditorView`: `UIViewRepresentable` sobre `Runestone.TextView`.
  Números de linha, guias de indentação, quebra de linha opcional, minimap
  opcional, seleção com Pencil, indentação automática.
- Linguagens: HTML, CSS, JavaScript, TypeScript, TSX, JSON, Markdown, Swift, YAML,
  texto puro. Detecção por extensão em `Language.detect(path:)`.
- Tema do editor derivado do tema ativo (`EditorTheme(from: Theme)`).
- Barra acessória do teclado (`KeyboardBar`): Tab, `{}`, `()`, `[]`, `<>`, `"`,
  setas, desfazer/refazer, buscar.
- Salvar: ⌘S e auto-save opcional com debounce de 1 s (padrão ligado, como na web).
- Abas: modificadas mostram ponto; fechar com alteração pergunta.

## Design system (`OdeteUI`)

- `Theme`: 11 temas migrados de `src/styles.css` (odete, catppuccin, latte,
  darcula, cursor, claude, linear, github, okami, volt, colo) com tokens `bg`,
  `bgElevated`, `bgSubtle`, `fg`, `fgMuted`, `fgSubtle`, `border`,
  `borderStrong`, `accent`, `accentFg`, `danger`, `ok`, e cores de sintaxe.
- Fontes IBM Plex Sans e IBM Plex Mono empacotadas; tamanhos 11/13/15.
- Alvos de toque 44 pt; itens de lista 40 pt.
- Ícones SF Symbols; `FileGlyph` mapeia extensão → símbolo e cor, portado de
  `file-glyph.tsx`.

## Telas

- **Hub**: grade de cartões de projeto (nome, stack detectada por
  `package.json`/`Package.swift`, data), criar novo (em branco ou dos modelos
  `vite-react`, `astro`, `swift-playground`), renomear, duplicar, apagar com
  confirmação, abrir. Wordmark "Odete" no topo.
- **Workspace**: layout acima. Árvore com criar arquivo/pasta, renomear, mover
  por arrastar, apagar, revelar no Arquivos. Busca por texto com resultados
  agrupados por arquivo e abrir na linha. Paleta com arquivos e comandos.
- **Ajustes**: tema, fonte e tamanho, auto-save, quebra de linha, minimap,
  seções casca para Agente, Git e Segurança.
- **Boas-vindas**: primeira abertura, três passos, botão "criar projeto".

## Verificação

- Build: `xcodegen generate` e `xcodebuild -scheme Odete -destination
  'platform=iOS Simulator,name=iPad Air 11-inch (M4),OS=26.5'`.
- Simulador aberto no painel do Claude Code; screenshots a cada marco.
- Testes unitários (Swift Testing): árvore e ordenação, ignore, operações de
  arquivo, persistência do estado, detecção de linguagem, temas completos.
- XCUITest de fumaça: hub → criar projeto → abrir → abrir arquivo → editar → salvar.
- SwiftFormat e SwiftLint no repositório.

## Marcos

1. Casca: rail, sidebar, centro, agente, terminal, temas, Liquid Glass.
2. Hub de projetos completo.
3. Árvore de arquivos com todas as operações.
4. Editor com abas, highlight, salvar, KeyboardBar, atalhos.
5. Busca, paleta, Ajustes.
6. Layout de iPhone e barra de menus.

## Fora de escopo

Git, terminal, preview, agente, Playgrounds, multiplayer, ZIP, iCloud,
extensões. Painéis correspondentes existem só como casca.
