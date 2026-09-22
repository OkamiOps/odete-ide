# App Review — Guideline 2.1, Information Needed

A Apple parou a fila da primeira submissão com a carta padrão de conta sem
histórico: *"This app has been submitted by a developer account that has a
limited App Review history."* Não é acusação de bug nem de diretriz violada —
são seis perguntas.

O texto abaixo é a resposta, em inglês, para colar **nos dois lugares** que eles
pedem: na mensagem do App Review e no campo **Notes** da seção *App Review
Information*. Colar só num não basta; a carta pede os dois, "for reference on
future submissions".

O item 1 é o vídeo, que vai anexado à mensagem.

---

## 1. Screen recording

Attached. Recorded on a physical iPad running iPadOS 27, from a TestFlight
build. The recording shows the typical user flow end to end:

| Time | What happens |
|---|---|
| 0:00 | Project list, then **New project** |
| 0:04 | Naming the project, picking the Blank template, creating it |
| 0:08 | The project opens: file tree, code editor, live preview of the running page, terminal, and the agent panel |
| 0:24 | Asking the on-device AI agent, in plain English, to change the button colour |
| 0:28 | The agent reads the file and proposes an edit |
| 0:36 | The proposed change is shown as a diff, with Accept / Reject — nothing is written without approval |
| 0:40 | After Accept, the file is saved and the live preview updates |
| 0:44 | Tapping the button in the preview: the page the user just built is running on the device |

**No account is created, and none is required for the flow in the recording.**
See item 3.

## 2. Purpose and target audience

Odete IDE is a development environment that runs entirely on the iPad: the
editor, the git repository, the terminal, the package manager and the web
server all run on the device. It is not a remote session and not a browser tab
pointed at another machine.

**The problem it solves.** Writing and running code on an iPad today means
either renting a server, tethering to a Mac, or accepting a browser-based editor
that stops working without a connection. Odete removes that dependency: the
whole toolchain is local, so it works on a plane, on the subway, and anywhere
there is no signal.

**Target audience.** Developers and students who work in JavaScript,
TypeScript, HTML, CSS and Swift and want the iPad to be the machine they work
on, rather than a screen for a machine somewhere else.

## 3. Setting up and accessing the main features — no credentials needed

**No login is required to review the app, and the app does not offer account
registration.** Odete does not have user accounts, a backend, or a server of its
own. There is nothing to register for and therefore no account-deletion flow to
show; the account-deletion requirement does not apply.

To review the main features, no setup at all is needed:

1. Open the app and tap **New project**, choose the **Blank** template, create it.
2. The editor, file tree, terminal and live preview open on the project. Edit
   `src/style.css` or `src/main.js` and the preview updates.
3. Open the **Terminal** tab and type `help` for the built-in commands.
4. Open the **Git** tab: every project is a real git repository — stage, commit,
   branch and diff all work locally, with no remote.
5. Open the **AI** panel. On a device with Apple Intelligence, the
   **Apple Intelligence — on device** agent is available immediately, with no
   account and no network. This is what the attached recording uses.

Optional connections, none of which are needed to exercise the app:

- **AI providers.** The user may connect their *own existing* account with
  Anthropic, OpenAI or xAI, or enter their own API key for any
  OpenAI-compatible endpoint. The app signs in to accounts the user already has;
  it never creates one. Credentials are stored in the device Keychain and are
  sent only to the provider the user chose.
- **Git hosting.** The user may connect their *own existing* GitHub account via
  GitHub's official device-authorisation flow, to clone and push their own
  repositories. Again: connecting an existing account, never creating one.
  GitLab and any git host reachable over HTTPS also work with a token.

## 4. External services, tools and platforms

The app has **no backend of its own** and collects no data. It reaches the
network only for things the user explicitly asks for. Complete list:

**AI services** — contacted only after the user connects their own account or key:

| Service | Hosts | When |
|---|---|---|
| Apple Foundation Models (on device) | *none — no network* | Default agent. Runs on the device; no account, no connection |
| Anthropic (Claude) | `api.anthropic.com`, `claude.com`, `platform.claude.com` | Only if the user connects their Anthropic account |
| OpenAI | `api.openai.com`, `auth.openai.com`, `chatgpt.com` | Only if the user connects their OpenAI account |
| xAI (Grok) | `auth.x.ai`, `cli-chat-proxy.grok.com` | Only if the user connects their xAI account |
| Any OpenAI-compatible endpoint | whatever base URL the user types | Only if the user enters their own key |

**Developer infrastructure** — contacted only when the user runs the
corresponding action inside their own project:

| Service | Hosts | When |
|---|---|---|
| GitHub | `github.com`, `api.github.com` | Cloning, fetching, pushing the user's own repositories |
| Any git host over HTTPS | user-supplied, e.g. `gitlab.com` | Same |
| npm registry | `registry.npmjs.org` | Installing packages the user asked for |
| esm.sh | `esm.sh` | Resolving ES module imports in the user's project |

There are no analytics, no advertising SDKs, no crash reporters, no payment
processors and no data providers. The privacy nutrition label is
"Data Not Collected" across the board, and that is accurate.

## 5. Regional differences

None. The app behaves identically in every region. The interface is localised
into Portuguese (Brazil), English, German, French and Spanish, and follows the
device language; the feature set is the same in all of them. There is no
region-gated content, no region-gated pricing and no region-specific service.

## 6. Regulated industry / third-party material

The app does not operate in a regulated industry — no health, finance,
gambling, or similar. It does not include third-party content requiring
licensing. The open-source components it embeds (libgit2, tree-sitter, esbuild,
QuickJS and similar developer libraries) are used under their own permissive
licences, which are listed in the app under **Settings → About → Licences**.

---

## Antes de reenviar

- [ ] Trocar a build da submissão: a que está anexada é a **1.0 (8)**, de antes
      de metade das correções da semana.
- [ ] Colar o texto acima na mensagem do App Review **e** no campo Notes de
      *App Review Information*.
- [ ] Anexar o vídeo na mensagem.

---

# App Review — Guideline 5.2.5, marca da Apple no subtítulo

Segunda rodada, 21/09/2026, revisada num iPad Air 11" (M3) sobre a build
1.0 (32). Um ponto só, e nada de código:

> The app's metadata includes content that is similar to designs or terms
> used for Apple products and services and may cause confusion for users.
> Specifically, your metadata includes:
> - Terms for iPad in the app subtitle in an inappropriate manner.

A regra vale para nome e subtítulo. Uso referencial na descrição continua
permitido — e de fato a descrição, que cita o aparelho o tempo todo, passou
sem ressalva nas duas rodadas. Os subtítulos novos estão em cada arquivo de
idioma desta pasta. `playground` saiu das keywords em inglês por encostar em
Swift Playgrounds pelo mesmo caminho, embora não tenha sido apontado.

Resposta enviada na thread, 22/09/2026:

> Thank you for the review. We have removed the term iPad from the app
> subtitle in all five localizations. The subtitle now reads: "Real
> development, on device" (English), "Dev de verdade, no aparelho"
> (Portuguese), "Dev de verdad, en tu equipo" (Spanish), "Coder vraiment,
> sur l'appareil" (French), "Echt entwickeln, auf dem Gerät" (German). We
> also removed the keyword "playground" for the same reason. No binary
> change was needed, so this is the same build, 1.0 (32).
