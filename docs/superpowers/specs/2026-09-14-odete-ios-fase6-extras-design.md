# Odete iOS — Fase 6: Polimento e extras

Data: 2026-09-14. Depende das fases 1 a 5 (`ios/` na branch `iOS`).

## Objetivo

Deixar a Odete bonita de verdade no iPadOS 26 e fechar o que falta para uso diário:
editor com gutter git, outline, lint e autocompletar; git com PRs, commit por IA e
histórico por arquivo; integração com o sistema (Arquivos, iCloud, Atalhos, compartilhar);
e preparação para a loja.

## 1. Polimento visual (Marco 1)

Princípio: a Odete usa o vocabulário do iPadOS 26 (Liquid Glass, controles nativos,
materiais, SF Symbols com efeitos) por cima das paletas de tema já existentes. Menos
bordas de 1 pt e retângulos chapados; mais camadas de vidro, materiais e espaço.

### Tokens (OdeteUI)

- `Metrics`: escala de espaçamento 4/8/12/16/24/32; raios 8 (controles), 12 (cards), 18
  (painéis flutuantes); alturas: cabeçalho de painel 40, aba 44, linha 40, toque 44.
- Tipografia: `OdeteFont.ui` continua IBM Plex Sans, base 14 no iPad e 13 no iPhone
  (`Metrics.baseFont`); títulos de painel em 11 caixa alta com tracking 1.2; mono 12.5 no
  terminal e no chat.
- Cores: `Theme` ganha `surface` (material de painel: `bgElevated` a 92 % sobre `bg`),
  `separator` (`border` a 60 %) e `glassTint` (accent a 18 %). Bordas de 1 pt só onde
  separam áreas de trabalho (rail/sidebar/centro); dentro dos painéis, espaço e material.

### Componentes (OdeteUI)

- `GlassBar`: barra horizontal em `GlassEffectContainer` + `.glassEffect(.regular, in:
  Capsule())` para o `ModePicker`, a barra de ações do centro, o composer do agente, a
  barra de atalhos do terminal e a barra de abas do retrato.
- `HeaderButton`: 32 pt, ícone `.medium`, fundo em vidro só no hover/press
  (`.hoverEffect(.highlight)`), `.contentTransition(.symbolEffect(.replace))` quando o
  símbolo muda; variante `prominent` para a ação principal do painel.
- `OdeteCard`: fundo `surface` + `.glassEffect(.regular.tint(glassTint))` quando
  selecionado; raio 12; sombra suave (`.shadow(color: .black.opacity(0.18), radius: 10, y: 4)`)
  só em cards flutuantes (hub, sheets); nos painéis, sem sombra.
- `Rail`: seleção em cápsula de vidro com `matchedGeometryEffect`; ícones `.hierarchical`;
  o botão do agente com `symbolEffect(.pulse)` enquanto o agente roda.
- `EditorTabs`: aba ativa com fundo `bg` e indicador de 2 pt em accent, inativas sem borda
  direita; fechar aparece no hover/seleção; ponto de não salvo em accent.
- `PaneHeader`: 40 pt, título 11 caixa alta, ações à direita com 4 pt de espaço.
- Toggles e steppers: nativos com `.tint(accent)`, dentro de `Form`/`List` em
  `.insetGrouped` com `.scrollContentBackground(.hidden)` e fundo `surface` nas linhas;
  nada de toggle solto em VStack.
- Botões: `.glass` para secundário e `.glassProminent` para primário, `controlSize(.regular)`
  no iPad; nunca `bordered`/`borderedProminent` chapados. Texto dos botões em Plex 13
  medium.
- Listas do git, do agente (histórico) e do preview (console): linhas 40 pt, ícone 16,
  texto 13, secundário 11, separadores `separator`.
- Estados vazios: símbolo 34 pt `.hierarchical` em `fgSubtle`, título 15 medium, texto 13
  muted, ação primária em `.glassProminent`.
- Animações: `.snappy(duration: 0.2)` para layout; `symbolEffect(.bounce)` em ações
  concluídas (salvar, commit, aceitar patch); `contentTransition(.numericText())` em
  contadores.

### Telas

- Hub: cabeçalho com marca, subtítulo e ações em `GlassBar`; grade de `OdeteCard` com ícone
  da stack em cápsula colorida, nome 15 semibold, "aberto há…" 11; hover levanta o card.
- Workspace (paisagem): rail em `bgElevated` com cápsula de vidro; sidebar `surface`;
  centro `bg`; agente `surface`; splitters de 8 pt com alça de vidro no hover.
- Retrato: barra inferior em vidro flutuante (cápsula, 8 pt das bordas) com ícones e rótulos.
- Ajustes: `Form` agrupado (Tema em grade de cards dentro de uma seção; Editor; Layout;
  Contas e Git; Contas de IA), tudo nativo.
- Git: hero com branch em cápsula, contadores com `numericText`, cards `OdeteCard`, botões
  de vidro; diff com fundo de linhas a 10 % e gutter mono.
- Terminal: fundo `bg`, saída Plex Mono 12.5, prompt em accent, barra de atalhos em vidro.
- Agente: bolhas do usuário em `bgSubtle` raio 16; resposta sem bolha; cards de patch e
  permissão `OdeteCard`; composer em vidro com sombra; barra de contexto discreta.
- Preview: barra de URL em cápsula de vidro; viewport de iPhone com moldura arredondada e
  sombra.
- Ícone do app e `AccentColor` conferidos com os temas.

## 2. Editor (Marco 2)

- Gutter git: `Repository.diff(.headToWorkdir, path:)` a cada save/reload dá linhas
  adicionadas/alteradas/removidas; Runestone recebe marcas via `TextView.gutter`
  decorações (`LineDecoration` própria desenhada no `gutterLeadingPadding`): verde (added),
  azul (modified), triângulo vermelho (deleted). Toque na marca mostra popover com o diff
  do hunk e "Descartar".
- Outline: parser leve por linguagem (regex por linha) para JS/TS (`function`, `class`,
  `const x = (` , `export`), Swift (`struct/class/enum/func/var body`), Markdown (`#`),
  CSS (seletores), JSON (chaves de nível 1). Painel "Esboço" na sidebar (novo `SidePanel`
  `.outline`) e no `CommandPalette` com `@`.
- Lint: JS/TS via `esbuild.transform` (erros de sintaxe) e regras simples (console.log,
  debugger, var, == null); Swift pelo parser da fase 5; resultados em Problemas e
  sublinhado no editor (Runestone `highlightedRanges`).
- Autocompletar: palavras do documento + caminhos do projeto após `./`/`@`/`from "` +
  snippets por linguagem (`log`, `fn`, `useState`, `struct View`); popover ancorado no
  cursor com `TextViewDelegate` (`textViewDidChangeSelection`), aceita com Tab/Enter.
- Minimap e guias de indentação já têm prefs; guias via Runestone `showIndentGuides`.

## 3. Git (Marco 3)

- PRs: `GhSheet` vira `PullRequestsPane` no painel Git: lista (abertos/meus), detalhe com
  descrição em Markdown, arquivos alterados com diff (via `compare` da API), comentários
  (listar e responder), checks (status), "Mesclar" (merge/squash), "Criar PR" a partir da
  branch atual com título/corpo sugeridos pelo agente.
- Commit por IA: botão "✨" no card Commit chama o provedor ativo com o diff staged (até
  12 kB) e a skill `commit`; preenche a mensagem editável.
- Histórico por arquivo: no menu de contexto do arquivo e no cabeçalho do editor,
  "Histórico" abre uma lista de commits que tocaram o arquivo (`git_revwalk` com pathspec)
  com diff de cada um; "Blame" simples via `git_blame_file` mostrando autor/data por linha
  num painel lateral do editor.

## 4. Sistema (Marco 4)

- Abrir pasta de fora: `fileImporter` de pastas com bookmark de segurança
  (`startAccessingSecurityScopedResource`), projeto "externo" listado no hub com selo;
  `.odete/` dentro da pasta.
- iCloud Drive: opção em Ajustes "Projetos no iCloud" que move `Documents/Projects` para o
  container ubíquo (`NSUbiquitousContainers`, `FileManager.url(forUbiquityContainerIdentifier:)`);
  o app continua funcionando offline; conflitos resolvidos pelo mais recente.
- Atalhos: `AppIntents` `AbrirProjeto`, `RodarComando` (shell no projeto), `PerguntarAoAgente`
  (texto → resposta), `NovoProjeto(template)`; entidades `ProjetoEntity`.
- Compartilhar: `ShareLink` de arquivo/projeto (zip via `Compression`), "Copiar caminho", e
  receber texto/arquivos pelo `onOpenURL`/`handlesExternalEvents` (abrir `.zip` ou pasta
  compartilhada como projeto).
- Documentos: `UIFileSharingEnabled` já está; `LSSupportsOpeningDocumentsInPlace` idem.

## 5. Loja (Marco 5)

- Ícone final (1024) gerado a partir do `OdeteIcon` com fundo em gradiente da marca,
  variantes dark/tinted do iOS 18+; `AccentColor` = accent do tema Odete.
- `PrivacyInfo.xcprivacy` (sem tracking; APIs: UserDefaults, file timestamp, disk space).
- Onboarding: 3 telas na primeira abertura (o que é, onde ficam os dados, contas), com
  `welcomeDone`.
- OAuth do GitHub: `GitHubDeviceFlow.defaultClientId` lido de `Info.plist`
  (`OdeteGitHubClientId`), preenchido pelo usuário quando registrar o OAuth App; a UI só
  mostra "Entrar com GitHub" se existir.
- Textos de loja e capturas: `docs/store/` com descrição, palavras-chave e lista de capturas.

## Testes

- UI: XCUITest de fumaça atualizado (hub → projeto → abas → ajustes) nas duas orientações;
  capturas de referência salvas em `docs/store/`.
- Editor: outline por linguagem, lint JS/TS/Swift, autocompletar (palavras, caminhos,
  snippets), gutter (diff → linhas).
- Git: PR list/detail com API falsa, commit por IA com provedor falso, histórico por arquivo
  e blame em repositório temporário.
- Sistema: intents (parâmetros e resultado), zip/unzip de projeto, bookmark de pasta externa.
- Loja: privacidade presente no bundle; onboarding aparece uma vez.
