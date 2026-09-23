<div align="center">

<img src="docs/img/icone.png" width="104" alt="Odete" />

# Odete

**A real IDE that runs entirely on an iPad.**
Editor, git, terminal, npm, live preview and a coding agent — no Mac, no server, no remote runner.

[![Platform](https://img.shields.io/badge/iPadOS%20%C2%B7%20iOS-26%2B-000000?style=flat-square&logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](#architecture)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-native-0A84FF?style=flat-square)](#architecture)
[![On-device](https://img.shields.io/badge/runs-100%25%20on--device-34C759?style=flat-square)](#how-it-actually-runs)
[![Languages](https://img.shields.io/badge/languages-5-FF6B2C?style=flat-square)](#speaking-five-languages)
[![Tests](https://img.shields.io/badge/tests-1130-8E8E93?style=flat-square)](#contributing)
[![Version](https://img.shields.io/badge/version-1.5-FF6B2C?style=flat-square)](CHANGELOG.md)

**English** · [Português](README.pt-BR.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md)

</div>

---

> **TL;DR** — Odete is a native SwiftUI IDE for iPadOS 26. It has a real git repository per
> project (libgit2), a shell that actually runs `npm install` and `npm run dev`, a Node-compatible
> runtime on JavaScriptCore, esbuild compiled to WebAssembly, and an AI agent that reads your
> files, runs commands and proposes patches you accept hunk by hunk. Nothing is compiled in the
> cloud. Nothing is uploaded. Close the lid — there is no lid.

> **New in 1.5** — no output cap on cloud models and parameters discovered per model (new
> releases just work), conversation compaction at 80% of the context window, local history for
> every file, a git that no longer reports a rejected push as "ok", Tailwind CSS v4 the official
> way, `npm run dev` that installs what's missing, and Next.js and Astro end to end.
> [Full changelog →](CHANGELOG.md)

<div align="center">
  <img src="docs/img/preview.png" width="900" alt="A Vite project running in Odete: source on the left, dev server in the terminal, live page in Preview" />
  <br />
  <sub>A React + Vite project: source, dev server and the live page — all on the iPad.</sub>
</div>

---

## Why this exists

An iPad is a fast computer with a terrible development story. The usual answers are a remote
VM, a web IDE, or a Mac in the next room. All three mean: no plane, no subway, no signal, no work.

Odete takes the other road. Everything that has to run, runs here.

<table>
<tr>
<td width="50%" valign="top">

<h3>✅ What it does</h3>

- Edits code with tree-sitter highlighting and real autocomplete
- Clones, commits, branches, merges, pushes — actual git
- Runs `npm install` against the real registry
- Runs `npm run dev` and serves your app on `127.0.0.1`
- Renders the running app in a Preview pane with hot reload
- Runs an AI agent with tools, patches, checkpoints and automatic compaction
- Keeps a local history of every file, so no version is ever lost
- Runs Tailwind CSS v4, Next.js and Astro projects as they come
- Speaks 5 languages, from the screens to the terminal output

</td>
<td width="50%" valign="top">

<h3>❌ What it doesn't</h3>

- No Swift compiler (Apple doesn't ship one for iOS)
- No SSH for git — `git@host:` remotes go over HTTPS with the host's account
- No native binaries (`esbuild`, `swc`, `lightningcss`) —
  Odete substitutes its own equivalents
- No `astro build` / `next build` yet — dev mode only
- No submodules, cherry-pick or interactive rebase
- No account required, and no telemetry either

</td>
</tr>
</table>

---

## The five panes

<table>
<tr>
<td width="50%" valign="top">

<h3>📝 Editor</h3>

Runestone with tree-sitter. Git gutter marks (green, blue, red — tap one to open the hunk
with **Discard**), the file's symbols one `@` away in the command palette, light per-language lint plus real syntax errors
from esbuild, and completion from file words, project paths and snippets.

Tabs, split view, diff view, image/PDF/SQLite viewers. Unsaved buffers survive a restart. If a
file changes on disk while its tab has unsaved edits, the editor shows a conflict bar (keep mine,
reload, view diff) instead of overwriting either side. CRLF files stay CRLF, Tab/⇧Tab indent a
selection, and `.editorconfig` is honoured.

**Local history**: before any write — your save, the agent, git, the terminal, Replace all, a
delete — the previous version is kept on the device (outside the project and iCloud). Touch and
hold a tab or a file to browse, diff and restore; deleted files can be brought back too.

</td>
<td width="50%" valign="top">

<h3>🌿 Git</h3>

libgit2, not a wrapper. Status, stage by file or by hunk, commit, branch, merge with conflict
resolution, stash, remotes over HTTPS, blame and per-file history.

GitHub pull requests live in the pane: open one, read the Markdown, check CI, comment, merge.
✨ writes the commit message from the staged diff.

It doesn't lie and doesn't lose work: a push the server rejects is reported as rejected, **Commit**
and **Commit & push** are separate, discarding asks first and sends files to the project trash
with Undo, and aborting a merge touches only the merge's files.

</td>
</tr>
<tr>
<td valign="top">

<h3>⌨️ Terminal</h3>

Odete's own shell — pipes, redirects, `&&`, `||`, `;`, `&`, `$VAR`, job control, history and Tab
completion. `npm`, `node`, `git`, `npx`, plus the usual `ls`/`cat`/`grep`/`find`.

Anything that opens a port becomes a job (`jobs`, `kill %1`) and the Preview follows the last one.
The shell is confined to the project folder — `rm -rf ../other` is refused, not executed.

</td>
<td valign="top">

<h3>▶️ Preview</h3>

A WKWebView pointed at your dev server, reloading every time you save. iPhone/iPad/desktop
viewports, the page's own console, and one tap to open it in Safari.

With no server running, `index.html` is served straight off disk through `odete://static/`.

</td>
</tr>
<tr>
<td colspan="2" valign="top">

<h3>✨ Agent</h3>

Bring your own account — Claude (subscription OAuth), Codex and Grok (device code), or any
OpenAI-/Anthropic-compatible endpoint by key and base URL. Tokens live in the Keychain, never
in a file.

Eight tools run against the real project: read, write, replace, list, grep, read the terminal,
run a shell command, and talk to the GitHub API. Three modes — **Chat** reads, **Plan** writes
only `.odete/plan.md`, **Build** edits. Three permission levels — **Ask**, **Auto**, **Full** —
and anything that writes to someone else's repository asks every time, even on Full.

Every edit arrives as a patch you accept, reject, or accept hunk by hunk. A checkpoint is
written before each turn, so "undo last turn" is one tap.

Cloud models get no artificial output cap: context window, output limit, reasoning and effort
levels are discovered per model (provider APIs plus the public models.dev catalog), so a model
released yesterday works today. When a conversation passes **80% of the model's context window**
it is compacted the way opencode does it — old tool outputs are pruned first, then the beginning
is summarised and the turn carries on. `/compact` does it on demand.

</td>
</tr>
</table>

<div align="center">
  <img src="docs/img/git.png" width="620" alt="The Git pane: branch, commit box, changes, pull requests and history" />
  <br />
  <sub>The Git pane. Pull requests are read, reviewed and merged without leaving the app.</sub>
</div>

---

## How it actually runs

This is the part people don't believe, so here is the honest mechanism:

| Piece | How | Caveat |
|---|---|---|
| **Node** | JavaScriptCore + a hand-written Node layer: `fs`, `path`, `events`, `buffer`, `stream`, `timers`, `crypto`, `fetch`, `http`, `require`/`import()` | Not V8 (a stack-trace shim keeps express & co. happy). No native addons, no Web Streams yet. |
| **npm** | Real registry, real semver resolution, `package.json` and `package-lock.json` byte-identical to npm's, `npm:` aliases, peers, GitHub/tarball/`file:`/workspaces | Native binaries and install scripts are skipped |
| **Bundler** | `esbuild-wasm` running inside JavaScriptCore, browser-condition resolution, `@/` aliases, CSS Modules, Sass/Less | Transform and dev server; `build` for Vite only |
| **Tailwind** | The `tailwindcss` v4 compiler running in the same engine, with a JS class scanner instead of oxide | No lightningcss prefixing |
| **HTTP server** | Network.framework, bound to `127.0.0.1` | Local to the device, by design |
| **git** | libgit2 1.9.7 as an XCFramework, SecureTransport, no SSH | HTTPS + token |
| **Swift preview** | An interpreter for a subset of SwiftUI, rendered as real SwiftUI | No compiler — see [Swift on the iPad](#swift-on-the-ipad) |

Dev servers that work today: **Vite** (`dev`, `build`, `preview`), **Astro** (`dev`, including
content collections and MDX), **Next** (`dev`, App Router with CSS and Tailwind), **Nest** (via `node`).
`npm run dev` installs missing dependencies first, and the first start after an install takes about
0.2 s because the dev server is warmed up in the background.

---

## Swift on the iPad

There is no Swift compiler on iOS, and Odete does not pretend otherwise.

What it does instead: the Preview **interprets** a useful subset of SwiftUI and renders it as
genuine SwiftUI — stacks, `List`/`Form`/`Section`, `ScrollView`, `NavigationStack`/`Link`, `Text`,
`Button`, `Toggle`, `TextField`, `Slider`, `Stepper`, `Image(systemName:)`, `Label`, `ForEach`,
`if`/`else`, `@State`/`@Binding`, functions, string interpolation and the common modifiers.
State survives a save; "reset" starts it over. Anything outside the subset becomes a dashed
placeholder plus a warning in Problems, with the line number.

For code that must actually compile, the **Swift Playground** template produces a `.swiftpm`
package and a button hands it to Swift Playgrounds.

---

## Speaking five languages

<div align="center">
  <img src="docs/img/idiomas.png" width="820" alt="The language picker: device language, Português, English, Deutsch, Français, Español" />
</div>

The whole app — screens, terminal output, git messages, lint warnings, and the language the
agent answers in — is translated into **🇧🇷 Português · 🇺🇸 English · 🇩🇪 Deutsch · 🇫🇷 Français · 🇪🇸 Español**.

By default Odete follows the iPad. Change it in **Settings → Language** and the interface
switches immediately, without reopening the app. Dates, file sizes, relative times and the
speech recogniser follow the same choice.

1,278 strings live in a single String Catalog. `make i18n` compares it against the source and
fails if a phrase was added without translations — which is how it stays that way.

---

## Getting started

### Requirements

- Xcode 26.6 or newer, with the iOS 26.5 simulator runtime
- `brew install xcodegen swiftformat swiftlint`

### Build and run

```bash
git clone https://github.com/OkamiOps/odete-ide.git
cd odete-ide
make run
```

`make run` generates the Xcode project, builds it, installs it on the iPad Air 11-inch (M4)
simulator and launches it. For another device:

```bash
make run SIM="iPhone 17"
```

### Every command

| Command | What it does |
|---|---|
| `make gen` | Generate `Odete.xcodeproj` from `project.yml` |
| `make build` | Compile for the simulator |
| `make run` | Build, install and launch |
| `make unit` | Unit tests for all 15 packages (1,130 tests) |
| `make test` | UI tests (XCUITest) |
| `make lint` | `swiftformat --lint` + `swiftlint` |
| `make format` | `swiftformat` |
| `make i18n` | Check the translation catalog against the source |
| `make check` | Everything CI runs, in one go |

---

## Architecture

Fifteen local SwiftPM packages, wired by XcodeGen. Nothing is fetched from the network at
build time except the pinned libgit2 XCFramework, which is vendored.

| Package | Responsibility |
|---|---|
| `OdeteI18n` | The String Catalog, the chosen language, `tr()` and locale-aware formatting |
| `OdeteCore` | Pure models, themes, ignore rules, language detection, lint, persisted state |
| `OdeteFiles` | Projects in `Documents/Projects`, file tree, operations, watcher, search, templates |
| `OdeteEditor` | `CodeEditorView` (Runestone + tree-sitter), editor theme, keyboard bar |
| `OdeteGit` | libgit2: `Repository` actor, diff/hunks, branches, merge, stash, HTTPS remotes |
| `OdeteAccounts` | Keychain, per-host accounts, GitHub device flow and REST API |
| `OdeteRuntime` | JavaScriptCore with the Node layer, real HTTP on `127.0.0.1` |
| `OdeteNpm` | Registry, semver, `package-lock` v3 identical to npm's, tarballs, `.bin`, aliases, workspaces |
| `OdeteBundler` | esbuild-wasm inside JSC: TS/ESM transform, build, dev server with reload |
| `OdeteShell` | Parser (`\|` `>` `>>` `<` `&&` `\|\|` `;` `&` `$VAR`), builtins, git, npm, node, jobs |
| `OdetePreview` | The Preview WKWebView, the `odete://static/` scheme and the console bridge |
| `OdeteAgent` | Providers, streaming, the tool loop, patches, checkpoints, conversations, skills |
| `OdeteSwift` | SwiftUI subset parser and interpreter, native rendering, `.swiftpm` packaging |
| `OdeteUI` | Design system: `Theme`, `Rail`, `PaneHeader`, `EditorTabs`, `Splitter`, `FileGlyph` |
| `OdeteApp` | The screens: hub, workspace, panes, sheets, settings |

Dependencies flow one way: `OdeteApp → {OdeteUI, OdeteGit, OdeteAccounts, OdeteShell, OdetePreview, OdeteAgent, OdeteSwift}`,
`OdeteShell → {OdeteGit, OdeteNpm, OdeteRuntime, OdeteBundler}`, `OdeteBundler → OdeteRuntime`,
everything on top of `OdeteCore` and `OdeteI18n`.

Design specs and implementation plans for all six phases live in
[`docs/superpowers/`](docs/superpowers/).

---

## Where your data lives

| What | Where |
|---|---|
| Projects | `Documents/Projects/<name>/` — visible in the Files app |
| Project metadata | `<project>/.odete/project.json` |
| Conversations, patches, checkpoints, plans | `<project>/.odete/` (excluded from git) |
| Layout and preferences | `Application Support/Odete/state.json` |
| Local file history | `Application Support/Odete/Historico/` — on the device only, never synced |
| Tokens and keys | Keychain — never a file, never a backup |

`.odete/` is added to `.git/info/exclude`, so the agent's history never lands in your commits.

Projects can live in iCloud Drive instead (**Settings → System**), which is the difference
between "uninstalling loses everything" and "uninstalling loses nothing".

---

## The hub

<div align="center">
  <img src="docs/img/hub.png" width="900" alt="The project hub: cards with stack badges and last-opened time" />
</div>

Projects show their detected stack, the first line of their README, and when you last opened
them. **Open folder** adopts a folder from anywhere via a security bookmark (marked *external*),
**Clone** pulls from a URL, **New project** offers: blank, Vite + React, Astro, plain HTML,
SwiftUI view, or a Swift Playground package.

Shortcuts are wired up too: *Open project*, *Run command*, *Ask Odete*, *New project*.

---

## Known gaps

Stated plainly, because a README that only lists wins is a brochure:

- `astro build` and `next build` don't run yet — Astro and Next are dev-mode only
- Astro islands with `client:*` hydration and custom collection loaders don't run yet
- Next runs the App Router (dynamic segments, catch-alls, route groups, route handlers,
  `metadata`, `not-found`, `error`) and the Pages Router, hydrates `'use client'` components,
  and runs middleware, `next/font` and Server Actions. What's missing: `useActionState` shows
  its initial state until the island hydrates (`renderToString` can't receive the postback),
  file uploads in a form action, `'use server'` written inside a component instead of at the
  top of a file, parallel routes (`@slot`), and client-side navigation — a link is a full reload
- No SourceKit, so no Swift autocomplete; `GeometryReader` and `Canvas` aren't in the preview subset
- Completion doesn't navigate with arrow keys — Tab/Enter takes the first item, or tap
- Two agents in parallel, MCP and voice are not built
- A pure `for(;;){}` that never calls into the app can't be interrupted by Ctrl+C
- iCloud Drive needs the app signed with the `iCloud.com.okamiops.odete` container
- GitHub device flow needs `OdeteGitHubClientId` filled in; until then, a personal token
- Signing in with a Claude or Codex **subscription** uses those CLIs' OAuth clients, which
  Anthropic and OpenAI restrict to their own apps. That is your call to make, not ours.

---

## Contributing

`make check` is the gate: format, lint, translation catalog, build, 1,130 tests. CI runs the same
thing on every push.

Two rules that aren't obvious:

1. **Any new user-facing string goes through `tr("…")`**, written in Portuguese — the Portuguese
   *is* the key. Then add the four translations to
   `Packages/OdeteI18n/Sources/OdeteI18n/Resources/Localizable.xcstrings`. `make i18n` will
   tell you if you forgot.
2. **Never translate a string that's compared anywhere.** If some code does `text == "x"`,
   `"x"` is a sentinel, not a label.

---

## Credits

| | |
|---|---|
| [IBM Plex](https://github.com/IBM/plex) | Sans and Mono — OFL |
| [Runestone](https://github.com/simonbs/Runestone) + [tree-sitter](https://tree-sitter.github.io) | Editor and highlighting — MIT |
| [libgit2](https://libgit2.org) | Git — GPL2 with linking exception |
| [esbuild](https://esbuild.github.io) | Bundling and transform — MIT |

Odete is named after a mouse. She is in the icon, and in the corner of the Git pane.
