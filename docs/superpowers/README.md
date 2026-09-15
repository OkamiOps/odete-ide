# Design docs and implementation plans

Six phases, written before the code and kept as they were written:

| Phase | Spec | Plan |
|---|---|---|
| 1 · Foundation | [design](specs/2026-09-14-odete-ios-fase1-fundacao-design.md) | [plan](plans/2026-09-14-odete-ios-fase1-fundacao.md) |
| 2 · Git | [design](specs/2026-09-14-odete-ios-fase2-git-design.md) | [plan](plans/2026-09-14-odete-ios-fase2-git.md) |
| 3 · Runtime, terminal, preview | [design](specs/2026-09-14-odete-ios-fase3-runtime-design.md) | [plan](plans/2026-09-14-odete-ios-fase3-runtime.md) |
| 4 · Agent | [design](specs/2026-09-14-odete-ios-fase4-agente-design.md) | [plan](plans/2026-09-14-odete-ios-fase4-agente.md) |
| 5 · Swift | [design](specs/2026-09-14-odete-ios-fase5-swift-design.md) | [plan](plans/2026-09-14-odete-ios-fase5-swift.md) |
| 6 · Polish and extras | [design](specs/2026-09-14-odete-ios-fase6-extras-design.md) | [plan](plans/2026-09-14-odete-ios-fase6-extras.md) |

They are in Portuguese, and they are a record rather than current documentation: the app has
moved since, and these have not been edited to match. Two differences worth knowing before you
follow a path in them:

- They were written when the app lived under `ios/`. It is now the repository root, so read
  `ios/Packages/…` as `Packages/…`.
- They predate the translation work. Any user-facing string they show in Portuguese now goes
  through `tr("…")` — see **Contributing** in the [README](../../README.md).

For what the app does today, the README is the current document.
