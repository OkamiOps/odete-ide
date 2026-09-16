<div align="center">

<img src="docs/img/icone.png" width="104" alt="Odete" />

# Odete

**Eine echte IDE, die komplett auf einem iPad läuft.**
Editor, git, Terminal, npm, Live-Preview und ein Coding-Agent — kein Mac, kein Server, kein Remote-Runner.

[![Plattform](https://img.shields.io/badge/iPadOS%20%C2%B7%20iOS-26%2B-000000?style=flat-square&logo=apple&logoColor=white)](#voraussetzungen)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](#architektur)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-nativ-0A84FF?style=flat-square)](#architektur)
[![On-Device](https://img.shields.io/badge/l%C3%A4uft-100%25%20on--device-34C759?style=flat-square)](#wie-das-wirklich-läuft)
[![Sprachen](https://img.shields.io/badge/Sprachen-5-FF6B2C?style=flat-square)](#fünf-sprachen)
[![Tests](https://img.shields.io/badge/Tests-223-8E8E93?style=flat-square)](#mitmachen)

[English](README.md) · [Português](README.pt-BR.md) · **Deutsch** · [Français](README.fr.md) · [Español](README.es.md)

</div>

---

> **TL;DR** — Odete ist eine native SwiftUI-IDE für iPadOS 26. Sie hat pro Projekt ein echtes
> git-Repository (libgit2), eine Shell, die tatsächlich `npm install` und `npm run dev` ausführt,
> eine Node-kompatible Laufzeit auf JavaScriptCore, esbuild kompiliert nach WebAssembly, und einen
> KI-Agenten, der deine Dateien liest, Befehle ausführt und Patches vorschlägt, die du hunk für
> hunk annimmst. Nichts wird in der Cloud kompiliert. Nichts wird hochgeladen. Zuklappen? Da ist
> nichts zum Zuklappen.

<div align="center">
  <img src="docs/img/preview.png" width="900" alt="Ein Vite-Projekt läuft in Odete: Quellcode links, Dev-Server im Terminal, Live-Seite im Preview" />
  <br />
  <sub>Ein React-+-Vite-Projekt: Quellcode, Dev-Server und die Live-Seite — alles auf dem iPad.</sub>
</div>

---

## Warum es das gibt

Ein iPad ist ein schneller Rechner, auf dem sich miserabel entwickeln lässt. Die üblichen Antworten
sind eine Remote-VM, eine Web-IDE oder ein Mac im Nebenzimmer. Alle drei heißen: kein Flugzeug,
keine U-Bahn, kein Netz, keine Arbeit.

Odete geht den anderen Weg. Alles, was laufen muss, läuft hier.

<table>
<tr>
<td width="50%" valign="top">

<h3>✅ Was sie kann</h3>

- Code bearbeiten, mit tree-sitter-Highlighting und echter Autovervollständigung
- Klonen, committen, branchen, mergen, pushen — echtes git
- `npm install` gegen die echte Registry ausführen
- `npm run dev` ausführen und deine App auf `127.0.0.1` ausliefern
- Die laufende App im Preview-Bereich rendern, mit Hot Reload
- Einen KI-Agenten betreiben, mit Tools, Patches und Checkpoints
- 5 Sprachen sprechen, von den Screens bis zur Terminal-Ausgabe

</td>
<td width="50%" valign="top">

<h3>❌ Was sie nicht kann</h3>

- Kein Swift-Compiler (Apple liefert für iOS keinen)
- Kein SSH für git — nur HTTPS und Tokens
- Keine nativen Binaries (`esbuild`, `swc`, `lightningcss`) —
  Odete setzt eigene Äquivalente ein
- Noch kein `astro build` / `next build` — nur Dev-Modus
- Keine Submodule, kein cherry-pick, kein interaktives rebase
- Kein Account nötig, und Telemetrie auch nicht

</td>
</tr>
</table>

---

## Die fünf Bereiche

<table>
<tr>
<td width="50%" valign="top">

<h3>📝 Editor</h3>

Runestone mit tree-sitter. Git-Markierungen am Rand (grün, blau, rot — tippe eine an, um den hunk
mit **Verwerfen** zu öffnen), die Symbole der Datei ein `@` weit weg in der Befehlspalette, leichtes Lint pro Sprache plus echte
Syntaxfehler von esbuild, und Vervollständigung aus Wörtern der Datei, Projektpfaden und Snippets.

Tabs, Split View, diff-Ansicht, Viewer für Bilder/PDF/SQLite. Ungespeicherte Buffer überleben einen Neustart.

</td>
<td width="50%" valign="top">

<h3>🌿 Git</h3>

libgit2, kein Wrapper. Status, stage pro Datei oder pro hunk, commit, branch, merge mit
Konfliktauflösung, stash, Remotes über HTTPS, blame und Historie pro Datei.

GitHub pull requests leben im Bereich: einen öffnen, das Markdown lesen, CI prüfen, kommentieren, mergen.
✨ schreibt die commit-Message aus dem gestagten diff.

</td>
</tr>
<tr>
<td valign="top">

<h3>⌨️ Terminal</h3>

Odetes eigene Shell — Pipes, Umleitungen, `&&`, `||`, `;`, `&`, `$VAR`, Job-Steuerung, History und
Tab-Vervollständigung. `npm`, `node`, `git`, `npx`, dazu die üblichen `ls`/`cat`/`grep`/`find`.

Alles, was einen Port öffnet, wird ein Job (`jobs`, `kill %1`), und das Preview folgt dem letzten.

</td>
<td valign="top">

<h3>▶️ Preview</h3>

Eine WKWebView, die auf deinen Dev-Server zeigt und bei jedem Speichern neu lädt. Viewports für
iPhone/iPad/Desktop, die Konsole der Seite, und ein Tipp öffnet sie in Safari.

Läuft kein Server, wird `index.html` direkt von der Platte über `odete://static/` ausgeliefert.

</td>
</tr>
<tr>
<td colspan="2" valign="top">

<h3>✨ Agent</h3>

Bring deinen eigenen Account mit — Claude (Abo-OAuth), Codex und Grok (Device Code) oder jeden
OpenAI-/Anthropic-kompatiblen Endpoint per Key und Base-URL. Tokens liegen im Keychain, nie in
einer Datei.

Acht Tools arbeiten am echten Projekt: lesen, schreiben, ersetzen, auflisten, grep, das Terminal
lesen, einen Shell-Befehl ausführen und mit der GitHub-API reden. Drei Modi — **Chat** liest,
**Plan** schreibt nur `.odete/plan.md`, **Build** ändert. Drei Berechtigungsstufen — **Ask**,
**Auto**, **Full** — und alles, was in das Repository von jemand anderem schreibt, fragt jedes Mal
nach, auch bei Full.

Jede Änderung kommt als Patch, den du annimmst, ablehnst oder hunk für hunk annimmst. Vor jedem
Zug wird ein Checkpoint geschrieben, „letzten Zug rückgängig“ ist also ein Tipp.

</td>
</tr>
</table>

<div align="center">
  <img src="docs/img/git.png" width="620" alt="Der Git-Bereich: branch, Commit-Box, Änderungen, pull requests und Historie" />
  <br />
  <sub>Der Git-Bereich. Pull requests werden gelesen, geprüft und gemergt, ohne die App zu verlassen.</sub>
</div>

---

## Wie das wirklich läuft

Das ist der Teil, den die Leute nicht glauben, also hier der ehrliche Mechanismus:

| Teil | Wie | Haken |
|---|---|---|
| **Node** | JavaScriptCore + eine handgeschriebene Node-Schicht: `fs`, `path`, `events`, `buffer`, `stream`, `timers`, `fetch`, `http`, `require` | Nicht V8. Keine nativen Addons. |
| **npm** | Echte Registry, echte semver-Auflösung, echte `package-lock.json` v3, echte Tarballs, echtes `.bin` | Pakete mit nativen Binaries fallen auf `esm.sh` zurück |
| **Bundler** | `esbuild-wasm`, läuft in JavaScriptCore | Transform und Dev-Server; `build` nur für Vite |
| **HTTP-Server** | Network.framework, gebunden an `127.0.0.1` | Lokal auf dem Gerät, so gewollt |
| **git** | libgit2 1.9.7 als XCFramework, SecureTransport, kein SSH | HTTPS + Token |
| **Swift-Preview** | Ein Interpreter für eine Teilmenge von SwiftUI, gerendert als echtes SwiftUI | Kein Compiler — siehe [Swift auf dem iPad](#swift-auf-dem-ipad) |

Dev-Server, die heute funktionieren: **Vite** (`dev`, `build`, `preview`), **Astro** (`dev`), **Next** (`dev`),
**Nest** (über `node`).

---

## Swift auf dem iPad

Auf iOS gibt es keinen Swift-Compiler, und Odete tut auch nicht so.

Was sie stattdessen tut: Das Preview **interpretiert** eine brauchbare Teilmenge von SwiftUI und
rendert sie als echtes SwiftUI — Stacks, `List`/`Form`/`Section`, `ScrollView`,
`NavigationStack`/`Link`, `Text`, `Button`, `Toggle`, `TextField`, `Slider`, `Stepper`,
`Image(systemName:)`, `Label`, `ForEach`, `if`/`else`, `@State`/`@Binding`, Funktionen,
String-Interpolation und die gängigen Modifier. Der State überlebt ein Speichern; „Reset“ fängt von
vorn an. Alles außerhalb der Teilmenge wird zu einem gestrichelten Platzhalter plus einer Warnung
in Probleme, mit Zeilennummer.

Für Code, der wirklich kompilieren muss, erzeugt die Vorlage **Swift Playground** ein
`.swiftpm`-Paket, und ein Button reicht es an Swift Playgrounds weiter.

---

## Fünf Sprachen

<div align="center">
  <img src="docs/img/idiomas.png" width="820" alt="Die Sprachauswahl: Gerätesprache, Português, English, Deutsch, Français, Español" />
</div>

Die ganze App — Screens, Terminal-Ausgabe, git-Meldungen, Lint-Warnungen und die Sprache, in der der
Agent antwortet — ist übersetzt in **🇧🇷 Português · 🇺🇸 English · 🇩🇪 Deutsch · 🇫🇷 Français · 🇪🇸 Español**.

Standardmäßig folgt Odete dem iPad. Ändere es unter **Einstellungen → Sprache**, und die Oberfläche
schaltet sofort um, ohne die App neu zu öffnen. Datumsangaben, Dateigrößen, relative Zeiten und die
Spracherkennung folgen derselben Wahl.

826 Strings liegen in einem einzigen String Catalog. `make i18n` vergleicht ihn mit dem Quellcode und
schlägt fehl, wenn ein Satz ohne Übersetzungen dazugekommen ist — so bleibt es auch dabei.

---

## Loslegen

### Voraussetzungen

- Xcode 26.6 oder neuer, mit der iOS-26.5-Simulator-Runtime
- `brew install xcodegen swiftformat swiftlint`

### Bauen und starten

```bash
git clone https://github.com/OkamiOps/odete-ide.git
cd odete-ide
make run
```

`make run` generiert das Xcode-Projekt, baut es, installiert es auf dem Simulator iPad Air 11 Zoll (M4)
und startet es. Für ein anderes Gerät:

```bash
make run SIM="iPhone 17"
```

### Alle Befehle

| Befehl | Was er tut |
|---|---|
| `make gen` | `Odete.xcodeproj` aus `project.yml` generieren |
| `make build` | Für den Simulator kompilieren |
| `make run` | Bauen, installieren und starten |
| `make unit` | Unit-Tests für alle 15 Pakete (223 Tests) |
| `make test` | UI-Tests (XCUITest) |
| `make lint` | `swiftformat --lint` + `swiftlint` |
| `make format` | `swiftformat` |
| `make i18n` | Den Übersetzungskatalog gegen den Quellcode prüfen |
| `make check` | Alles, was CI ausführt, in einem Rutsch |

---

## Architektur

Fünfzehn lokale SwiftPM-Pakete, von XcodeGen verdrahtet. Zur Build-Zeit wird nichts aus dem Netz
geholt, außer dem gepinnten libgit2-XCFramework, das mitgeliefert wird.

| Paket | Zuständigkeit |
|---|---|
| `OdeteI18n` | Der String Catalog, die gewählte Sprache, `tr()` und locale-bewusste Formatierung |
| `OdeteCore` | Reine Modelle, Themes, Ignore-Regeln, Erkennung der Programmiersprache, Lint, persistierter State |
| `OdeteFiles` | Projekte in `Documents/Projects`, Dateibaum, Operationen, Watcher, Suche, Vorlagen |
| `OdeteEditor` | `CodeEditorView` (Runestone + tree-sitter), Editor-Theme, Tastaturleiste |
| `OdeteGit` | libgit2: `Repository`-Actor, diff/hunks, branches, merge, stash, HTTPS-Remotes |
| `OdeteAccounts` | Keychain, Accounts pro Host, GitHub Device Flow und REST-API |
| `OdeteRuntime` | JavaScriptCore mit der Node-Schicht, echtes HTTP auf `127.0.0.1` |
| `OdeteNpm` | Registry, semver, `package-lock` v3, Tarballs, `.bin`, `esm.sh`-Fallback |
| `OdeteBundler` | esbuild-wasm in JSC: TS/ESM-Transform, Build, Dev-Server mit Reload |
| `OdeteShell` | Parser (`\|` `>` `>>` `<` `&&` `\|\|` `;` `&` `$VAR`), Builtins, git, npm, node, Jobs |
| `OdetePreview` | Die WKWebView des Previews, das Schema `odete://static/` und die Konsolen-Brücke |
| `OdeteAgent` | Provider, Streaming, die Tool-Schleife, Patches, Checkpoints, Unterhaltungen, Skills |
| `OdeteSwift` | Parser und Interpreter für die SwiftUI-Teilmenge, natives Rendering, `.swiftpm`-Packaging |
| `OdeteUI` | Design-System: `Theme`, `Rail`, `PaneHeader`, `EditorTabs`, `Splitter`, `FileGlyph` |
| `OdeteApp` | Die Screens: Hub, Workspace, Bereiche, Sheets, Einstellungen |

Abhängigkeiten fließen in eine Richtung: `OdeteApp → {OdeteUI, OdeteGit, OdeteAccounts, OdeteShell, OdetePreview, OdeteAgent, OdeteSwift}`,
`OdeteShell → {OdeteGit, OdeteNpm, OdeteRuntime, OdeteBundler}`, `OdeteBundler → OdeteRuntime`,
alles oben auf `OdeteCore` und `OdeteI18n`.

Design-Specs und Implementierungspläne für alle sechs Phasen liegen in
[`docs/superpowers/`](docs/superpowers/).

---

## Wo deine Daten liegen

| Was | Wo |
|---|---|
| Projekte | `Documents/Projects/<name>/` — sichtbar in der Dateien-App |
| Projekt-Metadaten | `<project>/.odete/project.json` |
| Unterhaltungen, Patches, Checkpoints, Pläne | `<project>/.odete/` (aus git ausgeschlossen) |
| Layout und Einstellungen | `Application Support/Odete/state.json` |
| Tokens und Keys | Keychain — nie eine Datei, nie ein Backup |

`.odete/` wird in `.git/info/exclude` eingetragen, damit die Historie des Agenten nie in deinen commits landet.

Projekte können stattdessen in iCloud Drive liegen (**Einstellungen → System**) — das ist der
Unterschied zwischen „Deinstallieren verliert alles“ und „Deinstallieren verliert nichts“.

---

## Der Hub

<div align="center">
  <img src="docs/img/hub.png" width="900" alt="Der Projekt-Hub: Karten mit Stack-Badges und Zeitpunkt des letzten Öffnens" />
</div>

Projekte zeigen ihren erkannten Stack, die erste Zeile ihrer README und wann du sie zuletzt geöffnet
hast. **Ordner öffnen** übernimmt einen Ordner von überall her über ein Security Bookmark (als
*extern* markiert), **Klonen** holt von einer URL, **Neues Projekt** bietet: leer, Vite + React,
Astro, einfaches HTML, SwiftUI-View oder ein Swift-Playground-Paket.

Kurzbefehle sind auch verdrahtet: *Projekt öffnen*, *Befehl ausführen*, *Odete fragen*, *Neues Projekt*.

---

## Bekannte Lücken

Ehrlich benannt, denn eine README, die nur Erfolge auflistet, ist eine Broschüre:

- `astro build` und `next build` laufen noch nicht — Astro und Next nur im Dev-Modus
- Astro-Seiten werden gerendert; Islands mit Hydration, MDX und Content Collections nicht
- Next führt den App Router aus (dynamische Segmente, Catch-all, Route Groups, Route Handler,
  `metadata`, `not-found`, `error`) sowie den Pages Router, hydriert `'use client'`-Komponenten
  und führt Middleware, `next/font` und Server Actions aus. Es fehlt: `useActionState` zeigt
  den Anfangszustand, bis die Island hydriert (`renderToString` nimmt den Postback nicht
  entgegen), Datei-Uploads per Formular-Action, `'use server'` in der Komponente statt am
  Dateianfang, parallele Routen (`@slot`) und clientseitige Navigation — ein Link lädt neu
- Kein SourceKit, also keine Swift-Autovervollständigung; `GeometryReader` und `Canvas` sind nicht in der Preview-Teilmenge
- Die Vervollständigung lässt sich nicht mit Pfeiltasten durchgehen — Tab/Enter nimmt den ersten Eintrag, oder antippen
- Zwei Agenten parallel, MCP und Sprachsteuerung sind nicht gebaut
- iCloud Drive braucht die App signiert mit dem Container `iCloud.com.okamiops.odete`
- Der GitHub Device Flow braucht ein ausgefülltes `OdeteGitHubClientId`; bis dahin ein persönlicher Token
- Die Anmeldung mit einem Claude- oder Codex-**Abo** nutzt die OAuth-Clients dieser CLIs, die
  Anthropic und OpenAI auf ihre eigenen Apps beschränken. Das zu entscheiden ist deine Sache, nicht unsere.

---

## Mitmachen

`make check` ist das Tor: Format, Lint, Übersetzungskatalog, Build, 223 Tests. CI fährt bei jedem push
dasselbe.

Zwei Regeln, die nicht offensichtlich sind:

1. **Jeder neue nutzersichtbare String geht durch `tr("…")`**, auf Portugiesisch geschrieben — das
   Portugiesische *ist* der Schlüssel. Dann trag die vier Übersetzungen in
   `Packages/OdeteI18n/Sources/OdeteI18n/Resources/Localizable.xcstrings` ein. `make i18n` sagt dir,
   wenn du es vergessen hast.
2. **Übersetze nie einen String, der irgendwo verglichen wird.** Wenn Code `text == "x"` macht, ist
   `"x"` ein Sentinel, kein Label.

---

## Credits

| | |
|---|---|
| [IBM Plex](https://github.com/IBM/plex) | Sans und Mono — OFL |
| [Runestone](https://github.com/simonbs/Runestone) + [tree-sitter](https://tree-sitter.github.io) | Editor und Highlighting — MIT |
| [libgit2](https://libgit2.org) | Git — GPL2 mit Linking-Ausnahme |
| [esbuild](https://esbuild.github.io) | Bundling und Transform — MIT |

Odete ist nach einem Mäuschen benannt. Sie sitzt im Icon und in der Ecke des Git-Bereichs.
