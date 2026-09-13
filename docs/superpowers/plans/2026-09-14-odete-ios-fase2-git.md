# Odete iOS Fase 2 — Git — Plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Git real (libgit2) com painel, diff, conflitos, remotos HTTPS, conta GitHub e folha de PRs/issues/Actions, tudo no iPad.

**Architecture:** `libgit2.xcframework` compilado por script e versionado; `OdeteGit` (actor `Repository`) e `OdeteAccounts` (Keychain, device flow, GitHubAPI) como pacotes novos; `GitModel` por projeto no app; views em `OdeteApp/Git`.

**Tech Stack:** libgit2 1.9, CMake, Swift 6, SwiftUI, URLSession, Security.framework, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-14-odete-ios-fase2-git-design.md`

## Global Constraints

- iOS 26, Swift 6 strict; nenhum servidor; sem SSH; sem rede nos testes (remotos `file://`).
- Textos em português; toque 44 pt.
- Cada commit na branch `iOS`, com trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Destino de build/teste: `platform=iOS Simulator,id=7B54EEE5-3B0E-40E8-98CA-D14509F539DD` (iPad Air 11-inch M4, iOS 26.5).

---

### Task 1: libgit2.xcframework
**Files:** `ios/Vendor/libgit2/build-libgit2.sh`, `ios/Vendor/libgit2/libgit2.xcframework/` (gerado), `ios/Vendor/libgit2/README.md`.
- [ ] Script: baixa `https://github.com/libgit2/libgit2/archive/refs/tags/v1.9.x.tar.gz`, compila `-DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DUSE_SSH=OFF -DUSE_HTTPS=SecureTransport -DUSE_SHA1=CommonCrypto -DUSE_SHA256=CommonCrypto -DUSE_BUNDLED_ZLIB=ON -DREGEX_BACKEND=regcomp_l -DUSE_ICONV=OFF -DUSE_NTLMCLIENT=OFF` para `iphoneos`/`iphonesimulator` arm64 com `CMAKE_SYSTEM_NAME=iOS`, `CMAKE_OSX_DEPLOYMENT_TARGET=26.0`, junta com `libtool` as libs estáticas (git2 + deps bundled) e roda `xcodebuild -create-xcframework`.
- [ ] Commit: `git: libgit2 1.9 em xcframework`.

### Task 2: OdeteGit núcleo (Marco 1)
**Files:** `ios/Packages/OdeteGit/Package.swift` (binaryTarget `Clibgit2` apontando para `../../Vendor/libgit2/libgit2.xcframework`, target `OdeteGit`), `Sources/OdeteGit/{GitError,Models,Repository,Signature}.swift`, `Tests/OdeteGitTests/RepositoryTests.swift`.
- [ ] Testes: init cria `.git`; status de arquivo novo = untracked; stage → staged added; commit → log 1; modificação → unstaged modified; `.gitignore` esconde.
- [ ] Implementar `Repository` actor com `git_libgit2_init` uma vez, `open/initialize`, `status()`, `stage/unstage(paths)`, `commit`, `log`, `currentBranch`, `aheadBehind`.
- [ ] Commit: `git: OdeteGit com init, status, stage, commit e log`.

### Task 3: Diff, hunks, discard, branches, merge, stash (Marco 2)
**Files:** `Sources/OdeteGit/{Diff,Hunks,Branches,Merge,Stash}.swift`, testes correspondentes.
- [ ] Diff working/index/A-B via `git_diff_*` → `Diff{files:[FileDiff{path,status,hunks:[Hunk{header,oldStart,newStart,lines:[Line{kind,text}]}]}]}`.
- [ ] `stageHunk` aplica patch parcial ao índice (`git_apply` com `GIT_APPLY_LOCATION_INDEX`); `unstageHunk` aplica reverso; `discardHunk` aplica reverso no workdir.
- [ ] Branches: list/create/checkout/delete; merge ff e normal com detecção de conflitos (`git_index_has_conflicts`), `resolveConflict`.
- [ ] Stash: list/push/pop/drop. `undoLastCommit` = reset soft.
- [ ] Commit: `git: diff, hunks, branches, merge, stash`.

### Task 4: Remotos e contas (Marco 3)
**Files:** `Sources/OdeteGit/{Remotes,Credentials}.swift`; `ios/Packages/OdeteAccounts/**`; testes.
- [ ] Clone/fetch/pull/push com callbacks de credencial e progresso; teste com bare local `file://`.
- [ ] `OdeteAccounts`: Keychain, `HostAccount`, `AccountStore`, `GitHubDeviceFlow`, `GitHubAPI` (+ parsers testados com JSON fixo).
- [ ] Commit: `git: remotos HTTPS, contas e device flow do GitHub`.

### Task 5: Interface do Git (Marco 4)
**Files:** `OdeteApp/Sources/OdeteApp/Git/*.swift`, `GitModel.swift`, alterações em `WorkspaceView` (side .git → GitPane), `CenterPane` (.diff → DiffView), `HubView` (Clonar), `SettingsShell` (Contas, Autor), `OdeteEditor` (gutter + conflitos).
- [ ] `GitModel`: `@Observable`, `refresh()` chamado no watcher e após ações, expõe status agrupado, log, branches, stashes, ahead/behind, `busy`, `error`.
- [ ] Views em cartões; DiffView; conflitos; gutter; CloneSheet.
- [ ] Verificar no simulador: iniciar repo, editar, stage, commit, histórico, branch, merge com conflito, clone local.
- [ ] Commit: `app: painel Git, diff, conflitos e clonar`.

### Task 6: GhSheet (Marco 5)
**Files:** `OdeteApp/Sources/OdeteApp/Git/GhSheet.swift`.
- [ ] PRs (lista + detalhe + arquivos + comentar + merge), Criar PR, Issues (lista + criar), Actions (runs). Abre a partir do cabeçalho do GitPane quando o remoto é GitHub e há conta.
- [ ] Commit: `app: folha GitHub com PRs, issues e Actions`.

### Task 7: Fechamento
- [ ] `make unit`, `make test`, `make lint` verdes; README de `ios/` atualizado; commit `ios: fase 2 concluída`.
