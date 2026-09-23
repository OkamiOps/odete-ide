<div align="center">

<img src="docs/img/icone.png" width="104" alt="Odete" />

# Odete

**Un IDE de verdad que corre entero en un iPad.**
Editor, git, terminal, npm, vista previa en vivo y un agente que programa — sin Mac, sin servidor, sin runner remoto.

[![Plataforma](https://img.shields.io/badge/iPadOS%20%C2%B7%20iOS-26%2B-000000?style=flat-square&logo=apple&logoColor=white)](#requisitos)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](#arquitectura)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-nativo-0A84FF?style=flat-square)](#arquitectura)
[![En el dispositivo](https://img.shields.io/badge/funciona-100%25%20en%20el%20dispositivo-34C759?style=flat-square)](#cómo-funciona-de-verdad)
[![Idiomas](https://img.shields.io/badge/idiomas-5-FF6B2C?style=flat-square)](#hablando-cinco-idiomas)
[![Pruebas](https://img.shields.io/badge/pruebas-1130-8E8E93?style=flat-square)](#contribuir)
[![Versión](https://img.shields.io/badge/versi%C3%B3n-1.5-FF6B2C?style=flat-square)](CHANGELOG.md)

[English](README.md) · [Português](README.pt-BR.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · **Español**

</div>

---

> **TL;DR** — Odete es un IDE nativo en SwiftUI para iPadOS 26. Tiene un repositorio git real por
> proyecto (libgit2), una shell que de verdad ejecuta `npm install` y `npm run dev`, un runtime
> compatible con Node sobre JavaScriptCore, esbuild compilado a WebAssembly, y un agente de IA que lee tus
> archivos, ejecuta comandos y propone parches que aceptas hunk por hunk. Nada se compila en la
> nube. Nada se sube. Cierra la tapa del portátil — aquí no hay tapa.

> **Novedades de la 1.5** — sin límite de salida en los modelos en la nube y parámetros
> descubiertos por modelo (los lanzamientos nuevos funcionan de entrada), compactación de la
> conversación al 80 % de la ventana de contexto, historial local para cada archivo, un git que ya
> no reporta un push rechazado como "ok", Tailwind CSS v4 de la forma oficial, `npm run dev` que
> instala lo que falta, y Next.js y Astro de punta a punta.
> [Changelog completo →](CHANGELOG.md)

<div align="center">
  <img src="docs/img/preview.png" width="900" alt="Un proyecto Vite corriendo en Odete: el código a la izquierda, el dev server en el terminal, la página en vivo en el Preview" />
  <br />
  <sub>Un proyecto React + Vite: código, dev server y la página en vivo — todo en el iPad.</sub>
</div>

---

## Por qué existe esto

El iPad es una computadora rápida con una historia de desarrollo pésima. Las respuestas de siempre son una
VM remota, un IDE web, o un Mac en el cuarto de al lado. Las tres significan: sin avión, sin metro, sin señal, sin trabajo.

Odete toma el otro camino. Todo lo que tiene que correr, corre aquí.

<table>
<tr>
<td width="50%" valign="top">

<h3>✅ Lo que hace</h3>

- Edita código con resaltado tree-sitter y autocompletado de verdad
- Clona, hace commit, branches, merges, pushes — git real
- Ejecuta `npm install` contra el registro real
- Ejecuta `npm run dev` y sirve tu app en `127.0.0.1`
- Renderiza la app corriendo en un panel de Preview con hot reload
- Ejecuta un agente de IA con herramientas, parches, checkpoints y compactación automática
- Mantiene un historial local de cada archivo, así que ninguna versión se pierde nunca
- Ejecuta proyectos con Tailwind CSS v4, Next.js y Astro tal como vienen
- Habla 5 idiomas, desde las pantallas hasta la salida del terminal

</td>
<td width="50%" valign="top">

<h3>❌ Lo que no hace</h3>

- Sin compilador de Swift (Apple no trae uno para iOS)
- Sin SSH para git — los remotos `git@host:` van por HTTPS con la cuenta del host
- Sin binarios nativos (`esbuild`, `swc`, `lightningcss`) —
  Odete pone sus propios equivalentes
- Sin `astro build` / `next build` todavía — solo modo dev
- Sin submódulos, cherry-pick ni rebase interactivo
- Sin cuenta obligatoria, y sin telemetría tampoco

</td>
</tr>
</table>

---

## Los cinco paneles

<table>
<tr>
<td width="50%" valign="top">

<h3>📝 Editor</h3>

Runestone con tree-sitter. Marcas de git en el margen (verde, azul, rojo — toca una para abrir el hunk
con **Descartar**), los símbolos del archivo a un `@` en la paleta de comandos, lint ligero por lenguaje más errores de sintaxis reales
de esbuild, y autocompletado a partir de las palabras del archivo, las rutas del proyecto y snippets.

Pestañas, vista dividida, vista de diff, visores de imagen/PDF/SQLite. Los búferes sin guardar sobreviven a un
reinicio. Si un archivo cambia en el disco mientras su pestaña tiene ediciones sin guardar, el editor muestra una
barra de conflicto (mantener el mío, recargar, ver diff) en vez de sobrescribir cualquiera de los dos lados. Los
archivos CRLF siguen siendo CRLF, Tab/⇧Tab sangran una selección, y se respeta `.editorconfig`.

**Historial local**: antes de cualquier escritura — tu guardado, el agente, git, el terminal, Reemplazar todo, un
borrado — la versión anterior queda guardada en el dispositivo (fuera del proyecto y de iCloud). Toca y mantén
presionada una pestaña o un archivo para explorar, comparar y restaurar; los archivos borrados también se pueden
recuperar.

</td>
<td width="50%" valign="top">

<h3>🌿 Git</h3>

libgit2, no un wrapper. Status, stage por archivo o por hunk, commit, branch, merge con resolución
de conflictos, stash, remotos por HTTPS, blame e historial por archivo.

Los pull requests de GitHub viven en el panel: abre uno, lee el Markdown, revisa el CI, comenta, haz merge.
✨ escribe el mensaje del commit a partir del diff en stage.

No miente y no pierde trabajo: un push que el servidor rechaza se reporta como rechazado, **Commit**
y **Commit & push** están separados, descartar pregunta primero y manda los archivos a la papelera del proyecto
con Deshacer, y abortar un merge solo toca los archivos del merge.

</td>
</tr>
<tr>
<td valign="top">

<h3>⌨️ Terminal</h3>

La shell propia de Odete — pipes, redirecciones, `&&`, `||`, `;`, `&`, `$VAR`, control de jobs, historial y
autocompletado con Tab. `npm`, `node`, `git`, `npx`, más los de siempre `ls`/`cat`/`grep`/`find`.

Cualquier cosa que abra un puerto se vuelve un job (`jobs`, `kill %1`) y el Preview sigue al último.
La shell está confinada a la carpeta del proyecto — `rm -rf ../other` se rechaza, no se ejecuta.

</td>
<td valign="top">

<h3>▶️ Preview</h3>

Un WKWebView apuntando a tu dev server, que recarga cada vez que guardas. Viewports de iPhone/iPad/escritorio,
la consola de la propia página, y un toque para abrirla en Safari.

Sin ningún servidor corriendo, `index.html` se sirve directo desde el disco vía `odete://static/`.

</td>
</tr>
<tr>
<td colspan="2" valign="top">

<h3>✨ Agente</h3>

Trae tu propia cuenta — Claude (OAuth de suscripción), Codex y Grok (device code), o cualquier
endpoint compatible con OpenAI/Anthropic por clave y URL base. Los tokens viven en el Keychain, nunca
en un archivo.

Ocho herramientas actúan sobre el proyecto real: leer, escribir, reemplazar, listar, grep, leer el terminal,
ejecutar un comando de shell y hablar con la API de GitHub. Tres modos — **Chat** lee, **Plan** escribe
solo `.odete/plan.md`, **Build** edita. Tres niveles de permiso — **Ask**, **Auto**, **Full** —
y cualquier cosa que escriba en el repositorio de otra persona pregunta siempre, incluso en Full.

Cada edición llega como un parche que aceptas, rechazas, o aceptas hunk por hunk. Se escribe un checkpoint
antes de cada turno, así que "deshacer el último turno" es un toque.

Los modelos en la nube no tienen límite artificial de salida: la ventana de contexto, el límite de salida, el
razonamiento y los niveles de esfuerzo se descubren por modelo (APIs de los proveedores más el catálogo público de
models.dev), así que un modelo lanzado ayer ya funciona hoy. Cuando una conversación pasa del **80 % de la ventana
de contexto del modelo** se compacta como lo hace opencode — primero se podan las salidas de herramientas
antiguas, luego se resume el principio y el turno continúa. `/compact` lo hace bajo demanda.

</td>
</tr>
</table>

<div align="center">
  <img src="docs/img/git.png" width="620" alt="El panel de Git: branch, caja de commit, cambios, pull requests e historial" />
  <br />
  <sub>El panel de Git. Los pull requests se leen, se revisan y se mergean sin salir de la app.</sub>
</div>

---

## Cómo funciona de verdad

Esta es la parte que la gente no se cree, así que aquí va el mecanismo honesto:

| Pieza | Cómo | Advertencia |
|---|---|---|
| **Node** | JavaScriptCore + una capa Node escrita a mano: `fs`, `path`, `events`, `buffer`, `stream`, `timers`, `crypto`, `fetch`, `http`, `require`/`import()` | No es V8 (un shim de stack trace mantiene contentos a express y compañía). Sin addons nativos, todavía sin Web Streams. |
| **npm** | Registro real, resolución semver real, `package.json` y `package-lock.json` idénticos byte a byte a los del npm, alias `npm:`, peers, dependencias GitHub/tarball/`file:`/workspaces | Los binarios nativos y los scripts de instalación se omiten |
| **Bundler** | `esbuild-wasm` corriendo dentro de JavaScriptCore, resolución por condición de navegador, alias `@/`, CSS Modules, Sass/Less | Transformación y dev server; `build` solo para Vite |
| **Tailwind** | El compilador de `tailwindcss` v4 corriendo en el mismo motor, con un escáner de clases en JS en vez de oxide | Sin prefijado de lightningcss |
| **Servidor HTTP** | Network.framework, atado a `127.0.0.1` | Local al dispositivo, a propósito |
| **git** | libgit2 1.9.7 como XCFramework, SecureTransport, sin SSH | HTTPS + token |
| **Preview de Swift** | Un intérprete de un subconjunto de SwiftUI, renderizado como SwiftUI real | Sin compilador — ver [Swift en el iPad](#swift-en-el-ipad) |

Dev servers que funcionan hoy: **Vite** (`dev`, `build`, `preview`), **Astro** (`dev`, incluyendo
content collections y MDX), **Next** (`dev`, App Router con CSS y Tailwind), **Nest** (vía `node`).
`npm run dev` instala primero las dependencias que faltan, y el primer arranque después de un install tarda
unos 0,2 s porque el dev server se precalienta en segundo plano.

---

## Swift en el iPad

No hay compilador de Swift en iOS, y Odete no pretende lo contrario.

Lo que hace en su lugar: el Preview **interpreta** un subconjunto útil de SwiftUI y lo renderiza como
SwiftUI genuino — stacks, `List`/`Form`/`Section`, `ScrollView`, `NavigationStack`/`Link`, `Text`,
`Button`, `Toggle`, `TextField`, `Slider`, `Stepper`, `Image(systemName:)`, `Label`, `ForEach`,
`if`/`else`, `@State`/`@Binding`, funciones, interpolación de cadenas y los modificadores comunes.
El estado sobrevive a un guardado; "reiniciar" lo empieza de cero. Lo que quede fuera del subconjunto se vuelve un
marcador punteado más un aviso en Problemas, con el número de línea.

Para el código que sí tiene que compilar, la plantilla **Swift Playground** produce un paquete `.swiftpm`
y un botón se lo entrega a Swift Playgrounds.

---

## Hablando cinco idiomas

<div align="center">
  <img src="docs/img/idiomas.png" width="820" alt="El selector de idioma: idioma del dispositivo, Português, English, Deutsch, Français, Español" />
</div>

La app entera — pantallas, salida del terminal, mensajes de git, avisos del lint, y el idioma en que
responde el agente — está traducida a **🇧🇷 Português · 🇺🇸 English · 🇩🇪 Deutsch · 🇫🇷 Français · 🇪🇸 Español**.

Por defecto Odete sigue al iPad. Cámbialo en **Ajustes → Idioma** y la interfaz
cambia al instante, sin reabrir la app. Las fechas, los tamaños de archivo, los tiempos relativos y el
reconocimiento de voz siguen la misma elección.

1.278 cadenas viven en un único String Catalog. `make i18n` lo compara contra el código y
falla si se añadió una frase sin traducciones — que es como se mantiene así.

---

## Primeros pasos

### Requisitos

- Xcode 26.6 o más reciente, con el runtime del simulador de iOS 26.5
- `brew install xcodegen swiftformat swiftlint`

### Compilar y ejecutar

```bash
git clone https://github.com/OkamiOps/odete-ide.git
cd odete-ide
make run
```

`make run` genera el proyecto de Xcode, lo compila, lo instala en el simulador del iPad Air de 11 pulgadas (M4)
y lo lanza. Para otro dispositivo:

```bash
make run SIM="iPhone 17"
```

### Todos los comandos

| Comando | Qué hace |
|---|---|
| `make gen` | Genera `Odete.xcodeproj` a partir de `project.yml` |
| `make build` | Compila para el simulador |
| `make run` | Compila, instala y lanza |
| `make unit` | Pruebas unitarias de los 15 paquetes (1.130 pruebas) |
| `make test` | Pruebas de interfaz (XCUITest) |
| `make lint` | `swiftformat --lint` + `swiftlint` |
| `make format` | `swiftformat` |
| `make i18n` | Revisa el catálogo de traducciones contra el código |
| `make check` | Todo lo que corre el CI, de una vez |

---

## Arquitectura

Quince paquetes SwiftPM locales, conectados por XcodeGen. Nada se descarga de la red en
tiempo de compilación salvo el XCFramework de libgit2 fijado, que está vendorizado.

| Paquete | Responsabilidad |
|---|---|
| `OdeteI18n` | El String Catalog, el idioma elegido, `tr()` y el formato según la región |
| `OdeteCore` | Modelos puros, temas, reglas de ignore, detección de lenguaje, lint, estado persistido |
| `OdeteFiles` | Proyectos en `Documents/Projects`, árbol de archivos, operaciones, watcher, búsqueda, plantillas |
| `OdeteEditor` | `CodeEditorView` (Runestone + tree-sitter), tema del editor, barra de teclado |
| `OdeteGit` | libgit2: actor `Repository`, diff/hunks, branches, merge, stash, remotos HTTPS |
| `OdeteAccounts` | Keychain, cuentas por host, device flow de GitHub y API REST |
| `OdeteRuntime` | JavaScriptCore con la capa Node, HTTP real en `127.0.0.1` |
| `OdeteNpm` | Registro, semver, `package-lock` v3 idéntico al de npm, tarballs, `.bin`, alias, workspaces |
| `OdeteBundler` | esbuild-wasm dentro de JSC: transformación TS/ESM, build, dev server con reload |
| `OdeteShell` | Parser (`\|` `>` `>>` `<` `&&` `\|\|` `;` `&` `$VAR`), builtins, git, npm, node, jobs |
| `OdetePreview` | El WKWebView del Preview, el esquema `odete://static/` y el puente de la consola |
| `OdeteAgent` | Proveedores, streaming, el bucle de herramientas, parches, checkpoints, conversaciones, skills |
| `OdeteSwift` | Parser e intérprete del subconjunto de SwiftUI, renderizado nativo, empaquetado `.swiftpm` |
| `OdeteUI` | Sistema de diseño: `Theme`, `Rail`, `PaneHeader`, `EditorTabs`, `Splitter`, `FileGlyph` |
| `OdeteApp` | Las pantallas: hub, workspace, paneles, hojas, ajustes |

Las dependencias fluyen en un solo sentido: `OdeteApp → {OdeteUI, OdeteGit, OdeteAccounts, OdeteShell, OdetePreview, OdeteAgent, OdeteSwift}`,
`OdeteShell → {OdeteGit, OdeteNpm, OdeteRuntime, OdeteBundler}`, `OdeteBundler → OdeteRuntime`,
todo encima de `OdeteCore` y `OdeteI18n`.

Las specs de diseño y los planes de implementación de las seis fases viven en
[`docs/superpowers/`](docs/superpowers/).

---

## Dónde viven tus datos

| Qué | Dónde |
|---|---|
| Proyectos | `Documents/Projects/<nombre>/` — visibles en la app Archivos |
| Metadatos del proyecto | `<proyecto>/.odete/project.json` |
| Conversaciones, parches, checkpoints, planes | `<proyecto>/.odete/` (excluido de git) |
| Disposición y preferencias | `Application Support/Odete/state.json` |
| Historial local de archivos | `Application Support/Odete/Historico/` — solo en el dispositivo, nunca sincronizado |
| Tokens y claves | Keychain — nunca un archivo, nunca un backup |

`.odete/` se añade a `.git/info/exclude`, así que el historial del agente nunca acaba en tus commits.

Los proyectos también pueden vivir en iCloud Drive (**Ajustes → Sistema**), que es la diferencia
entre "desinstalar lo pierde todo" y "desinstalar no pierde nada".

---

## El hub

<div align="center">
  <img src="docs/img/hub.png" width="900" alt="El hub de proyectos: tarjetas con insignias de stack y la hora de la última apertura" />
</div>

Los proyectos muestran el stack detectado, la primera línea de su README, y cuándo los abriste por
última vez. **Abrir carpeta** adopta una carpeta de cualquier lugar vía un security bookmark (marcada *externa*),
**Clonar** trae desde una URL, **Nuevo proyecto** ofrece: en blanco, Vite + React, Astro, HTML puro,
vista SwiftUI, o un paquete de Swift Playground.

Los atajos también están conectados: *Abrir proyecto*, *Ejecutar comando*, *Preguntar a Odete*, *Nuevo proyecto*.

---

## Carencias conocidas

Dicho sin rodeos, porque un README que solo lista victorias es un folleto:

- `astro build` y `next build` todavía no corren — Astro y Next son solo modo dev
- Las islas de Astro con hidratación `client:*` y loaders de collection personalizados todavía no corren
- Next ejecuta el App Router (segmentos dinámicos, catch-all, grupos de rutas, route handlers,
  `metadata`, `not-found`, `error`) y el Pages Router, hidrata componentes `'use client'` y
  ejecuta middleware, `next/font` y Server Actions. Falta: `useActionState` muestra su estado
  inicial hasta que la isla hidrata (`renderToString` no recibe el postback), la subida de
  archivos por una acción de formulario, `'use server'` escrito dentro del componente en vez
  de al principio del archivo, las rutas paralelas (`@slot`), y la navegación en el cliente —
  un enlace recarga la página
- Sin SourceKit, así que no hay autocompletado de Swift; `GeometryReader` y `Canvas` no están en el subconjunto de la vista previa
- El autocompletado no se navega con las flechas — Tab/Enter toma el primer elemento, o tocas
- Dos agentes en paralelo, MCP y voz no están hechos
- Un `for(;;){}` puro que nunca llama a la app no se puede interrumpir con Ctrl+C
- iCloud Drive necesita la app firmada con el contenedor `iCloud.com.okamiops.odete`
- El device flow de GitHub necesita `OdeteGitHubClientId` rellenado; hasta entonces, un token personal
- Entrar con una **suscripción** de Claude o Codex usa los clientes OAuth de esas CLIs, que
  Anthropic y OpenAI restringen a sus propias apps. Esa decisión es tuya, no nuestra.

---

## Contribuir

`make check` es la puerta: formato, lint, catálogo de traducciones, build, 1.130 pruebas. El CI corre lo mismo
en cada push.

Dos reglas que no son obvias:

1. **Toda cadena nueva visible para el usuario pasa por `tr("…")`**, escrita en portugués — el portugués
   *es* la clave. Después añade las cuatro traducciones a
   `Packages/OdeteI18n/Sources/OdeteI18n/Resources/Localizable.xcstrings`. `make i18n` te
   dirá si se te olvidó.
2. **Nunca traduzcas una cadena que se compare en algún lado.** Si algún código hace `text == "x"`,
   `"x"` es un centinela, no una etiqueta.

---

## Créditos

| | |
|---|---|
| [IBM Plex](https://github.com/IBM/plex) | Sans y Mono — OFL |
| [Runestone](https://github.com/simonbs/Runestone) + [tree-sitter](https://tree-sitter.github.io) | Editor y resaltado — MIT |
| [libgit2](https://libgit2.org) | Git — GPL2 con excepción de enlazado |
| [esbuild](https://esbuild.github.io) | Bundling y transformación — MIT |

Odete lleva el nombre de una ratita. Está en el icono, y en la esquina del panel de Git.
