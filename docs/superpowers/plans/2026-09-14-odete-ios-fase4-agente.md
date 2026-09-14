# Odete iOS Fase 4 — Agente — Plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Agente com paridade ao Odete web rodando no iPad/iPhone: cinco tipos de conta, streaming dos três formatos, loop com sete ferramentas sobre o projeto real, patches, checkpoints, conversas e a UI completa.

**Architecture:** Pacote `OdeteAgent` (puro Swift, sem UI) com `Providers/` (auth + streaming), `Loop/` (AgentLoop, tools, permit, steer), `Store/` (chats, patches, checkpoints), `Context/` (rules, skills, mentions). UI em `OdeteApp/Agent/` sobre um `AgentModel` @Observable por projeto. As ferramentas usam OdeteFiles, OdeteShell e OdeteGit já existentes.

**Tech Stack:** Swift 6, SwiftUI, URLSession bytes SSE, Keychain via OdeteAccounts, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-14-odete-ios-fase4-agente-design.md`

## Global Constraints

- iOS/iPadOS 26+, Swift 6 strict concurrency, sem servidor da Odete.
- Segredos só no Keychain (`SecretStore`); nada em UserDefaults ou `.odete/`.
- Textos em pt-BR; nomes de ferramentas iguais ao web (`read_file`, `str_replace`, `write_file`, `list_dir`, `grep`, `read_terminal`, `run_shell`).
- Cada task termina com `xcodebuild test` do pacote no simulador `7B54EEE5-3B0E-40E8-98CA-D14509F539DD` verde e commit na branch `iOS`.

---

### Task 1: Contas e sessões (Marco 1)

**Files:**
- Modify: `ios/Packages/OdeteAccounts/Sources/OdeteAccounts/{HostAccount,AccountStore}.swift` — `HostKind` ganha `claude, codex, grok, openaiCompat, anthropicCompat`; `HostAccount` ganha `baseURL`, `accountId`, `expiresAt`, `needsReconnect`.
- Create: `ios/Packages/OdeteAgent/Package.swift`, `Sources/OdeteAgent/Providers/{ProviderKind,OAuth,ClaudeAuth,OpenAIDeviceAuth,GrokDeviceAuth,Session}.swift`
- Test: `Tests/OdeteAgentTests/AuthTests.swift` (URLProtocol falso)

**Interfaces:**
- `enum ProviderKind: claude, codex, grok, openaiCompat, anthropicCompat` com `label`, `authStyle (oauthPaste, deviceCode, apiKey)`, `defaultBaseURL`.
- `struct TokenBundle { access, refresh, expiresAt, accountId }`.
- `ClaudeAuth.authorizeURL() -> (url, verifier, state)`, `exchange(code:state:verifier:)`, `refresh(_:)`.
- `OpenAIDeviceAuth.start() -> DeviceStart {userCode, verificationURL, interval, handle}`, `poll(handle) -> PollResult (.pending | .tokens)`, `refresh`.
- `GrokDeviceAuth.start()`, `poll`, `refresh` (RFC 8628).
- `actor Session { init(account:, secrets:, http:) ; func accessToken() async throws -> String }` renovação única sob concorrência, 300 s de folga.

- [x] Escrever `AuthTests`: PKCE gera verifier/challenge S256 válidos; Claude exchange envia JSON certo; OpenAI device poll 403 = pendente e depois troca; Grok device `authorization_pending` → `slow_down` → tokens; `Session` com dois `accessToken()` concorrentes faz um refresh só.
- [x] Implementar até passar. Commit: `agent: contas Claude, Codex, Grok e compatíveis com sessões`.

### Task 2: Streaming (Marco 2)

**Files:**
- Create: `Sources/OdeteAgent/Providers/{AgentMessage,SSE,ChatCompletionsStream,MessagesStream,ResponsesStream,Provider,Effort,ModelList}.swift`
- Test: `Tests/OdeteAgentTests/StreamTests.swift`, `Tests/OdeteAgentTests/Fixtures/{chat,messages,responses}.sse`

**Interfaces:**
- `struct AgentMessage { role, content, thinking, images, toolCalls, toolCallId }`, `struct ToolCall { id, name, arguments }`, `struct TokenUse`.
- `enum StreamEvent`.
- `protocol Provider { func stream(turn: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error>; func models() async throws -> [ModelInfo] }`.
- `struct TurnRequest { system, messages, tools: [ToolSpec], model, effort }`.
- `Effort.options(kind:model:)`, `Effort.default(_:)`.
- `ProviderFactory.make(account:, session:) -> Provider`.

- [x] Fixtures gravadas à mão a partir dos formatos reais; testes: cada parser reproduz think/text/tools/usage; conversões de histórico (tool result vira `user` block no Anthropic, `function_call_output` no Responses); `Effort` para 6 modelos.
- [x] Implementar. Commit: `agent: streaming Chat Completions, Messages e Responses`.

### Task 3: Ferramentas, loop, patches e checkpoints (Marco 3)

**Files:**
- Create: `Sources/OdeteAgent/Loop/{Tools,ToolRunner,Permit,AgentLoop,Prompts}.swift`, `Sources/OdeteAgent/Store/{PatchStore,CheckpointStore,ChatStore}.swift`, `Sources/OdeteAgent/Context/{Rules,Skills,Mentions}.swift`
- Test: `Tests/OdeteAgentTests/{ToolsTests,LoopTests,StoreTests,ContextTests}.swift`

**Interfaces:**
- `enum AgentMode: chat, plan, build`; `enum PermitMode: ask, auto, full`.
- `protocol ToolHost: Sendable { read/write/list/grep/terminalTail/runShell }` — implementado no app por cima de FileOps/RunModel/Shell; testes usam `TempHost`.
- `ToolRunner.run(call:, mode:, host:, patches:) async -> ToolOutcome { text, patch? }`.
- `AgentLoop(provider:, host:, patches:, checkpoints:, config: LoopConfig {mode, permit, model, effort, systemExtras})`; `run(history:, userText:, images:) -> AsyncStream<LoopEvent>` onde `LoopEvent = .item(ChatItem) | .usage(TokenUse) | .history([AgentMessage]) | .permitRequest(id) | .done`; `approve(id:, ok:)`, `steer(_:)`, `stop()`.
- `PatchStore(root:)`: `queue/accept/acceptHunk/reject/undo/pending`, salva `.odete/patches.json`.
- `CheckpointStore(root:)`: `take(title:) -> id`, `restore(id:)`, `list()`.
- `ChatStore(root:)`: `load/save/list/new/remove`.
- `Rules.prompt(root:)`, `Skills.all(root:)`, `Skills.prompt(all:, userText:)`, `Mentions.expand(text:, root:)`.

- [x] Testes primeiro (FakeProvider com roteiro de eventos).
- [x] Implementar. Commit: `agent: loop com ferramentas, permissões, patches, checkpoints e conversas`.

### Task 4: UI no app (Marco 4)

**Files:**
- Create: `ios/Packages/OdeteApp/Sources/OdeteApp/Agent/{AgentModel,AgentPane,ChatList,ChatBubbles,PatchCard,Composer,MentionMenu,ModelMenu,HistorySheet,AppToolHost}.swift`, `Accounts/{ClaudeConnectSheet,DeviceCodeSheet,ApiKeySheet}.swift`
- Modify: `WorkspaceView.swift` (AgentColumn → AgentPane), `PhoneShell.swift`, `WorkspaceModel.swift` (`agent: AgentModel`), `Git/AccountsSettings.swift` (cinco tipos), `Commands.swift` (⌘⇧A, ⌘⏎), `CenterPane.swift` (faixa de patch pendente no editor), `OdeteApp/Package.swift`, `project.yml`, `Makefile`.
- Test: `WorkspaceModelTests` + `AgentModelTests` com FakeProvider.

- [x] `AgentModel`: conta/modelo/esforço escolhidos (persistidos no ChromeState por projeto), thread ativa, itens, running, permit pendente, enviar/parar/redirecionar, aceitar/rejeitar patch, desfazer turno, uso de tokens.
- [x] Views conforme a spec; Markdown com `AttributedString(markdown:)` por bloco e código mono.
- [x] Contas em Ajustes com as três folhas.
- [x] Commit: `agent: painel do agente, composer, patches no editor e contas`.

### Task 5: Verificação e fechamento (Marco 5)

- [ ] Simulador com conta real (pendente do usuário: conectar Grok/Claude em Ajustes → Contas de IA e pedir uma mudança em `App.tsx`).
- [x] `make lint`, `make unit`, `make test` verdes; README (seção Agente, pendências); memória.
- [x] Commit: `ios: fase 4 concluída`.
