# Changelog

**English** · [Português](CHANGELOG.pt-BR.md)

All notable changes to Odete. Versions follow the App Store marketing version; the number in
parentheses is the build.

## [1.5] (33) — 2026-09-23

The biggest release since 1.0: silent data loss, a git that lied, a stuck agent loop and a
half-working web stack, all fixed — plus local history and conversation compaction.

### AI providers
- **No output cap on cloud models.** Only the on-device model (Apple Intelligence) keeps a
  limit. OpenAI, Codex, Grok and compatible endpoints get no `max_tokens` at all; Anthropic gets
  the model's own maximum.
- **Future-proof parameters.** Context window, output limit, thinking type and effort levels are
  discovered per model from the provider's API and the public [models.dev](https://models.dev)
  catalog (cached for a day), not guessed from the model name. Unknown models use the newest
  request format, so new releases (Claude Opus 5.5, GPT 6 Sol/Luna, …) work on day one.
- Claude requests use adaptive thinking and `output_config.effort`; the `budget_tokens` /
  `temperature` combination that returned 400 on Claude Sonnet 5 is gone. Signed thinking blocks
  and OpenAI encrypted reasoning are passed back between rounds.
- A truncated reply or tool call becomes a clear error the model can act on — never a silent
  "invalid JSON". Refusals and paused turns are handled.
- Retries with backoff on 429/529/5xx and dropped connections, honouring `Retry-After`.
- A network error while refreshing a subscription token no longer disconnects the account.

### Agent
- **Conversation compaction at 80% of the context window**, modelled on opencode: old tool
  outputs are pruned first, then the beginning is summarised and the turn continues. Context
  usage is shown in the composer; `/compact` compacts on demand. The fixed 24-message window is gone.
- The repetition brake no longer blocks edit → test cycles and never stops `run_shell`.
- Giving up no longer leaves an orphan tool call that broke every following message; tool
  call/result pairs are repaired before each request.
- Shell commands are classified with the real shell parser (`>`, `&&`, `git branch -D`,
  `find -delete` count as writes). Tool paths are confined to the project, symlinks resolved.
- **Stop** actually stops the running tool. `run_shell` output survives a long scrollback.
- Patches: no 12-patch cap, accept/reject check the disk and show a conflict instead of
  overwriting, non-UTF-8 files are never emptied. Accept/Reject all reload only the affected tabs.
- Undoing a turn tells the model what was reverted. Conversations are saved every round.
- The system prompt and tool list stay fixed for the whole conversation (better prompt caching).

### Local history (new)
- Before any write or delete — your save, the agent, rejecting a patch, undoing a turn, git
  discard/checkout/merge, Replace all, reload, restore, the terminal's `rm`/`cp`/`mv`/`>` — the
  previous version is kept in `Application Support/Odete/Historico`, outside the project and
  iCloud, deduplicated, up to 50 versions and 30 days per file (300 MB total by default).
- Touch and hold a tab or a file for **Local History**: content, diff against the current file,
  Restore, Copy. **Deleted Files** brings removed files back. Size and cleanup in Settings.
- Saving through a symbolic link writes the target and keeps the link.

### Git
- A push rejected by the server (protected branch, hook, non-fast-forward) is reported as
  rejected, not "push ok".
- Tapping a remote branch creates a local tracking branch instead of a detached HEAD.
- **Discard** asks first, shows tracked/untracked counts, moves files to the project trash and
  offers Undo. **Abort merge** works like `git merge --abort` and asks first.
- Conflicts without markers (binary, deleted × modified) can be resolved with mine/theirs/delete.
- "Your changes to X would be overwritten" is reported as such, with a stash-and-continue option.
- **Commit** only commits; **Commit & push** pushes. The message is cleared only on success.
- Undoing a commit that is already on the remote asks first; undoing the very first commit
  explains why it can't. Deleting a branch asks first.
- libgit2 errors in plain language, with a button to remove a stale `index.lock`.
- `git@host:` remotes go over HTTPS when an account for the host exists.
- Commits by a GitHub account without a public e-mail use the `users.noreply.github.com` address.
- The Git pane notices a repository created from the terminal.

### Editor
- A tab with unsaved edits whose file changed on disk shows a conflict bar (keep mine, reload,
  view diff) and autosave pauses — nothing is overwritten silently.
- Find/replace requests are one-shot and tied to their document: a new editor no longer replays
  the last replace, and split view no longer replaces in both panes.
- Project **Replace all** uses the same query as search, edits open buffers, and previews counts.
- CRLF files stay CRLF; Tab/⇧Tab indent and outdent selections; indentation and `.editorconfig`
  are honoured; autosave no longer trims the space you just typed.
- Deleting a file with an unsaved tab saves it first; closing a dirty tab with autosave off asks.

### Files and projects
- The trash no longer deletes old files immediately, never falls back to a permanent delete,
  and never collides on names.
- SQLite editing writes to the right table and column; `.sql` files are read-only unless you
  confirm a rewrite.
- An unreadable `state.json` no longer resets everything or turns on iCloud.
- Moving projects to or from iCloud Drive runs off the main thread, asks first, shows progress,
  renames on collision and rolls back on failure; all windows follow.
- Renaming or deleting a project open in another window closes it there first. The Shortcuts
  "Run command" action runs in the right window.
- Zip: ZIP64 support, bounds-checked extraction, `.odete` excluded from shared zips.
- Swift playground: reversed ranges and integer overflow are errors, not crashes.
- A missing external folder shows as unavailable with a way to relocate it.

### Terminal and Node runtime
- The shell and the runtime's `fs` are confined to the project folder (plus the temporary
  folder and the `npx` cache).
- `require` normalises paths and deduplicates by real path (zod 4, yargs 17/18, Tailwind 3,
  readable-stream); `imports` (`#subpath`); `import()` outside esbuild; ES modules exporting
  `"module.exports"`; a V8 stack-trace shim and function-constructor `EventEmitter`/`Stream`
  (express, depd).
- Unhandled rejections exit with code 1; top-level await; `unref`; per-job cancellation for
  `kill %N` and Ctrl+C; stdin piped into `node`; binary stdout; `crypto` hashes, HMAC, PBKDF2.
- Transform cache on disk and POSIX `fs`: listing `node_modules` went from 708 ms to 32 ms
  without JIT.
- Parser: `2>`, `>&2`, `VAR=x cmd`, `cd -`, globbing; `grep`/`find`/`wc`/`echo` take the usual flags.
- A smoke test runs 31 popular packages without JIT with Node's exact output.

### npm
- `npm run dev` (and the Preview button) installs missing dependencies before starting the
  server. The `esm.sh` fallback is gone — mixing it with `node_modules` loaded React twice.
- After `npm install` the dev server is warmed in the background: first start ~6 s → ~0.2 s
  without JIT. Lockfile changes are watched.
- `package.json` and `package-lock.json` come out byte-identical to npm's; `npm:` aliases,
  required peers, tarball/GitHub/`file:`/`workspace:` dependencies, `overrides`; install scripts
  are reported, not mistaken for native code; hoisting and semver fixes; tar links can't escape.
- `npm ci`, `npx -y`, `pre`/`post` scripts, bare `yarn`/`pnpm`, and npm/npx find the nearest
  `package.json`.

### Web build
- Browser-condition resolution for the dev server and `vite build` (axios, uuid no longer blank
  the page); Node built-ins become empty modules with a warning, like Vite.
- `@/` and other aliases from `tsconfig` paths and `vite.config`; CSS Modules; Sass and Less
  through the project's packages; `import.meta.glob`, `?raw`, `?url`, `?inline`, `?worker`.
- **Tailwind CSS v4 the official way** (`@tailwindcss/vite` + `@import "tailwindcss"`) in the
  Preview and `vite build`, with `@theme`, `@source`, `@apply`, `@plugin`; Tailwind 3 too.

### Next.js and Astro
- Next: CSS per route (globals, CSS Modules, Tailwind), mixed sync/async server components,
  providers with children as islands, `display: contents` islands, `next/*` in the browser,
  templates, loading, full metadata and app icons. The `create-next-app` template runs.
- Astro: TypeScript frontmatter, scoped styles with Sass/Tailwind, imported images, dynamic
  routes and `getStaticPaths`, endpoints (`rss.xml`), Markdown/MDX pages, content collections.
  The `create-astro` blog template runs.
- `URL` accepts special-scheme slashes like WHATWG.

### Other
- "fichas" is now "tokens" in Portuguese; 1,278 strings translated into five languages.
- Privacy policy: added models.dev, removed esm.sh.

## 1.0 (32)

First App Store release: native SwiftUI IDE for iPadOS 26 with editor, libgit2, shell, npm,
Node-compatible runtime on JavaScriptCore, esbuild-wasm dev server, Preview, Swift preview
interpreter and a coding agent with patches and checkpoints, in five languages.

[1.5]: https://github.com/OkamiOps/odete-ide/releases/tag/v1.5
