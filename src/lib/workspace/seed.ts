import type { FileMap } from "./types";

export const SEED_FILES: FileMap = {
  "README.md": `# Odete

IDE no dispositivo. Arquivos, git, terminal e um agente
que edita este workspace — no próprio iPad.

## Neste projeto

| arquivo | o que é |
| --- | --- |
| \`index.html\` | página do preview |
| \`src/style.css\` | visual da página |
| \`src/main.js\` | clique e hora |
| \`App.swift\` | estudo p/ Playgrounds |

## Fluxo

1. Abra \`index.html\`
2. Peça ao agente: *muda o título para Olá*
3. Abra Preview (ou Split)
4. \`git commit\` no terminal ou pelo agente
`,
  ".colo/skills/commit.md": `---
name: Commit
description: Mensagens curtas no padrão convencional, em PT-BR.
when: commit, git, mensagem, changelog
---

Mensagens: tipo(escopo): o que mudou
Tipos: feat, fix, chore, docs, refactor, style, test.
Uma linha, sem ponto final, verbo no infinitivo. Ex: feat(editor): destacar seleção pelo tema.
`,
  ".colo/skills/swiftui.md": `---
name: SwiftUI
description: Estilo SwiftUI simples para o playground do iPad.
when: swift, swiftui, view, vstack, playground
---

Swift neste workspace é um subset: VStack, HStack, Text, Button, padding.
Prefira views pequenas, nomes claros, sem Combine/async. Preview usa o interpretador da Odete.
`,
  ".colo/skills/review.md": `---
name: Review
description: Revisão curta: risco, bug, o que está ok.
when: review, revisa, revisão, olha esse
---

Revise em 3 blocos: (1) o que está ok, (2) bugs/risco, (3) patch sugerido.
Não reescreva arquivo inteiro se um hunk resolve. Cite path:linha.
`,
  ".colo/skills/html.md": `---
name: HTML
description: index.html e CSS do preview, sem framework.
when: html, css, preview, página, index
---

index.html é a página do Preview. CSS em src/style.css. JS em src/main.js.
Sem build step além do Vite. Acessível, contraste ok, sem dependência nova.
`,
  "AGENTS.md": `# Odete

- Preview usa index.html + src/.
- Swift em App.swift: subset SwiftUI (VStack, Text, Button, Toggle).
- Commits curtos em PT-BR.
- Não invente dependência nova sem pedido.
`,
  "package.json": `{
  "name": "odete-demo",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "devDependencies": {
    "vite": "^7.1.0"
  }
}
`,
  "index.html": `<!doctype html>
<html lang="pt-BR">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Odete</title>
    <link rel="stylesheet" href="/src/style.css" />
  </head>
  <body>
    <div class="page">
      <header class="top">
        <span class="mark">O</span>
        <span class="word">ODETE</span>
        <span class="spacer"></span>
        <span class="live" id="clock">—</span>
      </header>
      <main>
        <p class="kicker">workspace local</p>
        <h1>IDE no dispositivo.</h1>
        <p class="lede">
          Arquivos, git, terminal e um agente HTTP
          no próprio dispositivo. Sem outra máquina.
        </p>
        <ul class="feats">
          <li>
            <b>01</b>
            <span>Editor e preview no mesmo lugar</span>
          </li>
          <li>
            <b>02</b>
            <span>Terminal com git e npm i</span>
          </li>
          <li>
            <b>03</b>
            <span>Agente que lê e escreve os arquivos</span>
          </li>
        </ul>
        <button id="ok" type="button">contar clique</button>
        <p id="out" class="out">0 cliques</p>
      </main>
      <footer>
        <span>colo-demo</span>
        <span>sandbox no dispositivo</span>
      </footer>
    </div>
    <script type="module" src="/src/main.js"></script>
  </body>
</html>
`,
  "src/style.css": `:root {
  --paper: #efece4;
  --ink: #161412;
  --mute: #6f6a62;
  --line: #d8d2c6;
  --mark: #161412;
}

* { box-sizing: border-box; }
html, body { margin: 0; }
body {
  min-height: 100dvh;
  background: var(--paper);
  color: var(--ink);
  font-family: "IBM Plex Sans", ui-sans-serif, system-ui, sans-serif;
}

.page {
  min-height: 100dvh;
  display: grid;
  grid-template-rows: 52px 1fr 44px;
}

.top, footer {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 0 28px;
  border-bottom: 1px solid var(--line);
  font-size: 12px;
  letter-spacing: 0.14em;
}

footer {
  border-bottom: 0;
  border-top: 1px solid var(--line);
  color: var(--mute);
  letter-spacing: 0.08em;
  text-transform: uppercase;
  justify-content: space-between;
}

.mark {
  width: 22px;
  height: 22px;
  display: grid;
  place-items: center;
  border: 1px solid var(--ink);
  border-radius: 5px;
  font-size: 11px;
  font-weight: 600;
}

.word { font-weight: 600; letter-spacing: 0.22em; }
.spacer { flex: 1; }
.live { font-family: ui-monospace, Menlo, monospace; letter-spacing: 0; color: var(--mute); }

main {
  padding: 72px 28px 48px;
  max-width: 720px;
}

.kicker {
  margin: 0 0 16px;
  font-size: 11px;
  letter-spacing: 0.18em;
  text-transform: uppercase;
  color: var(--mute);
}

h1 {
  margin: 0 0 20px;
  font-size: clamp(3rem, 8vw, 5.5rem);
  font-weight: 500;
  letter-spacing: -0.055em;
  line-height: 0.92;
}

.lede {
  margin: 0 0 40px;
  max-width: 34ch;
  color: var(--mute);
  font-size: 1.05rem;
  line-height: 1.55;
}

.feats {
  list-style: none;
  margin: 0 0 36px;
  padding: 0;
  display: grid;
  gap: 0;
  border-top: 1px solid var(--line);
}

.feats li {
  display: grid;
  grid-template-columns: 2.5rem 1fr;
  gap: 12px;
  padding: 14px 0;
  border-bottom: 1px solid var(--line);
  font-size: 0.95rem;
}

.feats b {
  font-family: ui-monospace, Menlo, monospace;
  font-weight: 500;
  color: var(--mute);
  font-size: 0.8rem;
}

button {
  height: 44px;
  padding: 0 18px;
  border: 0;
  border-radius: 8px;
  background: var(--ink);
  color: var(--paper);
  font: 500 14px/1 "IBM Plex Sans", ui-sans-serif, system-ui, sans-serif;
  cursor: pointer;
}

.out {
  margin: 12px 0 0;
  font-family: ui-monospace, Menlo, monospace;
  font-size: 12px;
  color: var(--mute);
}
`,
  "src/main.js": `let n = 0; // TODO: persistir cliques
const out = document.getElementById("out");
const btn = document.getElementById("ok");
const clock = document.getElementById("clock");

btn?.addEventListener("click", () => {
  n += 1;
  if (out) out.textContent = n === 1 ? "1 clique" : \`\${n} cliques\`;
});

function tick() {
  if (!clock) return;
  const d = new Date();
  clock.textContent = d.toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" });
}
tick();
setInterval(tick, 1000);
`,
  "src/tokens.css": `:root {
  --paper: #efece4;
  --ink: #161412;
  --mute: #6f6a62;
}
`,
  "App.swift": `import SwiftUI

struct ContentView: View {
    @State private var taps = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ODETE")
                .font(.caption.weight(.medium))
                .tracking(3)
                .foregroundStyle(.secondary)
            Text("IDE no dispositivo.")
                .font(.largeTitle.weight(.medium))
            Text("Copia este arquivo para o Swift Playgrounds e dá play no iPad.")
                .foregroundStyle(.secondary)
            Button("contar toque") { taps += 1 }
            Text(taps == 1 ? "1 toque" : "\\(taps) toques")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview { ContentView() }
`,
  "notes.md": `# Notas

- \`npm i\` e \`npm run dev\` usam o Node deste iPad quando o app está em tela cheia (origem isolada).
- Sem isolamento (prévia embutida) o Preview usa esm.sh + JSX/TS da Odete.
- Git é local: commit, log, status, push (HEAD, não o rascunho).
- O agente usa grok-4.5 no servidor do app e as tools mexem nestes arquivos.
`,
};

export const SEED_COMMIT_MESSAGE = "chore: workspace inicial";
