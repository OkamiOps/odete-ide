// Compila `.astro` para um módulo CommonJS que devolve HTML.
//
// O compilador oficial do Astro é WebAssembly (e no Astro 7, Rust nativo), e isso precisa
// de JIT — que um app de terceiro não tem no iPad. Sem isto o Preview mostrava 404 em todo
// projeto Astro, que é o modelo que o próprio Hub oferece. Este cobre o que uma página de
// verdade usa: frontmatter em TypeScript com imports, expressões, componentes, props,
// `<slot />`, `class:list`, `set:html` e blocos `<style>` com escopo, como o Astro faz.
// Não cobre ilhas com hidratação (`client:*`).
//
// São duas passagens. A primeira (`compila`, síncrona) lê o arquivo e escreve o módulo;
// a segunda (`compilaAsync`) passa o módulo pelo esbuild para tirar os tipos — `interface
// Props`, `as Props`, `const n: number` — e trocar `import.meta.env` pelos valores.
(function (raiz) {
  "use strict";

  // ---- escape ----
  const MARCA = "__odeteHtmlSeguro";
  function seguro(s) { return { [MARCA]: true, valor: String(s), toString() { return this.valor; } }; }
  function escapa(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }
  // Valor vindo de `{...}`: array vira concatenação, nulo some, string escapa. JSX dentro
  // de expressão (`{xs.map((x) => <Card />)}`) chega como promessa — o componente é
  // assíncrono, e o `map` não é —, então espera-se tudo antes de juntar.
  function textoJa(v) {
    if (v == null || v === false || v === true) return "";
    if (Array.isArray(v)) return v.map(textoJa).join("");
    if (typeof v === "object" && v[MARCA]) return v.valor;
    return escapa(v);
  }
  function temPromessa(v) {
    if (v && typeof v.then === "function") return true;
    return Array.isArray(v) && v.some(temPromessa);
  }
  async function resolve(v) {
    if (v && typeof v.then === "function") return resolve(await v);
    if (Array.isArray(v)) return Promise.all(v.map(resolve));
    return v;
  }
  function texto(v) {
    if (!temPromessa(v)) return textoJa(v);
    return resolve(v).then(textoJa);
  }
  // O HTML de um pedaço de JSX numa expressão.
  function jsx(f) { return f().then(seguro); }

  // ---- leitura do fonte ----
  // Frontmatter é o bloco entre os dois `---` do começo. Sem ele a página é só HTML.
  function separa(src) {
    const m = /^﻿?\s*---\r?\n([\s\S]*?)\r?\n?---[ \t]*\r?\n?/.exec(src);
    if (!m) return { frente: "", corpo: src };
    return { frente: m[1], corpo: src.slice(m[0].length) };
  }

  // Os imports saem do corpo do frontmatter e vão para o topo, como no ESM: cada um vira
  // `const X = await __req("y", Astro)`, que o dev server atende (outro .astro, um .ts
  // empacotado pelo esbuild, CSS, imagem, `astro:content`...). `import type` some — é só
  // tipo —, e `{ type A, b }` fica com o `b`.
  function preparaFrente(codigo) {
    const imports = [];
    const specs = [];
    let fora = codigo;
    fora = fora.replace(/^[ \t]*import[ \t]+type[ \t]+[\s\S]*?[ \t]from[ \t]*(['"])[^'"\n]+\1[ \t]*;?/gm, "");
    // Cada import ganha um nome próprio: dois `import X from` no mesmo arquivo geravam
    // dois `const __m` no mesmo escopo, que é erro de sintaxe — e a página inteira
    // morria no eval, sem dizer onde.
    let seq = 0;
    const tmp = () => "__imp" + (++seq);
    const req = (alvo) => { specs.push(alvo); return `await __req(${JSON.stringify(alvo)}, Astro)`; };
    fora = fora.replace(/^[ \t]*import[ \t]*(['"])([^'"\n]+)\1[ \t]*;?[ \t]*$/gm, (m, q, alvo) => { imports.push(`${req(alvo)};`); return ""; });
    fora = fora.replace(
      /^[ \t]*import[ \t]+([\s\S]*?)[ \t\n]+from[ \t]*(['"])([^'"\n]+)\2[ \t]*;?[ \t]*$/gm,
      (m, clausula, q, alvo) => {
        const r = req(alvo);
        const c = clausula.trim();
        const ns = /^\*\s+as\s+([A-Za-z_$][\w$]*)$/.exec(c);
        let linha;
        if (ns) linha = `const ${ns[1]} = ${r};`;
        else {
          const misto = /^([A-Za-z_$][\w$]*)\s*,\s*\{([\s\S]*)\}$/.exec(c);
          const nomeada = /^\{([\s\S]*)\}$/.exec(c);
          const misto2 = /^([A-Za-z_$][\w$]*)\s*,\s*\*\s+as\s+([A-Za-z_$][\w$]*)$/.exec(c);
          if (misto) { const n = tmp(); linha = `const ${n} = ${r}; const ${misto[1]} = ${n}.default ?? ${n}; const {${chaves(misto[2])}} = ${n};`; }
          else if (nomeada) linha = `const {${chaves(nomeada[1])}} = ${r};`;
          else if (misto2) linha = `const ${misto2[2]} = ${r}; const ${misto2[1]} = ${misto2[2]}.default ?? ${misto2[2]};`;
          else { const n = tmp(); linha = `const ${n} = ${r}; const ${c} = ${n}.default ?? ${n};`; }
        }
        imports.push(linha);
        return "";
      }
    );
    // `export` no frontmatter não exporta nada útil aqui (o `getStaticPaths` é lido à
    // parte); vira declaração normal. `export { x }` some.
    fora = fora.replace(/^[ \t]*export[ \t]+(?=(const|let|var|function|async[ \t]+function|interface|type|enum|class|abstract)\b)/gm, "");
    fora = fora.replace(/^[ \t]*export[ \t]*\{[^}]*\}[ \t]*;?[ \t]*$/gm, "");
    return { imports, specs, corpo: fora };
  }
  function chaves(dentro) {
    return dentro.split(",").map((p) => p.trim()).filter((p) => p && !/^type\s/.test(p))
      .map((p) => p.replace(/\s+as\s+/, ": ")).join(", ");
  }

  // ---- varredura do template ----
  const BRANCO = /\s/;
  function ehNomeComponente(nome) { return /^[A-Z]/.test(nome) || /^[A-Za-z_$][\w$]*\.[A-Za-z_$]/.test(nome); }

  // Anda até o fecho da chave, respeitando string, template e chave aninhada.
  function fimDaExpressao(s, i) {
    let nivel = 0;
    while (i < s.length) {
      const c = s[i];
      if (c === '"' || c === "'" || c === "`") { i = fimDaString(s, i, c); continue; }
      if (c === "{") nivel++;
      else if (c === "}") { nivel--; if (nivel === 0) return i; }
      i++;
    }
    return -1;
  }
  function fimDaString(s, i, aspas) {
    i++;
    while (i < s.length) {
      if (s[i] === "\\") { i += 2; continue; }
      if (aspas === "`" && s[i] === "$" && s[i + 1] === "{") { const f = fimDaExpressao(s, i + 1); i = f < 0 ? s.length : f + 1; continue; }
      if (s[i] === aspas) return i + 1;
      i++;
    }
    return i;
  }

  function literal(txt) {
    return txt.replace(/\\/g, "\\\\").replace(/`/g, "\\`").replace(/\$\{/g, "\\${");
  }

  // Lê `<Nome attr="x" outro={y} {...z} />` e devolve nome, props e onde o tag termina.
  function leTag(s, i) {
    const abre = i;
    i++; // <
    let nome = "";
    while (i < s.length && !BRANCO.test(s[i]) && s[i] !== ">" && s[i] !== "/") nome += s[i++];
    if (nome === "" && s[i] === "/") { nome = "/"; i++; while (i < s.length && !BRANCO.test(s[i]) && s[i] !== ">") nome += s[i++]; }
    const props = [];
    while (i < s.length) {
      while (i < s.length && BRANCO.test(s[i])) i++;
      if (s[i] === ">") return { nome, props, fim: i + 1, sozinho: false, texto: s.slice(abre, i + 1) };
      if (s[i] === "/" && s[i + 1] === ">") return { nome, props, fim: i + 2, sozinho: true, texto: s.slice(abre, i + 2) };
      if (s[i] === "{") { // spread, ou o atalho `{nome}` do Astro
        const f = fimDaExpressao(s, i);
        if (f < 0) break;
        const dentro = s.slice(i + 1, f).trim();
        if (/^\.\.\./.test(dentro)) props.push({ spread: dentro.replace(/^\.\.\./, "") });
        else props.push({ chave: dentro, bruto: dentro });
        i = f + 1; continue;
      }
      let chave = "";
      while (i < s.length && !BRANCO.test(s[i]) && s[i] !== "=" && s[i] !== ">" && !(s[i] === "/" && s[i + 1] === ">")) chave += s[i++];
      if (!chave) { i++; continue; }
      while (i < s.length && BRANCO.test(s[i]) && s[i] !== "\n") i++;
      if (s[i] !== "=") { props.push({ chave, bruto: "true", sem: true }); continue; }
      i++; // =
      while (i < s.length && BRANCO.test(s[i])) i++;
      if (s[i] === "{") {
        const f = fimDaExpressao(s, i);
        if (f < 0) break;
        props.push({ chave, bruto: s.slice(i + 1, f) });
        i = f + 1;
      } else if (s[i] === '"' || s[i] === "'") {
        const aspas = s[i];
        const f = s.indexOf(aspas, i + 1);
        const fim = f < 0 ? s.length : f;
        props.push({ chave, bruto: JSON.stringify(s.slice(i + 1, fim)), cru: s.slice(i + 1, fim) });
        i = fim + 1;
      } else if (s[i] === "`") {
        const f = fimDaString(s, i, "`");
        props.push({ chave, bruto: s.slice(i, f) });
        i = f;
      } else {
        let v = "";
        while (i < s.length && !BRANCO.test(s[i]) && s[i] !== ">") v += s[i++];
        props.push({ chave, bruto: JSON.stringify(v), cru: v });
      }
    }
    return { nome, props, fim: i, sozinho: true, texto: s.slice(abre, i) };
  }

  // Do fim de um tag de abertura até o seu fecho, contando aninhamento do mesmo nome.
  function fimDoBloco(s, nome, i) {
    let nivel = 1;
    const n = nome.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const abre = new RegExp("<" + n + "(?=[\\s/>])", "g");
    const fecha = new RegExp("</" + n + "\\s*>", "g");
    while (i < s.length) {
      abre.lastIndex = i; fecha.lastIndex = i;
      const a = abre.exec(s), f = fecha.exec(s);
      if (!f) return -1;
      if (a && a.index < f.index) {
        // `<Tag />` não abre nível
        const t = leTag(s, a.index);
        if (!t.sozinho) nivel++;
        i = t.fim;
        continue;
      }
      nivel--;
      if (nivel === 0) return { corpo: [f.index], fim: f.index + f[0].length };
      i = f.index + 1;
    }
    return -1;
  }

  // Os nomes de prop de um componente: `class` vira `class` mesmo (o Astro passa assim), e
  // o atalho `{nome}` vira `nome: nome`.
  function propsParaObjeto(props) {
    const partes = props.filter((p) => !/^(client|server|transition):/.test(p.chave || ""))
      .map((p) => p.spread ? `...(${p.spread})` : `${JSON.stringify(p.chave)}: (${p.bruto})`);
    return "{" + partes.join(", ") + "}";
  }

  // Depois destes caracteres, um `<` começa um elemento, não é "menor que".
  const ANTES_DE_JSX = "([{,;:?=>&|!+-*/%~^\n\r\t ";
  const PALAVRAS_JSX = ["return", "typeof", "await", "yield", "in", "of", "case", "do", "else"];

  function ehPosicaoJsx(s, i) {
    let j = i - 1;
    while (j >= 0 && BRANCO.test(s[j])) j--;
    if (j < 0) return true;
    if (ANTES_DE_JSX.includes(s[j])) return true;
    let palavra = "";
    while (j >= 0 && /[A-Za-z]/.test(s[j])) palavra = s[j--] + palavra;
    return PALAVRAS_JSX.includes(palavra);
  }

  // JSX dentro de `{...}`: `{xs.map((x) => <li>{x}</li>)}` é como uma lista se escreve
  // no Astro. Sem isto o elemento vira texto e a página mostra `&lt;li&gt;` na tela.
  // O resultado é marcado como seguro, porque já é HTML e não pode ser escapado de novo.
  function compilaExpressao(expr, ctx) {
    let fora = "";
    let i = 0;
    while (i < expr.length) {
      const c = expr[i];
      if (c === '"' || c === "'" || c === "`") { const f = fimDaString(expr, i, c); fora += expr.slice(i, f); i = f; continue; }
      if (c === "<" && ehPosicaoJsx(expr, i)) {
        const prox = expr[i + 1] || "";
        if (prox === ">") { // fragmento <>…</>
          const f = expr.indexOf("</>", i);
          if (f < 0) { fora += c; i++; continue; }
          fora += "__jsx(async () => `" + compilaTemplate(expr.slice(i + 2, f), ctx) + "`)";
          i = f + 3;
          continue;
        }
        if (/[A-Za-z]/.test(prox)) {
          const tag = leTag(expr, i);
          if (tag.sozinho) { fora += "__jsx(async () => `" + compilaTemplate(tag.texto, ctx) + "`)"; i = tag.fim; continue; }
          const bloco = fimDoBloco(expr, tag.nome, tag.fim);
          if (bloco === -1) { fora += c; i++; continue; }
          fora += "__jsx(async () => `" + compilaTemplate(expr.slice(i, bloco.fim), ctx) + "`)";
          i = bloco.fim;
          continue;
        }
      }
      fora += c;
      i++;
    }
    return fora;
  }

  // Os que o compilador do Astro nunca escopa (NeverScopedElements): o `<head>` e o que
  // mora nele. `<html>` e `<body>` ganham o atributo — é assim que `html, body { }` num
  // `<style>` de layout funciona.
  const ELEMENTOS_SEM_ESCOPO = new Set(["script", "style", "slot", "!doctype", "head", "title", "meta", "link", "base",
    "noscript", "noframes", "frame", "frameset", "font", "fragment"]);
  const temDiretiva = (p) => p.chave && /:/.test(p.chave) && !/^(xmlns|xlink|xml):/.test(p.chave);

  // Um `<style>` do template: sai do lugar e vai para a folha da página (com escopo, se
  // não for `is:global`). `is:inline` fica onde está, como o Astro.
  function trataEstilo(s, i, ctx) {
    const tag = leTag(s, i);
    const bloco = fimDoBloco(s, "style", tag.fim);
    const fim = bloco === -1 ? s.length : bloco.fim;
    const css = bloco === -1 ? "" : s.slice(tag.fim, bloco.corpo[0]);
    const tem = (n) => tag.props.some((p) => p.chave === n);
    if (tem("is:inline") || tem("define:vars")) {
      const attrs = tag.props.filter((p) => !temDiretiva(p)).map((p) => " " + p.chave + (p.sem ? "" : '="' + (p.cru != null ? p.cru : "") + '"')).join("");
      return { saida: literal("<style" + attrs + ">" + css + "</style>"), fim };
    }
    const lang = (tag.props.find((p) => p.chave === "lang") || {}).cru || "css";
    ctx.estilos.push({ css, global: tem("is:global"), lang });
    return { saida: "", fim };
  }

  // Um `<script>`: o Astro empacota e o manda como módulo. Aqui o conteúdo perde os tipos
  // na segunda passagem (vira um marcador até lá) e vai como `type="module"`. Com `src`,
  // ou `is:inline`, fica como está.
  function trataScript(s, i, ctx) {
    const tag = leTag(s, i);
    const bloco = fimDoBloco(s, "script", tag.fim);
    const fim = bloco === -1 ? s.length : bloco.fim;
    const js = bloco === -1 ? "" : s.slice(tag.fim, bloco.corpo[0]);
    const tem = (n) => tag.props.some((p) => p.chave === n);
    const tipo = (tag.props.find((p) => p.chave === "type") || {}).cru;
    if (tem("is:inline") || tem("src") || (tipo && !/module|javascript|typescript/i.test(tipo))) {
      const attrs = tag.props.filter((p) => !temDiretiva(p)).map((p) => " " + p.chave + (p.sem ? "" : '="' + (p.cru != null ? p.cru : "") + '"')).join("");
      return { saida: literal("<script" + attrs + ">" + js + "</script>"), fim };
    }
    const n = ctx.scripts.push(js) - 1;
    return { saida: "<script type=\"module\">__ODETE_SCRIPT_" + n + "__</script>", fim };
  }

  function compilaTemplate(s, ctx) {
    let fora = "";
    let i = 0;
    while (i < s.length) {
      const c = s[i];
      if (c === "{") {
        const f = fimDaExpressao(s, i);
        if (f < 0) { fora += literal(s.slice(i)); break; }
        const expr = s.slice(i + 1, f).trim();
        // `{/* comentário */}` não é expressão
        if (expr && !/^\/\*[\s\S]*\*\/$/.test(expr) && !/^\/\/[^\n]*$/.test(expr)) {
          fora += "${await __t(" + compilaExpressao(expr, ctx) + ")}";
        }
        i = f + 1;
        continue;
      }
      if (c === "<") {
        const depois = s.slice(i + 1, i + 8).toLowerCase();
        if (/^style[\s>]/.test(depois)) { const r = trataEstilo(s, i, ctx); fora += r.saida; i = r.fim; continue; }
        if (/^script[\s>]/.test(depois)) { const r = trataScript(s, i, ctx); fora += r.saida; i = r.fim; continue; }
        if (s.slice(i, i + 4) === "<!--") { const f = s.indexOf("-->", i); const ate = f < 0 ? s.length : f + 3; fora += literal(s.slice(i, ate)); i = ate; continue; }
        if (!/[A-Za-z!\/]/.test(s[i + 1] || "")) { fora += "&lt;"; i++; continue; }
        if (/^<slot[\s/>]/.test(s.slice(i))) {
          const tag = leTag(s, i);
          const nome = (tag.props.find((p) => p.chave === "name") || {}).bruto || '"default"';
          if (tag.sozinho) { fora += "${await __slot(__slots, " + nome + ", null)}"; i = tag.fim; continue; }
          const bloco = fimDoBloco(s, "slot", tag.fim);
          const dentro = bloco === -1 ? "" : s.slice(tag.fim, bloco.corpo[0]);
          fora += "${await __slot(__slots, " + nome + ", async () => `" + compilaTemplate(dentro, ctx) + "`)}";
          i = bloco === -1 ? s.length : bloco.fim;
          continue;
        }
        const tag = leTag(s, i);
        if (tag.nome === "Fragment" || tag.nome === "") {
          // `<Fragment>` só agrupa; com `set:html` é o HTML cru.
          const html = tag.props.find((p) => p.chave === "set:html" || p.chave === "set:text");
          const bloco = tag.sozinho ? null : fimDoBloco(s, tag.nome, tag.fim);
          const dentro = bloco && bloco !== -1 ? s.slice(tag.fim, bloco.corpo[0]) : "";
          if (html) fora += html.chave === "set:html" ? "${await __html(" + html.bruto + ")}" : "${await __t(" + html.bruto + ")}";
          else fora += compilaTemplate(dentro, ctx);
          i = tag.sozinho || bloco === -1 ? tag.fim : bloco.fim;
          continue;
        }
        if (ehNomeComponente(tag.nome)) {
          const obj = propsParaObjeto(tag.props.filter((p) => p.chave !== "slot"));
          if (tag.sozinho) {
            fora += "${await __comp(" + tag.nome + ", " + obj + ", {}, Astro)}";
            i = tag.fim;
            continue;
          }
          const bloco = fimDoBloco(s, tag.nome, tag.fim);
          const dentro = bloco === -1 ? "" : s.slice(tag.fim, bloco.corpo[0]);
          fora += "${await __comp(" + tag.nome + ", " + obj + ", " + slotsDosFilhos(dentro, ctx) + ", Astro)}";
          i = bloco === -1 ? s.length : bloco.fim;
          continue;
        }
        const nomeMin = tag.nome.toLowerCase();
        const escopo = ctx.cid && !tag.nome.startsWith("/") && !ELEMENTOS_SEM_ESCOPO.has(nomeMin) ? " " + ctx.cid : "";
        const conteudo = tag.props.find((p) => p.chave === "set:html" || p.chave === "set:text");
        // tag comum: os atributos podem ter `{}` e diretivas, então passam pelo mesmo tratamento
        if (conteudo || tag.props.some((p) => p.spread || temDiretiva(p) || !p.cru && p.bruto !== "true" && p.cru == null && !p.sem) || tag.texto.includes("{")) {
          fora += "<" + tag.nome + escopo;
          for (const p of tag.props) {
            if (p === conteudo) continue;
            if (p.spread) { fora += "${__attrs(" + p.spread + ")}"; continue; }
            if (p.chave === "class:list") { fora += "${__attr(\"class\", __classes(" + p.bruto + "))}"; continue; }
            if (temDiretiva(p)) continue;
            if (p.sem) { fora += " " + p.chave; continue; }
            if (p.cru != null) { fora += " " + p.chave + '="' + literal(p.cru) + '"'; continue; }
            fora += "${__attr(" + JSON.stringify(p.chave) + ", " + p.bruto + ")}";
          }
          if (conteudo) {
            const bloco = tag.sozinho ? null : fimDoBloco(s, tag.nome, tag.fim);
            fora += ">" + (conteudo.chave === "set:html" ? "${await __html(" + conteudo.bruto + ")}" : "${await __t(" + conteudo.bruto + ")}") + "</" + tag.nome + ">";
            i = !bloco || bloco === -1 ? tag.fim : bloco.fim;
            continue;
          }
          fora += tag.sozinho ? " />" : ">";
          i = tag.fim;
          continue;
        }
        if (escopo) {
          const t = tag.texto;
          const corte = t.endsWith("/>") ? t.length - 2 : t.length - 1;
          fora += literal(t.slice(0, corte).replace(/\s+$/, "") + escopo + (t.endsWith("/>") ? " />" : ">"));
        } else {
          fora += literal(tag.texto);
        }
        i = tag.fim;
        continue;
      }
      fora += literal(c);
      i++;
    }
    return fora;
  }

  // Os filhos de um componente viram os slots dele: o que tem `slot="x"` vai para o slot
  // `x`, o resto para o padrão.
  function slotsDosFilhos(dentro, ctx) {
    const nomeados = new Map();
    let resto = "";
    let i = 0;
    while (i < dentro.length) {
      if (dentro[i] === "<" && /[A-Za-z]/.test(dentro[i + 1] || "")) {
        const tag = leTag(dentro, i);
        const slot = tag.props.find((p) => p.chave === "slot" && p.cru != null);
        const bloco = tag.sozinho ? null : fimDoBloco(dentro, tag.nome, tag.fim);
        const fim = tag.sozinho || bloco === -1 ? tag.fim : bloco.fim;
        if (slot) {
          const semSlot = dentro.slice(i, fim).replace(/\sslot=(["'])[^"']*\1/, "");
          nomeados.set(slot.cru, (nomeados.get(slot.cru) || "") + semSlot);
        } else {
          resto += dentro.slice(i, fim);
        }
        i = fim;
        continue;
      }
      if (dentro[i] === "{") {
        const f = fimDaExpressao(dentro, i);
        const fim = f < 0 ? dentro.length : f + 1;
        resto += dentro.slice(i, fim);
        i = fim;
        continue;
      }
      resto += dentro[i++];
    }
    const partes = [];
    if (resto.trim()) partes.push("default: async () => `" + compilaTemplate(resto, ctx) + "`");
    for (const [n, html] of nomeados) partes.push(JSON.stringify(n) + ": async () => `" + compilaTemplate(html, ctx) + "`");
    return "{ " + partes.join(", ") + " }";
  }

  // O id de escopo do componente, estável por arquivo, como o `data-astro-cid-*` do Astro.
  function cidDe(arquivo) {
    let h = 0x811c9dc5;
    const s = String(arquivo);
    for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
    return "data-astro-cid-" + h.toString(36).padStart(7, "0").slice(0, 8);
  }

  // ---- escopo do CSS ----
  // `h1 { }` num componente vale só para o `<h1>` dele: cada seletor ganha o atributo do
  // componente em cada parte (`nav a` → `nav[cid] a[cid]`), e cada elemento do template
  // ganha o atributo. `:global(...)` escapa. `@keyframes` e `@font-face` ficam como estão.
  function escopaCSS(css, cid) {
    const attr = "[" + cid + "]";
    let i = 0;
    function pula(fimDe) {
      // copia até `fimDe` em nível 0, respeitando string e comentário
      let out = "", nivel = 0;
      while (i < css.length) {
        const c = css[i];
        if (c === "/" && css[i + 1] === "*") { const f = css.indexOf("*/", i + 2); const ate = f < 0 ? css.length : f + 2; out += css.slice(i, ate); i = ate; continue; }
        if (c === '"' || c === "'") { const f = fimDaString(css, i, c); out += css.slice(i, f); i = f; continue; }
        if (c === "{") nivel++;
        if (c === "}") { if (nivel === 0 && fimDe === "}") return out; nivel--; }
        out += c;
        i++;
      }
      return out;
    }
    function regras(ateFechar) {
      let out = "";
      while (i < css.length) {
        // prelúdio: até `{`, `;` ou `}`
        let pre = "";
        while (i < css.length && css[i] !== "{" && css[i] !== ";" && css[i] !== "}") {
          const c = css[i];
          if (c === "/" && css[i + 1] === "*") { const f = css.indexOf("*/", i + 2); const ate = f < 0 ? css.length : f + 2; pre += css.slice(i, ate); i = ate; continue; }
          if (c === '"' || c === "'") { const f = fimDaString(css, i, c); pre += css.slice(i, f); i = f; continue; }
          if (c === "(") { let n = 0, j = i; for (; j < css.length; j++) { if (css[j] === "(") n++; else if (css[j] === ")" && --n === 0) break; } pre += css.slice(i, j + 1); i = j + 1; continue; }
          pre += c;
          i++;
        }
        if (i >= css.length) { out += pre; break; }
        const c = css[i];
        if (c === "}") { out += pre; if (ateFechar) { i++; return out + "}"; } out += c; i++; continue; }
        if (c === ";") { out += pre + ";"; i++; continue; }
        // c === "{"
        i++;
        const at = /^\s*@([\w-]+)/.exec(pre);
        if (at) {
          const nome = at[1].toLowerCase();
          if (["media", "supports", "container", "layer", "document", "scope", "starting-style"].indexOf(nome) >= 0) {
            out += pre + "{" + regras(true);
          } else {
            out += pre + "{" + pula("}") + "}";
            i++;
          }
          continue;
        }
        out += seletores(pre) + "{" + pula("}") + "}";
        i++;
      }
      return out;
    }
    function seletores(lista) {
      const inicio = lista.match(/^\s*/)[0], fim = lista.match(/\s*$/)[0];
      return inicio + divide(lista.trim(), ",").map((sel) => complexo(sel.trim())).join(", ") + fim;
    }
    function complexo(sel) {
      const g = /^:global\(([\s\S]*)\)$/.exec(sel);
      if (g) return g[1];
      // divide em compostos e combinadores
      const partes = [];
      let atual = "", n = 0;
      for (let k = 0; k < sel.length; k++) {
        const c = sel[k];
        if (c === "(" || c === "[") n++;
        if (c === ")" || c === "]") n--;
        if (!n && (c === " " || c === ">" || c === "+" || c === "~" || c === "\n" || c === "\t")) {
          if (atual) partes.push(atual);
          atual = "";
          if (c !== " " && c !== "\n" && c !== "\t") partes.push(c);
          continue;
        }
        atual += c;
      }
      if (atual) partes.push(atual);
      return partes.map((p) => (/^[>+~]$/.test(p) ? p : composto(p))).join(" ");
    }
    function composto(p) {
      if (/^:global\(/.test(p)) return p.replace(/^:global\(([\s\S]*)\)/, "$1");
      if (p === "&" || /^(from|to|\d+%)$/.test(p)) return p;
      // antes do primeiro pseudo (`a:hover` → `a[cid]:hover`)
      let n = 0;
      for (let k = 0; k < p.length; k++) {
        const c = p[k];
        if (c === "(" || c === "[") n++;
        if (c === ")" || c === "]") n--;
        if (!n && c === ":") return k === 0 ? attr + p : p.slice(0, k) + attr + p.slice(k);
      }
      return p + attr;
    }
    function divide(s, sep) {
      const out = [];
      let atual = "", n = 0;
      for (const c of s) {
        if (c === "(" || c === "[") n++;
        if (c === ")" || c === "]") n--;
        if (c === sep && !n) { out.push(atual); atual = ""; continue; }
        atual += c;
      }
      out.push(atual);
      return out;
    }
    return regras(false);
  }

  // ---- módulo ----
  // `opcoes.cid` força o id de escopo (o dev server usa o caminho relativo à raiz).
  function compila(src, arquivo, opcoes) {
    const o = opcoes || {};
    const { frente, corpo } = separa(src);
    const f = preparaFrente(frente);
    const temEscopo = /<style(?![^>]*\bis:(?:global|inline))[\s>]/i.test(corpo);
    const ctx = { cid: temEscopo ? o.cid || cidDe(arquivo) : null, estilos: [], scripts: [] };
    const tpl = compilaTemplate(corpo, ctx);
    const codigo = `"use strict";
const { __t, __comp, __slot, __attr, __attrs, __seguro, __classes, __html, __jsx } = __astroRuntime;
module.exports.__frente = async function (Astro, __slots, __modo) {
  const __props = (Astro && Astro.props) || {};
${f.imports.join("\n")}
__odeteMarcaPaths();
${f.corpo}
  return \`${tpl}\`;
};
module.exports.render = (Astro, __slots) => module.exports.__frente(Astro, __slots || {}, "render");
module.exports.__arquivo = ${JSON.stringify(arquivo || "")};
`;
    const estilos = ctx.estilos.map((e) => (e.global || !ctx.cid ? e.css : escopaCSS(e.css, ctx.cid)));
    return { codigo, specs: f.specs, estilos, brutos: ctx.estilos, scripts: ctx.scripts, cid: ctx.cid };
  }

  // Segunda passagem: o esbuild tira os tipos de tudo (frontmatter e expressões do
  // template) e troca `import.meta.env`. Depois, o `getStaticPaths` escrito como
  // `const` sobe para logo depois dos imports: no Astro ele roda isolado, sem o resto do
  // frontmatter, e é assim que o dev server o chama sem renderizar a página.
  async function compilaAsync(src, arquivo, opcoes) {
    const o = opcoes || {};
    const c = compila(src, arquivo, o);
    const r = await raiz.__transform(c.codigo, {
      loader: "ts", sourcefile: arquivo, target: "es2022", logLevel: "silent",
      define: o.define || {}, supported: { "top-level-await": true },
    });
    let js = sobePaths(r.code);
    // O `<style>` passa antes pelo pipeline de CSS do dev server (`opcoes.processaEstilo`:
    // Sass com `lang="scss"`, `@apply` do Tailwind) e só então ganha o escopo.
    let estilos = c.estilos;
    if (typeof o.processaEstilo === "function") {
      estilos = [];
      for (let k = 0; k < c.brutos.length; k++) {
        const e = c.brutos[k];
        const css = await o.processaEstilo(e.css, e.lang, arquivo, k);
        estilos.push(e.global || !c.cid ? css : escopaCSS(css, c.cid));
      }
    }
    // Os scripts do template, sem tipos, no lugar dos marcadores.
    for (let k = 0; k < c.scripts.length; k++) {
      let s = c.scripts[k];
      try { s = (await raiz.__transform(s, { loader: "ts", target: "es2022", logLevel: "silent" })).code; } catch (e) { /* vai como veio */ }
      js = js.replace("__ODETE_SCRIPT_" + k + "__", literal(s.replace(/<\/script/gi, "<\\/script")));
    }
    return Object.assign({}, c, { codigo: js, estilos });
  }

  function sobePaths(js) {
    const linhas = js.split("\n");
    const marca = linhas.findIndex((l) => /^\s*__odeteMarcaPaths\(\);\s*$/.test(l));
    if (marca < 0) return js;
    const recuo = linhas[marca].match(/^\s*/)[0];
    const inicio = linhas.findIndex((l, k) => k > marca && new RegExp("^" + recuo + "(const|let|var) getStaticPaths\\b").test(l));
    if (inicio > 0) {
      let fim = inicio + 1;
      const mesmo = new RegExp("^" + recuo + "(?![\\s})\\]])");
      while (fim < linhas.length && !mesmo.test(linhas[fim])) fim++;
      const bloco = linhas.splice(inicio, fim - inicio);
      linhas.splice(marca, 0, ...bloco);
    }
    const k = linhas.findIndex((l) => /^\s*__odeteMarcaPaths\(\);\s*$/.test(l));
    linhas[k] = recuo + 'if (__modo === "paths") { try { return { getStaticPaths: typeof getStaticPaths === "function" ? getStaticPaths : undefined }; } catch (e) { return {}; } }';
    return linhas.join("\n");
  }

  // ---- runtime ----
  // O `Astro` de um componente é o da página com as props e os slots dele.
  function filho(pai, props, slots, componente) {
    const a = Object.assign({}, pai || {});
    a.props = props || {};
    a.slots = {
      has: (n) => !!(slots && slots[n]),
      render: async (n, args) => (slots && slots[n] ? await slots[n](args) : undefined),
    };
    a.self = componente;
    return a;
  }

  async function comp(fn, props, slots, pai) {
    const alvo = fn && fn.render ? fn.render : fn;
    if (typeof alvo !== "function") {
      throw new Error("componente não é um .astro nem uma função: " + String(fn) +
        (fn && typeof fn === "object" ? " (chaves: " + Object.keys(fn).join(", ") + ")" : ""));
    }
    const Astro = filho(pai, props, slots, fn);
    if (pai && pai.__usados && fn && fn.__arquivo) pai.__usados.add(fn.__arquivo);
    const r = await alvo(Astro, slots || {});
    if (r == null) return "";
    if (typeof r === "object" && r[MARCA]) return r.valor;
    return String(r);
  }
  // O que vem de um slot já é HTML compilado, não dado: escapar aqui transformava a
  // página inteira do layout em `&lt;main&gt;` na tela.
  async function slot(slots, nome, padrao) {
    const f = slots && slots[nome || "default"];
    if (f) return await f();
    return padrao ? await padrao() : "";
  }
  // `class:list`, do jeito do clsx: string, lista, objeto de condições, aninhados.
  function classes(v) {
    const out = [];
    const anda = (x) => {
      if (!x) return;
      if (typeof x === "string" || typeof x === "number") { out.push(String(x)); return; }
      if (Array.isArray(x) || x instanceof Set) { for (const y of x) anda(y); return; }
      if (typeof x === "object") for (const k of Object.keys(x)) if (x[k]) out.push(k);
    };
    anda(v);
    return [...new Set(out.join(" ").split(/\s+/).filter(Boolean))].join(" ");
  }
  function attr(nome, v) {
    if (v == null || v === false) return "";
    if (v === true) return " " + nome;
    if (nome === "class" && typeof v === "object") v = classes(v);
    if (nome === "style" && typeof v === "object" && !Array.isArray(v)) {
      const css = Object.keys(v).filter((k) => v[k] != null && v[k] !== false)
        .map((k) => (k.startsWith("--") ? k : k.replace(/[A-Z]/g, (m) => "-" + m.toLowerCase())) + ":" + v[k]).join(";");
      return css ? ' style="' + escapa(css) + '"' : "";
    }
    if (typeof v === "object" && v[MARCA]) v = v.valor;
    return " " + nome + '="' + escapa(v) + '"';
  }
  function attrs(obj) {
    if (!obj) return "";
    return Object.keys(obj).map((k) => (k === "class:list" ? attr("class", classes(obj[k])) : /:/.test(k) && !/^(xmlns|xlink|xml):/.test(k) ? "" : attr(k, obj[k]))).join("");
  }
  async function html(v) {
    v = await v;
    if (v == null) return "";
    if (typeof v === "object" && v[MARCA]) return v.valor;
    return String(v);
  }

  raiz.__astroRuntime = { __t: texto, __comp: comp, __slot: slot, __attr: attr, __attrs: attrs, __seguro: seguro, __classes: classes, __html: html, __jsx: jsx, filho };
  raiz.__astroCompila = compila;
  raiz.__astroCompilaAsync = compilaAsync;
  raiz.__astroEscopaCSS = escopaCSS;
  if (typeof module !== "undefined" && module.exports) module.exports = { compila, compilaAsync, escopaCSS, runtime: raiz.__astroRuntime, texto, escapa };
})(typeof globalThis !== "undefined" ? globalThis : this);
