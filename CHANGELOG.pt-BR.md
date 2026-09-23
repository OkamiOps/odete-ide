# Changelog

[English](CHANGELOG.md) · **Português**

Todas as mudanças notáveis da Odete. As versões seguem a versão de marketing da App Store; o número
entre parênteses é o build.

## [1.5] (33) — 2026-09-23

O maior lançamento desde a 1.0: perda silenciosa de dados, um git que mentia, um loop travado no
agente e uma stack web pela metade — tudo corrigido — mais histórico local e compactação de
conversa.

### Provedores de IA
- **Sem limite de saída nos modelos de nuvem.** Só o modelo on-device (Apple Intelligence) mantém
  um limite. OpenAI, Codex, Grok e endpoints compatíveis não recebem `max_tokens` nenhum; a
  Anthropic recebe o máximo do próprio modelo.
- **Parâmetros à prova do futuro.** Janela de contexto, limite de saída, tipo de thinking e níveis
  de esforço são descobertos por modelo a partir da API do provedor e do catálogo público
  [models.dev](https://models.dev) (cacheado por um dia), não deduzidos do nome do modelo. Modelos
  desconhecidos usam o formato de requisição mais recente, então lançamentos novos (Claude Opus
  5.5, GPT 6 Sol/Luna, …) funcionam no primeiro dia.
- Requisições ao Claude usam adaptive thinking e `output_config.effort`; a combinação
  `budget_tokens` / `temperature` que retornava 400 no Claude Sonnet 5 acabou. Blocos de thinking
  assinados e o encrypted reasoning da OpenAI são passados de volta entre as rodadas.
- Uma resposta ou tool call truncada vira um erro claro que o modelo consegue agir em cima — nunca
  mais um "invalid JSON" silencioso. Recusas e turnos pausados são tratados.
- Retries com backoff em 429/529/5xx e conexões derrubadas, respeitando o `Retry-After`.
- Um erro de rede ao renovar um token de assinatura não desconecta mais a conta.

### Agente
- **Compactação de conversa em 80% da janela de contexto**, modelada no opencode: as saídas de
  ferramenta antigas são podadas primeiro, depois o começo é resumido e o turno continua. O uso de
  contexto aparece no composer; `/compact` compacta sob demanda. A janela fixa de 24 mensagens
  acabou.
- O freio de repetição não bloqueia mais os ciclos de editar → testar e nunca para o `run_shell`.
- Desistir não deixa mais uma tool call órfã que quebrava toda mensagem seguinte; os pares
  tool call/result são reparados antes de cada requisição.
- Comandos de shell são classificados com o parser de shell de verdade (`>`, `&&`,
  `git branch -D`, `find -delete` contam como escrita). Os caminhos das ferramentas ficam
  confinados ao projeto, com symlinks resolvidos.
- **Stop** realmente para a ferramenta em execução. A saída do `run_shell` sobrevive a um
  scrollback longo.
- Patches: sem limite de 12 patches, aceitar/rejeitar checam o disco e mostram um conflito em vez
  de sobrescrever, arquivos não-UTF-8 nunca são esvaziados. Aceitar/Rejeitar tudo recarrega só as
  abas afetadas.
- Desfazer um turno diz ao modelo o que foi revertido. As conversas são salvas a cada rodada.
- O system prompt e a lista de ferramentas ficam fixos durante toda a conversa (melhor prompt
  caching).

### Histórico local (novo)
- Antes de qualquer escrita ou delete — seu save, o agente, rejeitar um patch, desfazer um turno,
  discard/checkout/merge do git, Substituir tudo, reload, restore, o `rm`/`cp`/`mv`/`>` do
  terminal — a versão anterior fica guardada em `Application Support/Odete/Historico`, fora do
  projeto e do iCloud, deduplicada, com até 50 versões e 30 dias por arquivo (300 MB no total por
  padrão).
- Toque e segure numa aba ou num arquivo para **Histórico local**: conteúdo, diff contra o arquivo
  atual, Restaurar, Copiar. **Arquivos deletados** traz de volta arquivos removidos. Tamanho e
  limpeza nos Ajustes.
- Salvar através de um link simbólico escreve no destino e mantém o link.

### Git
- Um push rejeitado pelo servidor (branch protegida, hook, non-fast-forward) é reportado como
  rejeitado, não "push ok".
- Tocar numa branch remota cria uma branch de tracking local em vez de um HEAD destacado.
- **Descartar** pergunta antes, mostra as contagens de rastreados/não rastreados, manda os
  arquivos para a lixeira do projeto e oferece Desfazer. **Abortar merge** funciona como
  `git merge --abort` e pergunta antes.
- Conflitos sem marcadores (binário, deletado × modificado) podem ser resolvidos com mine/theirs/
  delete.
- "Suas mudanças em X seriam sobrescritas" é reportado como tal, com uma opção de stash e
  continuar.
- **Commit** só faz commit; **Commit & push** faz push. A mensagem só é limpa em caso de sucesso.
- Desfazer um commit que já está no remoto pergunta antes; desfazer o primeiríssimo commit explica
  por que não dá. Deletar uma branch pergunta antes.
- Erros do libgit2 em linguagem simples, com um botão para remover um `index.lock` obsoleto.
- Remotes `git@host:` vão por HTTPS quando existe uma conta para o host.
- Commits de uma conta do GitHub sem e-mail público usam o endereço
  `users.noreply.github.com`.
- O painel Git percebe um repositório criado a partir do terminal.

### Editor
- Uma aba com edições não salvas cujo arquivo mudou no disco mostra uma barra de conflito (manter
  o meu, recarregar, ver diff) e o autosave pausa — nada é sobrescrito silenciosamente.
- Requisições de find/replace são de uma vez só e presas ao seu documento: um editor novo não
  repete mais o último replace, e o split view não substitui mais nos dois painéis.
- **Substituir tudo** do projeto usa a mesma busca da pesquisa, edita buffers abertos e mostra uma
  prévia das contagens.
- Arquivos CRLF continuam CRLF; Tab/⇧Tab recuam e desrecuam seleções; indentação e
  `.editorconfig` são respeitados; o autosave não corta mais o espaço que você acabou de digitar.
- Deletar um arquivo com uma aba não salva salva ele primeiro; fechar uma aba suja com autosave
  desligado pergunta.

### Arquivos e projetos
- A lixeira não deleta mais arquivos antigos na hora, nunca cai num delete permanente, e nunca
  colide nos nomes.
- Editar SQLite escreve na tabela e coluna certas; arquivos `.sql` são somente leitura a menos que
  você confirme uma reescrita.
- Um `state.json` ilegível não reseta mais tudo nem liga o iCloud.
- Mover projetos para ou do iCloud Drive roda fora da thread principal, pergunta antes, mostra
  progresso, renomeia em caso de colisão e desfaz em caso de falha; todas as janelas
  acompanham.
- Renomear ou deletar um projeto aberto em outra janela fecha ele lá primeiro. A ação "Rodar
  comando" dos Atalhos roda na janela certa.
- Zip: suporte a ZIP64, extração com verificação de limites, `.odete` excluído dos zips
  compartilhados.
- Swift playground: ranges invertidos e overflow de inteiro são erros, não crashes.
- Uma pasta externa que sumiu aparece como indisponível, com um jeito de relocalizar ela.

### Terminal e runtime Node
- O shell e o `fs` do runtime ficam confinados à pasta do projeto (mais a pasta temporária e o
  cache do `npx`).
- O `require` normaliza caminhos e deduplica pelo caminho real (zod 4, yargs 17/18, Tailwind 3,
  readable-stream); `imports` (`#subpath`); `import()` fora do esbuild; módulos ES exportando
  `"module.exports"`; um shim de stack trace estilo V8 e `EventEmitter`/`Stream` via function
  constructor (express, depd).
- Rejeições não tratadas saem com código 1; top-level await; `unref`; cancelamento por job para
  `kill %N` e Ctrl+C; stdin encanado para o `node`; stdout binário; `crypto` com hashes, HMAC,
  PBKDF2.
- Cache de transformação em disco e `fs` POSIX: listar `node_modules` foi de 708 ms para 32 ms
  sem JIT.
- Parser: `2>`, `>&2`, `VAR=x cmd`, `cd -`, globbing; `grep`/`find`/`wc`/`echo` aceitam as flags de
  sempre.
- Um smoke test roda 31 pacotes populares sem JIT com a saída exata do Node.

### npm
- O `npm run dev` (e o botão Preview) instala as dependências que faltam antes de subir o
  servidor. O fallback pro `esm.sh` acabou — misturar ele com `node_modules` carregava o React
  duas vezes.
- Depois do `npm install` o dev server é aquecido em segundo plano: primeira inicialização de
  ~6 s → ~0,2 s sem JIT. Mudanças no lockfile são observadas.
- `package.json` e `package-lock.json` saem idênticos byte a byte aos do npm; aliases `npm:`,
  peers obrigatórios, dependências tarball/GitHub/`file:`/`workspace:`, `overrides`; scripts de
  instalação são reportados, não confundidos com código nativo; correções de hoisting e semver;
  links do tar não conseguem escapar.
- `npm ci`, `npx -y`, scripts `pre`/`post`, `yarn`/`pnpm` sem argumentos, e npm/npx encontram o
  `package.json` mais próximo.

### Build web
- Resolução por condição de browser para o dev server e o `vite build` (axios, uuid não deixam
  mais a página em branco); built-ins do Node viram módulos vazios com um aviso, como no Vite.
- `@/` e outros aliases vindos dos paths do `tsconfig` e do `vite.config`; CSS Modules; Sass e Less
  através dos pacotes do projeto; `import.meta.glob`, `?raw`, `?url`, `?inline`, `?worker`.
- **Tailwind CSS v4 do jeito oficial** (`@tailwindcss/vite` + `@import "tailwindcss"`) no Preview
  e no `vite build`, com `@theme`, `@source`, `@apply`, `@plugin`; Tailwind 3 também.

### Next.js e Astro
- Next: CSS por rota (globals, CSS Modules, Tailwind), server components síncronos e assíncronos
  misturados, providers com children como ilhas, ilhas `display: contents`, `next/*` no browser,
  templates, loading, metadata completa e ícones do app. O template do `create-next-app` roda.
- Astro: frontmatter em TypeScript, estilos com escopo com Sass/Tailwind, imagens importadas,
  rotas dinâmicas e `getStaticPaths`, endpoints (`rss.xml`), páginas Markdown/MDX, content
  collections. O template de blog do `create-astro` roda.
- `URL` aceita barras de esquema especial como no WHATWG.

### Outros
- "fichas" agora é "tokens" em português; 1.278 strings traduzidas em cinco idiomas.
- Política de privacidade: adicionado models.dev, removido esm.sh.

## 1.0 (32)

Primeiro lançamento na App Store: IDE nativa em SwiftUI para iPadOS 26 com editor, libgit2, shell,
npm, runtime compatível com Node sobre JavaScriptCore, dev server esbuild-wasm, Preview,
interpretador de preview Swift e um agente de código com patches e checkpoints, em cinco idiomas.

[1.5]: https://github.com/OkamiOps/odete-ide/releases/tag/v1.5
