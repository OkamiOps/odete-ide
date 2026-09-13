import { snippetCompletion, type Completion, type CompletionContext, type CompletionResult } from "@codemirror/autocomplete";
import { extOf } from "@/lib/utils";

function snip(label: string, template: string, detail: string, type = "keyword"): Completion {
  return snippetCompletion(template, { label, detail, type, boost: 40 });
}

export type SnipChip = { id: string; label: string; insert: string };

function forPath(path: string): Completion[] {
  const ext = extOf(path);
  const common = [
    snip("todo", "// TODO: ${}", "TODO", "text"),
    snip("fixme", "// FIXME: ${}", "FIXME", "text"),
  ];
  if (ext === "swift") {
    return [
      snip("struct", "struct ${name}: View {\n    var body: some View {\n        ${}\n    }\n}", "SwiftUI View", "class"),
      snip("VStack", "VStack(spacing: 12) {\n    ${}\n}", "VStack", "function"),
      snip("HStack", "HStack(spacing: 12) {\n    ${}\n}", "HStack", "function"),
      snip("ZStack", "ZStack {\n    ${}\n}", "ZStack", "function"),
      snip("Text", 'Text("${}")', "Text", "function"),
      snip("Button", 'Button("${}") {\n    ${}\n}', "Button", "function"),
      snip("Image", 'Image(systemName: "${}")', "SF Symbol", "function"),
      snip("List", "List {\n    ${}\n}", "List", "function"),
      snip("func", "func ${name}() {\n    ${}\n}", "func", "function"),
      snip("var", "var ${name}: ${Type}", "var", "keyword"),
      snip("let", "let ${name} = ${}", "let", "keyword"),
      ...common,
    ];
  }
  if (ext === "html") {
    return [
      snip("div", '<div class="${}">${}</div>', "div", "tag"),
      snip("btn", '<button type="button">${}</button>', "button", "tag"),
      snip("html5", '<!doctype html>\n<html lang="pt-BR">\n<head>\n  <meta charset="utf-8" />\n  <title>${}</title>\n</head>\n<body>\n  ${}\n</body>\n</html>', "boilerplate", "text"),
      ...common,
    ];
  }
  if (ext === "css") {
    return [
      snip("flex", "display: flex;\nalign-items: center;\ngap: 8px;", "flex", "property"),
      snip("grid", "display: grid;\ngrid-template-columns: 1fr 1fr;\ngap: 12px;", "grid", "property"),
      snip("media", "@media (max-width: 720px) {\n  ${}\n}", "media", "keyword"),
      ...common,
    ];
  }
  if (["js", "jsx", "ts", "tsx"].includes(ext)) {
    return [
      snip("rafce", "export default function ${Name}() {\n  return (\n    <div>\n      ${}\n    </div>\n  );\n}", "react fn", "function"),
      snip("rfc", "export function ${Name}() {\n  return (\n    <div>${}</div>\n  );\n}", "react", "function"),
      snip("useState", "const [${state}, set${State}] = useState(${})", "useState", "function"),
      snip("useEffect", "useEffect(() => {\n  ${}\n}, [${}]);", "useEffect", "function"),
      snip("clg", "console.log(${})", "log", "function"),
      snip("fn", "function ${name}() {\n  ${}\n}", "function", "function"),
      snip("afn", "const ${name} = () => {\n  ${}\n}", "arrow", "function"),
      snip("imp", 'import { ${} } from "${}"', "import", "keyword"),
      snip("for", "for (const ${item} of ${list}) {\n  ${}\n}", "for", "keyword"),
      snip("ife", "if (${}) {\n  ${}\n}", "if", "keyword"),
      snip("try", "try {\n  ${}\n} catch (e) {\n  ${}\n}", "try", "keyword"),
      ...common,
    ];
  }
  if (ext === "json") {
    return [snip("pkg", '{\n  "name": "${}",\n  "private": true\n}', "package", "text")];
  }
  if (ext === "md") {
    return [
      snip("h1", "# ${}", "título", "text"),
      snip("h2", "## ${}", "seção", "text"),
      snip("code", "```${}\n${}\n```", "bloco", "text"),
      ...common,
    ];
  }
  return common;
}

export function chipsFor(path: string): SnipChip[] {
  const ext = extOf(path);
  if (ext === "swift") {
    return [
      { id: "Text", label: "Text", insert: 'Text("")' },
      { id: "VStack", label: "VStack", insert: "VStack(spacing: 12) {\n    \n}" },
      { id: "HStack", label: "HStack", insert: "HStack(spacing: 12) {\n    \n}" },
      { id: "Button", label: "Button", insert: 'Button("") {\n    \n}' },
      { id: "func", label: "func", insert: "func name() {\n    \n}" },
    ];
  }
  if (ext === "css") {
    return [
      { id: "flex", label: "flex", insert: "display: flex;\nalign-items: center;\ngap: 8px;" },
      { id: "grid", label: "grid", insert: "display: grid;\ngrid-template-columns: 1fr 1fr;\ngap: 12px;" },
      { id: "media", label: "@media", insert: "@media (max-width: 720px) {\n  \n}" },
    ];
  }
  if (ext === "html") {
    return [
      { id: "div", label: "div", insert: '<div class=""></div>' },
      { id: "btn", label: "button", insert: '<button type="button"></button>' },
    ];
  }
  if (["js", "jsx", "ts", "tsx"].includes(ext)) {
    return [
      { id: "rafce", label: "rafce", insert: "export default function Name() {\n  return (\n    <div>\n      \n    </div>\n  );\n}" },
      { id: "log", label: "log", insert: "console.log()" },
      { id: "fn", label: "fn", insert: "function name() {\n  \n}" },
      { id: "afn", label: "=>", insert: "const name = () => {\n  \n}" },
    ];
  }
  return [
    { id: "todo", label: "TODO", insert: "// TODO: " },
  ];
}

export function snippetBody(path: string, token: string) {
  const map: Record<string, string> = {
    rafce: "export default function Name() {\n  return (\n    <div>\n      \n    </div>\n  );\n}",
    rfc: "export function Name() {\n  return (\n    <div></div>\n  );\n}",
    useState: "const [state, setState] = useState()",
    useEffect: "useEffect(() => {\n  \n}, [])",
    clg: "console.log()",
    log: "console.log()",
    fn: "function name() {\n  \n}",
    afn: "const name = () => {\n  \n}",
    todo: "// TODO: ",
  };
  if (map[token]) return map[token];
  const chip = chipsFor(path).find((c) => c.id === token || c.label === token);
  return chip?.insert ?? null;
}

export function coloCompletions(path: string) {
  const options = forPath(path);
  return (context: CompletionContext): CompletionResult | null => {
    const word = context.matchBefore(/[\w./@-]*/);
    if (!word) return null;
    if (word.from === word.to && !context.explicit) return null;
    const q = word.text.toLowerCase();
    const list = q ? options.filter((o) => o.label.toLowerCase().includes(q)) : options;
    if (!list.length) return context.explicit ? { from: word.from, options } : null;
    return { from: word.from, options: list, validFor: /^[\w./@-]*$/ };
  };
}
