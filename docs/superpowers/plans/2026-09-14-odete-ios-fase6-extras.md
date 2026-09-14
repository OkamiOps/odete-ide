# Odete iOS Fase 6 — Polimento e extras — Plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Interface bonita no iPadOS 26 e os extras de editor, git, sistema e loja.

**Architecture:** Tokens e componentes novos em OdeteUI; telas reescritas por cima; editor ganha `Outline`, `Lint`, `Complete` e `GitGutter` em OdeteEditor/OdeteCore; git ganha `PullRequests`, `CommitAI`, `FileHistory`/`Blame` em OdeteGit/OdeteAccounts/OdeteApp; sistema em `OdeteApp/System/` (intents, importar pasta, iCloud, compartilhar); loja em `Odete/` (ícone, privacidade, onboarding).

**Spec:** `docs/superpowers/specs/2026-09-14-odete-ios-fase6-extras-design.md`

## Global Constraints

- iOS/iPadOS 26+, Swift 6, Liquid Glass; nada de `bordered` chapado.
- Cada marco termina com `make lint`, testes do pacote e `make test` verdes, captura no simulador (retrato e paisagem) e commit na branch `iOS`.

---

### Marco 1: Polimento visual
- [ ] Tokens (`Metrics`, `Theme.surface/separator/glassTint`, `baseFont`) e componentes `GlassBar`, `OdeteCard`, `HeaderButton` novo, `Rail` com cápsula, `EditorTabs`, `PaneHeader`.
- [ ] Hub, Ajustes (`Form`), Workspace/retrato (barra flutuante), Git, Terminal, Agente, Preview.
- [ ] Capturas antes/depois em `docs/store/shots/`; commit `ui: polimento Liquid Glass`.

### Marco 2: Editor
- [ ] `Outline` (OdeteCore) + testes; painel Esboço e `@` na paleta.
- [ ] `Lint` (OdeteBundler transform + regras; Swift parser) + Problemas + sublinhado.
- [ ] `Complete` (palavras, caminhos, snippets) + popover no editor.
- [ ] `GitGutter` (diff por linha) + decorações + popover do hunk.
- [ ] Commit `editor: gutter git, esboço, lint e autocompletar`.

### Marco 3: Git
- [ ] `GitHubAPI` PRs (lista, detalhe, arquivos, comentários, checks, merge, criar) + `PullRequestsPane`.
- [ ] Commit por IA (`CommitAI`) no card Commit.
- [ ] Histórico por arquivo e blame (OdeteGit) + `FileHistorySheet`/`BlameView`.
- [ ] Commit `git: PRs, commit por IA, histórico e blame`.

### Marco 4: Sistema
- [ ] Pasta externa com bookmark; selo no hub.
- [ ] iCloud Drive opcional.
- [ ] AppIntents (abrir, rodar, perguntar, novo) + entidades.
- [ ] Compartilhar/receber (zip) + `onOpenURL`.
- [ ] Commit `sistema: Arquivos, iCloud, Atalhos e compartilhar`.

### Marco 5: Loja e fechamento
- [ ] Ícone, `PrivacyInfo.xcprivacy`, onboarding, client_id do GitHub por Info.plist, `docs/store/`.
- [ ] `make lint`, `make unit`, `make test`; README; memória; commit `ios: fase 6 concluída`.
