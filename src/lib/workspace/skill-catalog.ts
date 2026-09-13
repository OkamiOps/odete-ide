import { parseSkill, type Skill } from "./skills";
import { useWorkspace } from "./store";

export type CatalogSkill = {
  id: string;
  name: string;
  description: string;
  markdown: string;
};

function md(id: string, name: string, description: string, body: string): CatalogSkill {
  const markdown = `---\nname: ${id}\ndescription: ${description}\n---\n\n# ${name}\n\n${body.trim()}\n`;
  return { id, name, description, markdown };
}

export const SKILL_CATALOG: CatalogSkill[] = [
  md(
    "frontend-design",
    "Frontend Design",
    "UI distinta, sem cara de template de IA. Paleta, tipo e layout de propósito.",
    `Approach this as the design lead at a studio known for a visual identity that cannot be mistaken for anyone else's. The client already rejected cliché proposals. Make opinionated choices about palette, typography, and layout that belong to THIS brief.

## Ground it in the subject
If the brief does not name the product, pick one concrete subject, audience, and job before designing. Vernacular of that world drives the look. A toy for kids and a finance dashboard must not share a kit.

## Design principles
- Hero: the most characteristic thing in the subject's world — headline, image, live demo, interaction. A big number + small label + gradient is the default; only use it if it is truly the best option.
- Type: one family or two clearly distinct. Not Inter/Arial/Roboto/system-ui as the personality face. Type scale with intent. Line length < 80ch.
- Avoid AI tells: one word in a headline in a different color; ALL-CAPS eyebrows; 01/02/03 markers unless the content is a sequence; identical rounded cards with the same soft shadow; cream+#D97757 terracotta; black+#00FF88; tracked labels · middle dots; "→" on every button.
- Motion: one orchestrated moment, not fade-up on every section. Motion that answers a user action is welcome.
- Copy is design. Name things as the user understands them. CTA says what happens: "Save changes", not "Submit".

## Process
1. Write a short plan: 4–6 named hex colors, type roles, layout in one sentence + ASCII, 3 principles unique to this brief.
2. Review the plan against the brief. If it could have been generated for any similar page, revise.
3. Then code. Follow the plan. Don't let CSS classes cancel each other.

Spend boldness in one place. Everything else stays quiet. Responsive, keyboard focus, prefers-reduced-motion, contrast. Before shipping, remove one accessory.`,
  ),
  md(
    "web-critique",
    "Web Critique",
    "Revisa UI como diretor de arte: hierarquia, tipo, espaço, o que cheira a template.",
    `You are an art director reviewing a live interface, not a linter.

Look at hierarchy first (what the eye hits), then type (family, scale, measure), then space (rhythm, alignment), then color (does it belong to the subject), then motion.

Call out AI-default patterns by name: card grid with equal radius, cream/terracotta, acid green on black, numbered 01 features, eyebrow labels, gradient blobs, generic Inter.

For each issue: what is wrong, why it reads cheap, and a specific replacement (token, type, or layout move) — not "make it pop".

End with 3 must-fix and 3 leave-alone. Do not redesign the whole page unless asked.`,
  ),
  md(
    "accessibility",
    "Accessibility",
    "Contraste, foco, semântica, reduced-motion, nomes acessíveis.",
    `Treat a11y as a design constraint, not a patch.

- Contrast: text vs background AA. Don't put light gray on cream.
- Hit targets ≥ 44px on touch. iPad first.
- Focus visible: :focus-visible ring, never outline:none without a replacement.
- Semantics: real buttons, labels for inputs, heading order, alt that describes function.
- Motion: honor prefers-reduced-motion. No essential info only in color.
- Forms: error next to the field, in text, not only a red border.
- Don't add aria unless the native element is wrong.

When editing, fix the markup. Don't write an a11y essay.`,
  ),
  md(
    "interface-copy",
    "Interface Copy",
    "Microcopy de produto: CTA, vazio, erro. Sem marketing vazio.",
    `Words are UI. Write for the person using the screen, in the language of the project (pt-BR unless asked otherwise).

- Button = the action that happens. "Publicar", not "Confirmar".
- Empty state = what to do next, one sentence + one action.
- Error = what failed + how to continue. Never "algo deu errado" alone.
- No lorem. Invent real content that fits the subject.
- No ALL-CAPS labels, no clever puns that hide meaning.
- Same word for the same action across the flow.

If the brief is English, write English. If Portuguese, Brazilian Portuguese — not European.`,
  ),
  md(
    "design-system",
    "Design System",
    "Tokens, tipo, espaço, componentes reutilizáveis. Sem inventar um kit novo a cada tela.",
    `Before new UI, define or reuse tokens:

- Color: bg, fg, muted, accent, border, danger, ok — named, hex, used via CSS variables.
- Type: display / body / mono, sizes in a scale (12 14 16 20 28 40), line-height.
- Space: 4 8 12 16 24 32 48. Don't invent 13px gaps.
- Radius: 0–2 values, not a different radius per card.
- Components: button (primary/ghost), field, list row, tab. Build once, reuse.

If the project already has tokens.css or :root variables, extend them. Don't create a second palette.

Document the tokens at the top of the CSS you touch.`,
  ),
  md(
    "motion",
    "Motion",
    "Movimento com propósito: uma entrada, feedback de ação, reduced-motion.",
    `Motion explains change. It is not decoration.

- One entrance on first paint OR one highlight after an action — not both on every block.
- Duration 120–240ms for UI, easing ease-out. No bounce unless the brand is toy-like.
- Prefers-reduced-motion: opacity only, or none.
- Never animate layout of the whole page (no scroll-jacking, no staggered fade-up of every card).
- Hover on desktop, press states on iPad. Don't rely on hover alone.
- CSS first. No extra animation library.

If the brief is still, keep it still.`,
  ),
  md(
    "swiftui-ios",
    "SwiftUI iOS",
    "SwiftUI idiomático para iPad: NavigationStack, views pequenas, sem Combine.",
    `Write SwiftUI that reads like Apple sample code, not web CSS translated to View.

- Small views. One file, one main View. Extract subviews, not a 400-line body.
- NavigationStack, not nested NavigationView. Toolbar for primary actions.
- SF Symbols for icons. System fonts unless the brief asks otherwise.
- Padding and spacing from the system (16/20), not magic 13s.
- iPad: regular size class, split-friendly. No phone-only assumptions.
- Preview: keep a #Preview. Odete playground understands VStack, HStack, Text, Button, padding.
- No Combine, no async networking unless asked. State with @State / @Binding.

Name views after what the user sees (EditorView), not after architecture (ContentView2).`,
  ),
];

export function catalogById(id: string) {
  return SKILL_CATALOG.find((s) => s.id === id);
}

export function skillPath(id: string) {
  return `.colo/skills/${id.replace(/[^a-z0-9-]/gi, "-").toLowerCase()}.md`;
}

export function installedIds(files: Record<string, string>) {
  const ids = new Set<string>();
  for (const path of Object.keys(files)) {
    const m = path.match(/(?:^|\/)\.colo\/skills\/([^/]+)\.md$/i);
    if (m) ids.add(m[1]!.toLowerCase());
  }
  return ids;
}

export function installCatalog(id: string) {
  const item = catalogById(id);
  if (!item) return "skill não está no catálogo";
  return useWorkspace.getState().writeFile(skillPath(id), item.markdown);
}

export function uninstallSkill(id: string) {
  const path = skillPath(id);
  const w = useWorkspace.getState();
  if (w.files[path] === undefined) {
    const hit = Object.keys(w.files).find((p) => p.endsWith(`/skills/${id}.md`) || p.endsWith(`/skills/${id}/SKILL.md`));
    if (!hit) return "skill não instalada";
    return w.deleteFile(hit);
  }
  return w.deleteFile(path);
}

function toRawUrl(url: string) {
  const u = url.trim();
  const blob = /github\.com\/([^/]+)\/([^/]+)\/blob\/([^/]+)\/(.+)$/.exec(u);
  if (blob) return `https://raw.githubusercontent.com/${blob[1]}/${blob[2]}/${blob[3]}/${blob[4]}`;
  const tree = /github\.com\/([^/]+)\/([^/]+)\/tree\/([^/]+)\/(.+)$/.exec(u);
  if (tree) return `https://raw.githubusercontent.com/${tree[1]}/${tree[2]}/${tree[3]}/${tree[4]}/SKILL.md`;
  const repo = /github\.com\/([^/]+)\/([^/]+)\/?$/.exec(u);
  if (repo) return `https://raw.githubusercontent.com/${repo[1]}/${repo[2]}/main/SKILL.md`;
  return u;
}

export async function installFromUrl(url: string) {
  const raw = toRawUrl(url);
  const res = await fetch(raw);
  if (!res.ok) throw new Error(`não deu pra baixar (${res.status})`);
  const text = await res.text();
  if (!text.trim() || text.trimStart().startsWith("<")) throw new Error("isso não parece um SKILL.md");
  const guessed = parseSkill("SKILL.md", text);
  const id = (guessed?.id || "imported").replace(/[^a-z0-9-]/gi, "-").toLowerCase();
  const markdown = text.includes("---") ? text : `---\nname: ${id}\ndescription: skill importada\n---\n\n${text}`;
  const err = useWorkspace.getState().writeFile(skillPath(id), markdown);
  if (err) throw new Error(err);
  return id;
}

export type MarketItem = {
  id: string;
  name: string;
  repo: string;
  path: string;
};

export async function listMarket(repo = "anthropics/skills", dir = "skills"): Promise<MarketItem[]> {
  async function contents(path: string) {
    const url = path
      ? `https://api.github.com/repos/${repo}/contents/${path}`
      : `https://api.github.com/repos/${repo}/contents`;
    const r = await fetch(url);
    if (!r.ok) throw new Error(`GitHub ${r.status}`);
    const items = (await r.json()) as { name: string; path: string; type: string }[];
    if (!Array.isArray(items)) throw new Error("lista inválida");
    return items;
  }
  let items: { name: string; path: string; type: string }[];
  try {
    items = await contents(dir);
  } catch {
    items = await contents("");
  }
  const skip = new Set(["spec", "template", ".github", "docs", "images"]);
  return items
    .filter((i) => i.type === "dir" && !skip.has(i.name))
    .map((i) => ({ id: i.name, name: i.name.replace(/-/g, " "), repo, path: i.path }));
}

export async function installMarket(item: MarketItem) {
  const url = `https://raw.githubusercontent.com/${item.repo}/main/${item.path}/SKILL.md`;
  return installFromUrl(url);
}
