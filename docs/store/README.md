# Odete na App Store

A ficha do app, um arquivo por idioma. O App Store Connect aceita um texto por
localização, e a Odete fala cinco — quem procura "IDE" em alemão precisa achar a
descrição em alemão.

| Idioma | Arquivo | Locale no App Store Connect |
|---|---|---|
| Português (Brasil) | [pt-BR.md](pt-BR.md) | Portuguese (Brazil) — idioma principal do app |
| Inglês | [en.md](en.md) | English (U.S.) |
| Alemão | [de.md](de.md) | German |
| Francês | [fr.md](fr.md) | French |
| Espanhol | [es.md](es.md) | Spanish (Mexico) + Spanish (Spain) |

O app está registrado como **Odete IDE** (`com.okamiops.odete`), com português do
Brasil como idioma principal. Com "IDE" já no nome, o subtítulo não repete a palavra —
esses 30 caracteres rendem mais dizendo o que mais ninguém faz.

## Limites que o App Store Connect impõe

Estourar qualquer um destes trava o salvamento da ficha, por localização:

| Campo | Máximo |
|---|---|
| Nome | 30 caracteres |
| Subtítulo | 30 caracteres |
| Texto promocional | 170 caracteres |
| Descrição | 4000 caracteres |
| Palavras-chave | 100 caracteres, separadas por vírgula, **sem espaço depois da vírgula** |
| Novidades desta versão | 4000 caracteres |

## Categorias

Primária: **Ferramentas para desenvolvedores**. Secundária: **Produtividade**.

## Privacidade

Sem coleta de dados — a ficha de privacidade é "Data Not Collected" em tudo.

`PrivacyInfo.xcprivacy` declara os motivos de API exigidos: UserDefaults, timestamps de
arquivo, espaço em disco e boot time, todos usados por Foundation e SwiftUI. Tokens do
GitHub e das contas de IA ficam no Keychain do aparelho e só saem para os provedores que
a própria pessoa conectou.

## Notas para a revisão

Texto para o campo "Notes" da submissão. A primeira parte é a que importa: a diretriz 2.5.2
é o motivo pelo qual um app assim pode ser rejeitado por quem não entendeu o que ele é.

> Odete is a development environment, in the same category as Swift Playgrounds, Pythonista,
> a-Shell and Textastic.
>
> **On 2.5.2 (executable code).** Odete does not download or execute code that changes the
> app's own features. It is a tool for writing and running *the user's own* code, which the
> user authors and can read and edit in full inside the app — the guideline's exception for
> apps that teach, develop or test code. Everything the user runs is interpreted inside a
> JavaScriptCore instance owned by the app; no native code is downloaded or loaded at any
> point. `npm install` fetches JavaScript packages the user explicitly asks for, into that
> user's own project folder, exactly as a code editor on a desktop would. None of it is ever
> executed as part of Odete itself.
>
> **On the AI agent.** The agent talks directly to the provider the user signed in to —
> Anthropic, OpenAI, xAI, or any OpenAI-compatible endpoint the user configures with their
> own key. Odete runs no servers and proxies nothing; there is no Odete account, and no data
> reaches us at any point. Credentials live in the device Keychain.
>
> **On the local web server.** `npm run dev` binds a server to 127.0.0.1 so the Preview pane
> can load the user's project. It is not reachable from outside the device.
>
> **On the Preview pane.** It is not a browser. Its navigation policy allows only the app's
> own `odete://` scheme and `localhost`/`127.0.0.1`, which is where the user's dev server
> listens. Any other address is refused in the pane; a link the user taps opens in Safari
> instead. That is why the app declares no unrestricted web access.
>
> **Test account.** None needed. Everything except the AI agent works with no sign-in at all;
> for the agent, any OpenAI-compatible API key can be pasted in Settings → AI accounts.

## Capturas

Tamanhos que o App Store Connect exige, por família de aparelho:

| Família | Tamanho (retrato) | Obrigatório |
|---|---|---|
| iPad 13" | 2064 × 2752 | sim, o app suporta iPad |
| iPhone 6.9" | 1290 × 2796 | sim, o app suporta iPhone |

Paisagem é aceita nas mesmas medidas invertidas, e para uma IDE é o que faz sentido.

O que mostrar, na ordem:

1. Workspace: editor, terminal com `npm run dev` e a página no Preview
2. Hub com os projetos
3. Painel Git: diff por hunk, com stage e discard
4. Pull request do GitHub dentro do app
5. Agente aplicando um patch, com o cartão de aprovação
6. Swift Playground com o preview nativo
7. Seletor de idioma — cinco idiomas é diferencial, e se vê numa imagem
8. Retrato: abas embaixo, agente ao lado

As capturas de `../img/` são do iPad Air 11" e servem para o README do GitHub, **não**
para a loja: o App Store Connect recusa medida fora da lista acima.
