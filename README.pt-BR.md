<div align="center">

<img src="docs/img/icone.png" width="104" alt="Odete" />

# Odete

**Uma IDE de verdade que roda inteira num iPad.**
Editor, git, terminal, npm, preview ao vivo e um agente de código — sem Mac, sem servidor, sem runner remoto.

[![Plataforma](https://img.shields.io/badge/iPadOS%20%C2%B7%20iOS-26%2B-000000?style=flat-square&logo=apple&logoColor=white)](#requisitos)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](#arquitetura)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-nativo-0A84FF?style=flat-square)](#arquitetura)
[![No dispositivo](https://img.shields.io/badge/roda-100%25%20no%20dispositivo-34C759?style=flat-square)](#como-isso-funciona-de-verdade)
[![Idiomas](https://img.shields.io/badge/idiomas-5-FF6B2C?style=flat-square)](#falando-cinco-idiomas)
[![Testes](https://img.shields.io/badge/testes-223-8E8E93?style=flat-square)](#contribuindo)

[English](README.md) · **Português** · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md)

</div>

---

> **TL;DR** — Odete é uma IDE nativa em SwiftUI para iPadOS 26. Tem um repositório git de verdade por
> projeto (libgit2), um shell que realmente roda `npm install` e `npm run dev`, um runtime compatível
> com Node em cima do JavaScriptCore, esbuild compilado para WebAssembly, e um agente de IA que lê seus
> arquivos, roda comandos e propõe patches que você aceita hunk por hunk. Nada é compilado na
> nuvem. Nada é enviado para lugar nenhum. Feche a tampa do notebook — não existe notebook.

<div align="center">
  <img src="docs/img/preview.png" width="900" alt="Um projeto Vite rodando na Odete: código-fonte à esquerda, dev server no terminal, página ao vivo no Preview" />
  <br />
  <sub>Um projeto React + Vite: código, dev server e a página ao vivo — tudo no iPad.</sub>
</div>

---

## Por que isso existe

O iPad é um computador rápido com uma história de desenvolvimento sofrível. As respostas de sempre são uma
VM remota, uma IDE web, ou um Mac na sala ao lado. As três significam: sem avião, sem metrô, sem sinal, sem trabalho.

Odete vai pelo outro caminho. Tudo o que precisa rodar, roda aqui.

<table>
<tr>
<td width="50%" valign="top">

<h3>✅ O que ela faz</h3>

- Edita código com destaque via tree-sitter e autocomplete de verdade
- Clona, faz commit, branch, merge, push — git de verdade
- Roda `npm install` contra o registro real
- Roda `npm run dev` e serve seu app em `127.0.0.1`
- Renderiza o app rodando num painel de Preview com hot reload
- Roda um agente de IA com ferramentas, patches e checkpoints
- Fala 5 idiomas, das telas à saída do terminal

</td>
<td width="50%" valign="top">

<h3>❌ O que ela não faz</h3>

- Sem compilador Swift (a Apple não entrega um para iOS)
- Sem SSH para git — só HTTPS e tokens
- Sem binários nativos (`esbuild`, `swc`, `lightningcss`) —
  a Odete substitui pelos equivalentes dela
- Sem `astro build` / `next build` ainda — só modo dev
- Sem submódulos, cherry-pick ou rebase interativo
- Sem conta obrigatória, e sem telemetria também

</td>
</tr>
</table>

---

## Os cinco painéis

<table>
<tr>
<td width="50%" valign="top">

<h3>📝 Editor</h3>

Runestone com tree-sitter. Marcas de git na margem (verde, azul, vermelho — toque numa para abrir o hunk
com **Descartar**), os símbolos do arquivo a um `@` de distância na paleta de comandos, lint leve por linguagem mais erros de sintaxe reais
vindos do esbuild, e completion a partir das palavras do arquivo, caminhos do projeto e snippets.

Abas, split view, diff view, visualizadores de imagem/PDF/SQLite. Buffers não salvos sobrevivem a um restart.

</td>
<td width="50%" valign="top">

<h3>🌿 Git</h3>

libgit2, não um wrapper. Status, stage por arquivo ou por hunk, commit, branch, merge com resolução
de conflito, stash, remotes por HTTPS, blame e histórico por arquivo.

Pull requests do GitHub vivem no painel: abra uma, leia o Markdown, veja o CI, comente, faça merge.
✨ escreve a mensagem de commit a partir do diff em stage.

</td>
</tr>
<tr>
<td valign="top">

<h3>⌨️ Terminal</h3>

O shell da própria Odete — pipes, redirecionamentos, `&&`, `||`, `;`, `&`, `$VAR`, controle de jobs, histórico e completion
com Tab. `npm`, `node`, `git`, `npx`, mais os de sempre `ls`/`cat`/`grep`/`find`.

Qualquer coisa que abra uma porta vira um job (`jobs`, `kill %1`) e o Preview segue o último.

</td>
<td valign="top">

<h3>▶️ Preview</h3>

Um WKWebView apontado para o seu dev server, recarregando toda vez que você salva. Viewports de
iPhone/iPad/desktop, o console da própria página, e um toque para abrir no Safari.

Sem servidor rodando, o `index.html` é servido direto do disco via `odete://static/`.

</td>
</tr>
<tr>
<td colspan="2" valign="top">

<h3>✨ Agente</h3>

Traga sua própria conta — Claude (OAuth de assinatura), Codex e Grok (device code), ou qualquer
endpoint compatível com OpenAI/Anthropic por chave e base URL. Os tokens ficam no Keychain, nunca
num arquivo.

Oito ferramentas rodam contra o projeto real: ler, escrever, substituir, listar, grep, ler o terminal,
rodar um comando de shell, e falar com a API do GitHub. Três modos — **Chat** lê, **Plan** escreve
só em `.odete/plan.md`, **Build** edita. Três níveis de permissão — **Ask**, **Auto**, **Full** —
e qualquer coisa que escreva no repositório de outra pessoa pergunta sempre, mesmo no Full.

Toda edição chega como um patch que você aceita, rejeita, ou aceita hunk por hunk. Um checkpoint é
gravado antes de cada turno, então "desfazer o último turno" é um toque.

</td>
</tr>
</table>

<div align="center">
  <img src="docs/img/git.png" width="620" alt="O painel Git: branch, caixa de commit, alterações, pull requests e histórico" />
  <br />
  <sub>O painel Git. Pull requests são lidas, revisadas e mergeadas sem sair do app.</sub>
</div>

---

## Como isso funciona de verdade

Essa é a parte em que ninguém acredita, então aqui vai o mecanismo honesto:

| Peça | Como | Ressalva |
|---|---|---|
| **Node** | JavaScriptCore + uma camada Node escrita na mão: `fs`, `path`, `events`, `buffer`, `stream`, `timers`, `fetch`, `http`, `require` | Não é V8. Sem addons nativos. |
| **npm** | Registro real, resolução de semver real, `package-lock.json` v3 real, tarballs reais, `.bin` real | Pacotes com binários nativos caem no `esm.sh` |
| **Bundler** | `esbuild-wasm` rodando dentro do JavaScriptCore | Transformação e dev server; `build` só para Vite |
| **Servidor HTTP** | Network.framework, atado a `127.0.0.1` | Local ao dispositivo, de propósito |
| **git** | libgit2 1.9.7 como XCFramework, SecureTransport, sem SSH | HTTPS + token |
| **Preview de Swift** | Um interpretador para um subconjunto de SwiftUI, renderizado como SwiftUI de verdade | Sem compilador — veja [Swift no iPad](#swift-no-ipad) |

Dev servers que funcionam hoje: **Vite** (`dev`, `build`, `preview`), **Astro** (`dev`), **Next** (`dev`),
**Nest** (via `node`).

---

## Swift no iPad

Não existe compilador Swift no iOS, e a Odete não finge que existe.

O que ela faz no lugar: o Preview **interpreta** um subconjunto útil de SwiftUI e renderiza como
SwiftUI genuíno — stacks, `List`/`Form`/`Section`, `ScrollView`, `NavigationStack`/`Link`, `Text`,
`Button`, `Toggle`, `TextField`, `Slider`, `Stepper`, `Image(systemName:)`, `Label`, `ForEach`,
`if`/`else`, `@State`/`@Binding`, funções, interpolação de string e os modificadores comuns.
O estado sobrevive a um save; "reset" começa de novo. Qualquer coisa fora do subconjunto vira um
placeholder tracejado mais um aviso em Problemas, com o número da linha.

Para código que precisa mesmo compilar, o template **Swift Playground** produz um pacote `.swiftpm`
e um botão entrega ele para o Swift Playgrounds.

---

## Falando cinco idiomas

<div align="center">
  <img src="docs/img/idiomas.png" width="820" alt="O seletor de idioma: idioma do dispositivo, Português, English, Deutsch, Français, Español" />
</div>

O app inteiro — telas, saída do terminal, mensagens do git, avisos de lint, e o idioma em que o
agente responde — é traduzido para **🇧🇷 Português · 🇺🇸 English · 🇩🇪 Deutsch · 🇫🇷 Français · 🇪🇸 Español**.

Por padrão a Odete segue o iPad. Mude em **Ajustes → Idioma** e a interface troca na hora, sem
reabrir o app. Datas, tamanhos de arquivo, tempos relativos e o reconhecedor de fala seguem a mesma escolha.

826 strings vivem num único String Catalog. `make i18n` compara ele com o código-fonte e falha se
alguma frase foi adicionada sem traduções — é assim que continua desse jeito.

---

## Começando

### Requisitos

- Xcode 26.6 ou mais novo, com o runtime do simulador iOS 26.5
- `brew install xcodegen swiftformat swiftlint`

### Compilar e rodar

```bash
git clone https://github.com/OkamiOps/odete-ide.git
cd odete-ide
make run
```

`make run` gera o projeto do Xcode, compila, instala no simulador do iPad Air 11 polegadas (M4)
e abre. Para outro dispositivo:

```bash
make run SIM="iPhone 17"
```

### Todos os comandos

| Comando | O que faz |
|---|---|
| `make gen` | Gera `Odete.xcodeproj` a partir de `project.yml` |
| `make build` | Compila para o simulador |
| `make run` | Compila, instala e abre |
| `make unit` | Testes unitários dos 15 pacotes (223 testes) |
| `make test` | Testes de UI (XCUITest) |
| `make lint` | `swiftformat --lint` + `swiftlint` |
| `make format` | `swiftformat` |
| `make i18n` | Confere o catálogo de traduções contra o código-fonte |
| `make check` | Tudo o que o CI roda, de uma vez |

---

## Arquitetura

Quinze pacotes SwiftPM locais, ligados pelo XcodeGen. Nada é baixado da rede na hora de compilar,
exceto o XCFramework do libgit2 com versão fixada, que está vendorizado.

| Pacote | Responsabilidade |
|---|---|
| `OdeteI18n` | O String Catalog, o idioma escolhido, `tr()` e formatação ciente de locale |
| `OdeteCore` | Modelos puros, temas, regras de ignore, detecção de linguagem, lint, estado persistido |
| `OdeteFiles` | Projetos em `Documents/Projects`, árvore de arquivos, operações, watcher, busca, templates |
| `OdeteEditor` | `CodeEditorView` (Runestone + tree-sitter), tema do editor, barra de teclado |
| `OdeteGit` | libgit2: ator `Repository`, diff/hunks, branches, merge, stash, remotes HTTPS |
| `OdeteAccounts` | Keychain, contas por host, device flow do GitHub e API REST |
| `OdeteRuntime` | JavaScriptCore com a camada Node, HTTP real em `127.0.0.1` |
| `OdeteNpm` | Registro, semver, `package-lock` v3, tarballs, `.bin`, fallback para `esm.sh` |
| `OdeteBundler` | esbuild-wasm dentro do JSC: transformação TS/ESM, build, dev server com reload |
| `OdeteShell` | Parser (`\|` `>` `>>` `<` `&&` `\|\|` `;` `&` `$VAR`), builtins, git, npm, node, jobs |
| `OdetePreview` | O WKWebView do Preview, o esquema `odete://static/` e a ponte do console |
| `OdeteAgent` | Provedores, streaming, o laço de ferramentas, patches, checkpoints, conversas, skills |
| `OdeteSwift` | Parser e interpretador do subconjunto de SwiftUI, renderização nativa, empacotamento `.swiftpm` |
| `OdeteUI` | Design system: `Theme`, `Rail`, `PaneHeader`, `EditorTabs`, `Splitter`, `FileGlyph` |
| `OdeteApp` | As telas: hub, workspace, painéis, sheets, ajustes |

As dependências correm num sentido só: `OdeteApp → {OdeteUI, OdeteGit, OdeteAccounts, OdeteShell, OdetePreview, OdeteAgent, OdeteSwift}`,
`OdeteShell → {OdeteGit, OdeteNpm, OdeteRuntime, OdeteBundler}`, `OdeteBundler → OdeteRuntime`,
todo mundo em cima de `OdeteCore` e `OdeteI18n`.

Especificações de design e planos de implementação das seis fases estão em
[`docs/superpowers/`](docs/superpowers/).

---

## Onde ficam seus dados

| O quê | Onde |
|---|---|
| Projetos | `Documents/Projects/<nome>/` — visível no app Arquivos |
| Metadados do projeto | `<projeto>/.odete/project.json` |
| Conversas, patches, checkpoints, planos | `<projeto>/.odete/` (excluído do git) |
| Layout e preferências | `Application Support/Odete/state.json` |
| Tokens e chaves | Keychain — nunca um arquivo, nunca um backup |

`.odete/` é adicionado ao `.git/info/exclude`, então o histórico do agente nunca cai nos seus commits.

Os projetos podem ficar no iCloud Drive (**Ajustes → Sistema**), que é a diferença entre
"desinstalar perde tudo" e "desinstalar não perde nada".

---

## O hub

<div align="center">
  <img src="docs/img/hub.png" width="900" alt="O hub de projetos: cards com badges de stack e a hora da última abertura" />
</div>

Os projetos mostram a stack detectada, a primeira linha do README deles, e quando você os abriu pela
última vez. **Abrir pasta** adota uma pasta de qualquer lugar via security bookmark (marcada como *externa*),
**Clonar** puxa de uma URL, **Novo projeto** oferece: vazio, Vite + React, Astro, HTML puro,
view SwiftUI, ou um pacote Swift Playground.

Os atalhos também estão ligados: *Abrir projeto*, *Rodar comando*, *Perguntar à Odete*, *Novo projeto*.

---

## Buracos conhecidos

Ditos sem rodeio, porque um README que só lista vitórias é um folheto:

- `astro build` e `next build` ainda não rodam — Astro e Next só em modo dev
- Sem SourceKit, então sem autocomplete de Swift; `GeometryReader` e `Canvas` não estão no subconjunto do preview
- O completion não navega com as setas — Tab/Enter pega o primeiro item, ou toque
- Dois agentes em paralelo, MCP e voz não foram feitos
- iCloud Drive precisa do app assinado com o container `iCloud.com.okamiops.odete`
- O device flow do GitHub precisa do `OdeteGitHubClientId` preenchido; até lá, um token pessoal
- Entrar com uma **assinatura** do Claude ou do Codex usa os clientes OAuth desses CLIs, que
  a Anthropic e a OpenAI restringem aos apps deles. Essa decisão é sua, não nossa.

---

## Contribuindo

`make check` é o portão: format, lint, catálogo de traduções, build, 223 testes. O CI roda a mesma
coisa a cada push.

Duas regras que não são óbvias:

1. **Toda string nova que o usuário vê passa por `tr("…")`**, escrita em português — o português
   *é* a chave. Aí adicione as quatro traduções em
   `Packages/OdeteI18n/Sources/OdeteI18n/Resources/Localizable.xcstrings`. O `make i18n` te avisa
   se você esqueceu.
2. **Nunca traduza uma string que é comparada em algum lugar.** Se algum código faz `text == "x"`,
   `"x"` é uma sentinela, não um rótulo.

---

## Créditos

| | |
|---|---|
| [IBM Plex](https://github.com/IBM/plex) | Sans e Mono — OFL |
| [Runestone](https://github.com/simonbs/Runestone) + [tree-sitter](https://tree-sitter.github.io) | Editor e destaque — MIT |
| [libgit2](https://libgit2.org) | Git — GPL2 com exceção de linking |
| [esbuild](https://esbuild.github.io) | Bundling e transformação — MIT |

Odete tem nome de ratinha. Ela está no ícone, e no canto do painel do Git.
