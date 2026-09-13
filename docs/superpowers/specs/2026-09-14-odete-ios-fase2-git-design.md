# Odete iOS — Fase 2: Git

Data: 2026-09-14. Estado: aprovado. Depende da Fase 1.

## Objetivo

Git de verdade no iPad: repositório `.git` real em cada projeto, operações locais completas,
clone/fetch/pull/push por HTTPS com token, conta GitHub por device flow, e a folha GitHub
(PRs, issues, Actions). Tudo no dispositivo, sem servidor.

## Decisões

| Tema | Decisão |
|---|---|
| Biblioteca | libgit2 1.9 compilado por nós em `libgit2.xcframework` (iphoneos + iphonesimulator, arm64), HTTPS via SecureTransport, SHA via CommonCrypto, sem SSH. |
| Wrapper | Pacote `OdeteGit`, Swift 6, `Repository` como `actor`; depende só de `OdeteCore`. |
| Auth | Token por host no Keychain (GitHub, GitLab, Gitea, Bitbucket) + device flow do GitHub. |
| Escopo | Status, stage/unstage por arquivo e hunk, discard, commit, undo commit, log, diff (working/index/commit A-B), branches (criar/trocar/apagar/merge ff e com conflitos), stash, clone/fetch/pull/push, `.gitignore`, folha GitHub. Fora: rebase interativo, submódulos, cherry-pick, blame, SSH. |
| Consumidores futuros | Terminal (`git …`, Fase 3) e agente (Fase 4) chamam a mesma API. |

## Módulos

```
ios/Vendor/libgit2/
  build-libgit2.sh        # baixa o tarball 1.9.x, compila com CMake, gera libgit2.xcframework
  libgit2.xcframework/    # versionado
  module.modulemap        # Clibgit2
ios/Packages/OdeteGit/
  Sources/Clibgit2/       # binaryTarget + shim de headers
  Sources/OdeteGit/
    Repository.swift      # actor: open/init/clone, status, index, commit, log, branches, merge, stash, remotes
    Models.swift          # StatusEntry, Commit, Branch, Diff/Hunk/Line, StashEntry, Remote, MergeResult, Conflict
    Credentials.swift     # callback libgit2 ← HostAccount
    GitError.swift        # mapeia git_error_last
    Ignore+Git.swift      # respeita .gitignore no status
ios/Packages/OdeteAccounts/
  Sources/OdeteAccounts/
    Keychain.swift        # Security.framework, serviço "com.okamiops.odete"
    HostAccount.swift     # host, login, token, kind (github|gitlab|gitea|bitbucket|other)
    AccountStore.swift    # @Observable lista de contas
    GitHubDeviceFlow.swift# device code → polling → token
    GitHubAPI.swift       # user, repos, pulls, issues, actions, compare
ios/Packages/OdeteApp/Sources/OdeteApp/
  Git/GitPane.swift, ChangesCard.swift, CommitCard.swift, HistoryCard.swift,
      BranchesCard.swift, ConflictsCard.swift, DiffView.swift, GhSheet.swift,
      CloneSheet.swift, AccountsSettings.swift
  WorkspaceModel+Git.swift  # GitModel por projeto: status, diffs, ações, refresh após watcher
ios/Packages/OdeteEditor/   # gutter de git (linhas add/mod) e blocos de conflito
```

Dependências: `OdeteApp → {OdeteGit, OdeteAccounts, OdeteUI, …}`; `OdeteGit → OdeteCore`;
`OdeteAccounts → OdeteCore`.

## API do `Repository` (resumo)

```swift
actor Repository {
  static func open(_ url: URL) throws -> Repository
  static func initialize(at url: URL) throws -> Repository
  static func clone(_ remote: URL, to url: URL, credentials: Credentials?, progress: @Sendable (CloneProgress) -> Void) async throws -> Repository
  func status() throws -> [StatusEntry]              // path, staged: Change?, unstaged: Change?, conflicted
  func stage(_ paths: [String]) throws; func unstage(_ paths: [String]) throws
  func stageHunk(_ h: Hunk, in path: String) throws; func unstageHunk(...); func discardHunk(...)
  func discard(_ paths: [String]) throws
  func commit(message: String, author: Signature) throws -> Commit
  func undoLastCommit() throws                        // soft reset HEAD~1
  func log(limit: Int, from: String?) throws -> [Commit]
  func diffWorkdir(path: String?) throws -> Diff; func diffIndex(...); func diff(from: String, to: String) throws -> Diff
  func branches() throws -> [Branch]; func currentBranch() throws -> Branch?
  func createBranch(_ name: String, checkout: Bool) throws; func checkout(_ name: String) throws; func deleteBranch(_:) throws
  func merge(_ name: String) throws -> MergeResult   // .upToDate, .fastForward, .merged(Commit), .conflicts([Conflict])
  func resolveConflict(path:, contents:) throws       // grava e marca resolvido
  func stashes() throws -> [StashEntry]; func stashPush(message:) throws; func stashPop(_:) throws; func stashDrop(_:) throws
  func remotes() throws -> [Remote]; func addRemote(name:url:) throws
  func fetch(remote:credentials:) async throws; func pull(...) async throws -> MergeResult; func push(...) async throws
  func aheadBehind() throws -> (ahead: Int, behind: Int)
}
```

## Contas e GitHub

- `Keychain.set/get/delete(key:)` com `kSecClassGenericPassword`, acessível após primeiro desbloqueio.
- Device flow: `POST https://github.com/login/device/code` (client_id, scope `repo read:org workflow`),
  mostra `user_code` e abre `verification_uri`; polling em `login/oauth/access_token` respeitando `interval`
  e `slow_down`. `client_id` é público e fica em `OdeteAccounts/GitHubApp.swift`; até o app ser registrado,
  o usuário pode colar um token.
- `GitHubAPI` com `URLSession`, `Authorization: Bearer`, paginação por `Link`. Endpoints: `/user`,
  `/user/repos`, `/repos/{o}/{r}/pulls` (list, create, files, comments, merge), `/issues` (list, create),
  `/actions/runs`, `/compare/{base}...{head}`.
- Credenciais para libgit2: usuário `x-access-token` + token no GitHub; `oauth2`/token nos demais.

## Interface

- **GitPane** (sidebar): cabeçalho (branch, ahead/behind, Fetch/Pull/Push); cartões Alterações, Commit,
  Histórico, Branches e stash, Conflitos (só quando há). Toque num arquivo abre o modo Diff.
- **DiffView** (centro, modo Diff): unificada por padrão, lado a lado em telas largas; hunks com
  "Stage hunk"/"Descartar hunk"; cabeçalho escolhe fonte (working/staged/commit A→B).
- **Conflitos** no editor: blocos destacados com "Manter meu", "Manter deles", "Ambos".
- **Gutter** do editor: marcas de adicionado/modificado contra HEAD.
- **Hub**: "Clonar repositório" (URL ou lista de repos da conta) com progresso e cancelamento.
- **GhSheet**: PRs, Criar PR (base/head, título, corpo), Issues, Actions.
- **Ajustes → Contas**: entrar com GitHub (device flow), adicionar token por host, remover.
- **Ajustes → Git**: nome e e-mail do autor (padrão do usuário GitHub quando logado).
- Projeto sem `.git`: painel mostra "Iniciar repositório".

## Erros

`GitError` traz mensagem do libgit2 em português curto ("remoto recusou: 401"), classe (`auth`,
`network`, `conflict`, `notFound`, `other`). Auth falha → painel oferece "Entrar" abrindo Contas.
Rede ausente → ações remotas desabilitadas com aviso, locais seguem.

## Testes

- `OdeteGitTests` (Swift Testing, diretório temporário): init/commit/status; stage e unstage por hunk;
  discard; log e diff A-B; branch/checkout/merge ff; merge com conflito e resolução; stash;
  clone `file://` + push/pull entre dois repositórios locais (bare).
- `OdeteAccountsTests`: parser do device flow (incl. `authorization_pending`, `slow_down`), parser de
  PRs/issues/runs com JSON fixo, Keychain round-trip.
- UI: criar projeto → iniciar repositório → commit → histórico com 1 commit.

## Marcos

1. `libgit2.xcframework` + `OdeteGit` com init/status/stage/commit/log e testes.
2. Diff (working/index/A-B), hunks, discard, branches, merge, stash, conflitos.
3. Remotos: clone/fetch/pull/push com `file://` e HTTPS; `OdeteAccounts` + device flow + Ajustes → Contas.
4. Interface: GitPane, DiffView, conflitos no editor, gutter, Clonar no hub.
5. GhSheet (PRs, issues, Actions) e Criar PR.

## Fora de escopo

Rebase interativo, submódulos, cherry-pick, blame, SSH, assinatura GPG, LFS.
