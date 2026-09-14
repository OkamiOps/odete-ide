# Odete na App Store

Textos, palavras-chave e a lista de capturas para a ficha do app. Tudo em pt-BR; a versão
em inglês vem depois.

## Nome e subtítulo

- Nome: **Odete**
- Subtítulo (30): **IDE completa no seu iPad**

## Descrição

Odete é uma IDE que roda inteira no iPad. Editor com árvore de arquivos, git de verdade
(commits, branches, merge, PRs do GitHub), terminal com npm e dev server, preview ao vivo e
um agente de IA que lê o projeto, roda comandos e propõe patches que você aceita hunk a hunk.

Sem Mac, sem servidor, sem conta obrigatória. Seus projetos ficam em Arquivos → Odete (ou no
iCloud Drive) e podem ser abertos no Swift Playgrounds, no Working Copy ou em qualquer app.

- Projetos web: Vite + React, Astro, HTML estático; npm instala de verdade, esbuild
  transforma TypeScript e JSX, o preview recarrega ao salvar.
- Swift: pacotes `.swiftpm` com preview nativo do subconjunto de SwiftUI e abertura no
  Swift Playgrounds.
- Git: libgit2 embutido, diff por hunk, histórico por arquivo, blame, stash, conflitos com
  editor de merge; GitHub com PRs, checks, comentários e Actions.
- Editor: realce por tree-sitter, gutter com o diff do git, esboço de símbolos, lint e
  autocompletar com snippets.
- Agente: Claude, Codex, Grok ou qualquer API compatível com OpenAI/Anthropic; modos Chat,
  Plan e Build; permissões por ferramenta; checkpoints para desfazer.
- Sistema: Atalhos (abrir projeto, rodar comando, perguntar à Odete, novo projeto),
  compartilhar projeto como .zip, abrir pastas de outros apps.

## Palavras-chave (100)

ide,editor,código,git,github,terminal,npm,vite,react,swift,swiftui,playgrounds,agente,ia,claude

## Categorias

Primária: Ferramentas para desenvolvedores. Secundária: Produtividade.

## Privacidade

Sem coleta de dados. `PrivacyInfo.xcprivacy` declara UserDefaults, timestamps de arquivo,
espaço em disco e boot time (APIs de sistema usadas por Foundation/SwiftUI). Tokens de
GitHub e de IA ficam no Keychain do dispositivo e só vão para os respectivos provedores.

## Notas para a revisão

- O agente usa assinaturas das contas do próprio usuário (OAuth do Claude Code, device code
  do Codex e do Grok) ou chaves de API; nada passa por servidores da Odete.
- O terminal executa JavaScript num JavaScriptCore do próprio app (sem código nativo baixado).
- Conta de teste: não é necessária; tudo funciona sem login.

## Capturas (iPad 13" e 11", paisagem e retrato)

1. Hub com projetos (Vite e Swift).
2. Workspace: editor + git + agente, tema Odete.
3. Terminal com `npm run dev` e preview do React.
4. Diff por hunk com stage/discard.
5. Swift Playground com preview nativo.
6. Agente aplicando um patch com aprovação.
7. Retrato: abas embaixo, agente ao lado.

Referências em `shots/`.
