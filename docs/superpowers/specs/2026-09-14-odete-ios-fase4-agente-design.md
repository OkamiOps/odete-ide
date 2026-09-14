# Odete iOS — Fase 4: Agente

Data: 2026-09-14. Depende das fases 1 a 3 (`ios/` na branch `iOS`).

## Objetivo

Trazer o agente do Odete web para o iPad e o iPhone com paridade de funções, rodando
inteiramente no dispositivo: o app fala direto com os provedores, executa as
ferramentas sobre o projeto real (arquivos, shell da Odete, git) e guarda tudo em
`.odete/` e no Keychain. Sem servidor da Odete.

Fora desta fase: dois agentes em paralelo (slots A/B), MCP, voz.

## Contas e provedores

Cinco tipos de conta, guardadas pelo `AccountStore` existente (OdeteAccounts) com
segredos no Keychain e refresh automático de token:

| Tipo | Entrada | Refresh | API |
| --- | --- | --- | --- |
| `claude` | OAuth PKCE com o client do Claude Code (`9d1c250a-e61b-44d9-88ed-5944d1962f5e`), `https://claude.com/cai/oauth/authorize`, redirect `https://platform.claude.com/oauth/code/callback`, escopos `user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`. O app abre o Safari (`SFSafariViewController`); o usuário cola `code#state`. Troca em `https://platform.claude.com/v1/oauth/token`. | `grant_type=refresh_token` no mesmo endpoint | `https://api.anthropic.com/v1/messages` com `Authorization: Bearer`, `anthropic-version: 2023-06-01`, `anthropic-beta: oauth-2025-04-20,claude-code-20250219` |
| `codex` | Device code da OpenAI: `POST https://auth.openai.com/api/accounts/deviceauth/usercode` (`client_id app_EMoamEEZ73f0CkXaXp7hrann`), usuário abre `https://auth.openai.com/codex/device` e digita o código; poll em `.../deviceauth/token` (403/404 = pendente) devolve `authorization_code` + `code_verifier`; troca em `https://auth.openai.com/oauth/token` com `redirect_uri https://auth.openai.com/deviceauth/callback`. `accountId` sai do claim `https://api.openai.com/auth.chatgpt_account_id` do JWT. | `grant_type=refresh_token` | `https://chatgpt.com/backend-api/codex/v1/chat/completions` com `Authorization: Bearer`, `originator: codex_cli_rs`, `ChatGPT-Account-ID` |
| `grok` | Device code RFC 8628 em `https://auth.x.ai/oauth2/device/code` com `client_id b1a00492-073a-47ea-816f-4c329264a828` (client público do Grok CLI) e `scope openid profile email offline_access grok-cli:access api:access`; poll em `https://auth.x.ai/oauth2/token` com `grant_type=urn:ietf:params:oauth:grant-type:device_code` (`authorization_pending` / `slow_down`). | `grant_type=refresh_token` | `https://cli-chat-proxy.grok.com/v1/responses` (formato OpenAI Responses) com `Authorization: Bearer`, `User-Agent: grok-pager/0.2.91 grok-shell/0.2.91 (ipados; aarch64)`, `x-grok-client-identifier: grok-pager`, `x-grok-client-version: 0.2.91`, `x-grok-model-override: <modelo>`, `x-grok-conv-id: <id da conversa>` |
| `openaiCompat` | Chave + URL base (ex.: `https://api.openai.com/v1`, OpenRouter, Ollama na rede) | — | `<base>/chat/completions` com `Authorization: Bearer <chave>` |
| `anthropicCompat` | Chave + URL base (ex.: `https://api.anthropic.com`) | — | `<base>/v1/messages` com `x-api-key`, `anthropic-version: 2023-06-01` |

Modelos: `GET` na API quando existe (`/v1/models` Anthropic e OpenAI-compatível; `chatgpt.com/backend-api/codex/models?client_version=<versão do @openai/codex no npm>` para Codex; `<base>/models` para Grok com catálogo fixo `grok-4.6`, `grok-4.5`, `grok-4.3`, `grok-build`, `grok-composer-2.5-fast` como fallback). A tabela de esforço por modelo do web (`effort.ts`) é portada para `Effort.swift`; o padrão é `medium` quando existe.

Um `Session` por conta: `accessToken()` devolve o token válido, renovando com 5 min de folga e serializando renovações concorrentes. Erro `invalid_grant` marca a conta como "reconectar".

## Streaming

Três adaptadores, todos lendo SSE por `URLSession.bytes(for:)` linha a linha e emitindo `StreamEvent`:

```swift
enum StreamEvent: Sendable { case think(String), text(String), tools([ToolCall]), usage(TokenUse), error(String), done }
```

- `ChatCompletionsStream`: `choices[0].delta.{reasoning_content,content,tool_calls[]}` com acumulação por `index`; `usage` com `stream_options.include_usage`. Usado por Codex e OpenAI-compatível. `reasoning_effort` quando o esforço não é `none`; senão `temperature 0.3`.
- `MessagesStream` (Anthropic): `content_block_start` / `content_block_delta` (`thinking_delta`, `text_delta`, `input_json_delta`), `message_delta.usage`. Mapeamento de esforço: low → `budget 1024 / max_tokens 4000`, medium → `4096 / 9000`, high → `8192 / 14000`, max → `16000 / 24000`, com `thinking.enabled` e `output_config.effort`. Usado por Claude e Anthropic-compatível (`x-api-key` em vez de Bearer).
- `ResponsesStream` (OpenAI Responses): eventos `response.output_text.delta`, `response.reasoning_summary_text.delta`, `response.output_item.added` (`function_call` com `call_id`, `name`), `response.function_call_arguments.delta`, `response.completed.usage`. Entrada: `input` com itens `message`, `function_call`, `function_call_output`; `tools` com `{type:"function", name, parameters}`; `reasoning.effort`. Usado por Grok.

O histórico é `[AgentMessage]` (roles system/user/assistant/tool, `content`, `thinking`, `images`, `toolCalls`, `toolCallId`), convertido por adaptador. O sistema leva `SYSTEM_PROMPT` + prompt do modo + lista de arquivos (até 400, sem ruído) + skills e regras; só as últimas 24 mensagens vão.

## Loop e ferramentas

`AgentLoop.run(thread:, userText:, images:, config:)` é um `AsyncStream<ChatItem>`:

1. Checkpoint do turno (ver abaixo).
2. Até 8 rodadas: streama um turno; para cada `toolCall` decide permissão, executa e anexa `tool` ao histórico.
3. Sem `toolCalls` → fim. Na 8ª rodada com ferramentas → item de erro "parei em 8 rodadas".
4. `steer(text)` cancela a `URLSessionTask` corrente, marca ferramentas abertas como "cancelado: o usuário redirecionou", injeta a mensagem e recomeça a contagem.
5. `stop()` cancela e encerra com "parado".

Ferramentas (mesmos nomes e schemas do web):

| Nome | Implementação |
| --- | --- |
| `read_file` | `FileOps.read`, até 200 kB |
| `str_replace` | exige uma ocorrência; em build vira patch; em plan só `.odete/plan.md` |
| `write_file` | idem |
| `list_dir` | `FileOps.list` sem ruído |
| `grep` | `TextSearch` (OdeteFiles) com regex |
| `read_terminal` | últimas N linhas (padrão 80, máximo 200) da aba ativa do `RunModel` |
| `run_shell` | `Shell.run` numa aba dedicada "agente" do terminal; saída limitada a 200 kB; chat só comandos de leitura (`ls cat head tail grep find git status/log/diff/branch pwd wc echo which npm ls`); plan idem mais `mkdir/touch` em `.odete/`; `kill all`, `rm -r` da raiz e `git push --force` bloqueados |

Modos: `chat` (só leitura), `plan` (escreve só `.odete/plan.md`, formato do web), `build`.
Permissões: `ask` (tudo), `auto` (só o que escreve ou roda), `full` (nada). A aprovação
é um item `permit` no chat com Aprovar/Recusar; recusa vira resultado "usuário recusou".

Contexto extra no sistema:
- Regras: `AGENTS.md`, `CLAUDE.md`, `.odete.md`, `.cursorrules`, `.odete/rules.md` (até 6 kB cada).
- Skills: `.odete/skills/*.md` com front matter `name/description/when`, mais as quatro embutidas (commit, swiftui, review, html). Sem `/nome` no prompt entra só a lista; com `/nome` entra o corpo.
- Menções `@caminho` no texto do usuário viram blocos com o conteúdo do arquivo (até 40 kB cada).

## Patches e checkpoints

`PatchStore` (por projeto, em `.odete/patches.json`): `Patch {id, path, before, after, orig, status}`. `queue` funde com o pendente do mesmo caminho. `accept` só grava se o arquivo ainda está em `before` ou `orig`; `acceptHunk` usa `Hunks` (OdeteGit `PatchText`) para manter um hunk; `reject` e `undo` voltam para `orig`. O editor mostra o patch pendente como faixa no topo com Aceitar / Rejeitar / Ver diff; o chat mostra o diff inline.

`CheckpointStore` (`.odete/checkpoints/<id>/`): antes de cada turno copia os arquivos
que não são ruído e têm menos de 200 kB (até 220 arquivos) e grava `manifest.json`
(`title`, `at`, `paths`). `restore` reescreve os arquivos do snapshot, apaga os que
não existiam e rejeita patches pendentes. Guarda os 8 últimos por projeto.

## Conversas

`ChatStore` em `.odete/chats/<id>.json`: `ChatThread {id, title, updated, items, messages, usage, lastInput}`. Itens de UI (`ChatItem`: user, assistant, think, tool, permit, error, patch) e histórico (`messages`, últimas 40) são salvos ao fim de cada turno com os mesmos limites do web (80 itens, pensamento 8 kB, resposta 20 kB, patch 4 kB cada lado). Título = primeiro pedido do usuário (48 caracteres). Uso de tokens acumulado por conversa; janela de contexto por modelo (`ctx` da API ou 128 k) alimenta a barra.

## UI (OdeteApp/Agent)

- `AgentColumn` (iPad, coluna direita) e aba Agente no iPhone, ambas `AgentPane`.
- Cabeçalho: menu de conta/modelo (agrupado por provedor, com "conectar" quando não há conta), esforço, histórico de conversas, nova conversa, desfazer último turno (checkpoint).
- Lista: mensagens do usuário (com miniaturas), resposta em Markdown (`Text(markdown)` por parágrafo, blocos de código em mono com copiar), pensamento colapsado com "pensando…" ao vivo, ferramentas agrupadas numa linha expansível, pedidos de permissão com botões, patches com diff colorido e Aceitar/Rejeitar/Hunk, erros.
- Composer: `TextEditor` que cresce até 6 linhas, botão de anexo (fototeca e captura do preview via `WKWebView.takeSnapshot`), menus `@` e `/` com filtro ao digitar, seletor de modo (Chat/Plan/Build) e de permissão (Ask/Auto/Full), enviar ou parar; com o agente rodando, enviar vira "redirecionar".
- Rodapé: tokens do turno e da conversa, barra de contexto.
- Ajustes → Contas: cinco tipos; folhas `ClaudeConnectSheet` (Safari + colar código), `DeviceCodeSheet` (código grande, botão de abrir a URL, spinner de poll) para Codex e Grok, `ApiKeySheet` (nome, chave, URL base) para os compatíveis.
- Comandos: ⌘⇧A foca o agente; ⌘⏎ envia; Esc para.

## Erros

- Sem conta → item de erro com botão "Conectar" que abre Ajustes.
- HTTP 401 → tenta refresh uma vez; falhou → marca conta "reconectar".
- 429 e 5xx → item de erro com o corpo (240 caracteres) e "tentar de novo".
- Rede caiu no meio → mantém o texto parcial e mostra o erro.
- Ferramenta com JSON inválido → resultado "argumentos JSON inválidos".

## Testes

- `OdeteAgentTests`: os três parsers de SSE com fixtures gravadas em `Tests/Fixtures`; conversão de histórico para os três formatos; `AgentLoop` com `FakeProvider` (texto, ferramenta, permissão negada, redirecionar, 8 rodadas); ferramentas sobre projeto temporário (str_replace único/ausente/duplo, plan bloqueando fora de `.odete`, run_shell em chat bloqueando `npm install`); `PatchStore` (queue funde, accept, acceptHunk, reject, undo) e `CheckpointStore` (take/restore); device flow do Grok e do Codex com `URLProtocol` falso; `Session.accessToken` renovando uma vez sob concorrência; skills e regras; menções.
- `WorkspaceModelTests` ganha um caso de `AgentModel` (nova conversa, enviar com provedor falso, itens aparecem, salvos em `.odete/chats`).
- Verificação no simulador com a conta real do usuário: conectar Grok por device code, pedir "cria um botão em App.tsx", ver patch, aceitar, preview recarregar.
