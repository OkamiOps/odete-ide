// Markdown e frontmatter YAML, em JS puro, para as páginas `.md`/`.mdx` e as content
// collections do Astro.
//
// O Astro usa remark/rehype (e o Astro 7, um parser em Rust), que no iPad não rodam: um é
// uma pilha de dezenas de pacotes para interpretar sem JIT, o outro é binário nativo. Isto
// cobre o que um blog escreve — o GFM do dia a dia: títulos com id, ênfase, links,
// imagens, código cercado, citações, listas aninhadas e de tarefas, tabelas, notas de
// rodapé e HTML no meio do texto — e sai com a marcação que o Astro produziria.
(function (raiz) {
  "use strict";

  const ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" };
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ESC[c]);

  // O slug do github-slugger, que é o que o Astro põe no id dos títulos.
  function slugDe(texto, vistos) {
    let s = String(texto).toLowerCase().trim()
      .replace(/<[^>]*>/g, "")
      .replace(/[^\p{L}\p{M}\p{N}\p{Pc} -]/gu, "")
      .replace(/ /g, "-");
    if (vistos) {
      const base = s;
      let n = vistos.get(base) || 0;
      while (vistos.has(s) && n) s = base + "-" + n++;
      if (vistos.has(s)) { n = 1; while (vistos.has(base + "-" + n)) n++; s = base + "-" + n; }
      vistos.set(base, (vistos.get(base) || 0) + 1);
      vistos.set(s, vistos.get(s) || 1);
    }
    return s;
  }

  // ---- inline ----
  // O que não pode ser tocado pela ênfase (código, links, HTML cru) vira um marcador,
  // o resto é escapado, a ênfase é aplicada e os marcadores voltam.
  function inline(texto, ctx) {
    const guardados = [];
    const guarda = (html) => "\u0000" + (guardados.push(html) - 1) + "\u0000";
    let t = String(texto);

    // código em linha: o mesmo número de crases fecha
    t = t.replace(/(`+)([\s\S]*?[^`])\1(?!`)/g, (m, c, dentro) => {
      let d = dentro.replace(/\n/g, " ");
      if (/^ .* $/.test(d) && d.trim()) d = d.slice(1, -1);
      return guarda("<code>" + escCodigo(d, ctx) + "</code>");
    });
    // escapes
    t = t.replace(/\\([!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~])/g, (m, c) => guarda(esc(c)));
    // quebra de linha forçada
    t = t.replace(/(?: {2,}|\\)\n/g, () => guarda("<br>\n"));
    // HTML cru (e os componentes do MDX)
    t = t.replace(/<\/?[A-Za-z][\w:.-]*(?:\s+[^<>]*?)?\/?>|<!--[\s\S]*?-->/g, (m) => guarda(m));
    // autolinks
    t = t.replace(/<((?:https?|mailto):[^\s<>]+)>/g, (m, u) => guarda('<a href="' + esc(u) + '">' + esc(u) + "</a>"));
    // nota de rodapé
    t = t.replace(/\[\^([^\]\s]+)\]/g, (m, id) => {
      if (!ctx.notas || !ctx.notas.defs.has(id)) return m;
      let n = ctx.notas.ordem.indexOf(id);
      if (n < 0) n = ctx.notas.ordem.push(id) - 1;
      const k = n + 1;
      return guarda('<sup><a href="#user-content-fn-' + esc(id) + '" id="user-content-fnref-' + esc(id) +
        '" data-footnote-ref="" aria-describedby="footnote-label">' + k + "</a></sup>");
    });
    // imagens e links: [texto](destino "título") e as referências [texto][id]
    t = t.replace(/(!?)\[((?:\[[^\]]*\]|[^\[\]])*)\]\(\s*<?([^\s)>]*)>?(?:\s+(?:"([^"]*)"|'([^']*)'))?\s*\)/g,
      (m, img, rotulo, href, t1, t2) => guarda(ligacao(img, rotulo, href, t1 || t2, ctx)));
    t = t.replace(/(!?)\[((?:\[[^\]]*\]|[^\[\]])*)\](?:\[([^\]]*)\])?/g, (m, img, rotulo, ref) => {
      const chave = (ref || rotulo).toLowerCase().trim();
      const d = ctx.refs && ctx.refs.get(chave);
      if (!d) return m;
      return guarda(ligacao(img, rotulo, d.href, d.titulo, ctx));
    });
    // link solto (GFM)
    t = t.replace(/(^|[\s(])((?:https?:\/\/|www\.)[^\s<]*[^\s<.,:;"')\]!?])/g,
      (m, antes, u) => antes + guarda('<a href="' + esc(u.startsWith("www.") ? "http://" + u : u) + '">' + esc(u) + "</a>"));

    t = esc(t);
    t = t.replace(/(\*\*|__)(?=\S)([\s\S]*?\S)\1/g, (m, d, x) =>
      d === "__" && /\w/.test(x[0]) === false ? m : "<strong>" + x + "</strong>");
    t = t.replace(/(^|[^\w*])\*(?=\S)([\s\S]*?\S)\*(?!\*)/g, "$1<em>$2</em>");
    t = t.replace(/(^|[^\w_])_(?=\S)([\s\S]*?\S)_(?![\w_])/g, "$1<em>$2</em>");
    t = t.replace(/~~(?=\S)([\s\S]*?\S)~~/g, "<del>$1</del>");
    t = tipografia(t, ctx);
    return t.replace(/\u0000(\d+)\u0000/g, (m, i) => guardados[+i]);
  }

  // Aspas, travessão e reticências (o retext-smartypants que o Astro liga por padrão).
  function tipografia(t, ctx) {
    if (ctx.smartypants === false) return t;
    return t
      .replace(/---/g, "—").replace(/--/g, "–").replace(/\.\.\./g, "…")
      .replace(/(^|[\s(\[—–])&quot;/g, "$1“").replace(/&quot;/g, "”")
      .replace(/(^|[\s(\[—–])'/g, "$1‘").replace(/'/g, "’");
  }

  // No MDX, chave no meio de código é texto, não expressão.
  function escCodigo(s, ctx) {
    const e = esc(s);
    return ctx.mdx ? e.replace(/\{/g, "&#123;").replace(/\}/g, "&#125;") : e;
  }

  function ligacao(img, rotulo, href, titulo, ctx) {
    const t = titulo ? ' title="' + esc(titulo) + '"' : "";
    if (img) {
      const src = ctx.imagem ? ctx.imagem(href) : href;
      return '<img src="' + esc(src) + '" alt="' + esc(rotulo.replace(/[*_`]/g, "")) + '"' + t + ">";
    }
    return '<a href="' + esc(href) + '"' + t + ">" + inline(rotulo, Object.assign({}, ctx, { refs: null })) + "</a>";
  }

  // ---- blocos ----
  const RE = {
    cerca: /^( {0,3})(`{3,}|~{3,})[ \t]*([^`\s]*)[^`]*$/,
    titulo: /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/,
    regua: /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/,
    citacao: /^ {0,3}> ?/,
    item: /^( {0,3})([-*+]|\d{1,9}[.)])([ \t]+|$)/,
    html: /^ {0,3}(?:<\/?([A-Za-z][\w.:-]*)(?=[\s/>]|$)|<!--)/,
    separador: /^ {0,3}\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/,
    setext: /^ {0,3}(=+|-+)[ \t]*$/,
    ref: /^ {0,3}\[([^\]^][^\]]*)\]:[ \t]*<?(\S+?)>?(?:[ \t]+(?:"([^"]*)"|'([^']*)'|\(([^)]*)\)))?[ \t]*$/,
    nota: /^ {0,3}\[\^([^\]\s]+)\]:[ \t]*(.*)$/,
  };

  const ehBranco = (l) => /^[ \t]*$/.test(l);

  function comecaBloco(l, ctx) {
    return RE.cerca.test(l) || RE.titulo.test(l) || RE.regua.test(l) || RE.citacao.test(l) ||
      RE.item.test(l) || (RE.html.test(l) && !ctx.dentroDeParagrafoHtml);
  }

  function blocos(linhas, ctx) {
    const out = [];
    let i = 0;
    while (i < linhas.length) {
      const l = linhas[i];
      if (ehBranco(l)) { i++; continue; }
      let m;
      if ((m = RE.cerca.exec(l))) {
        const cerca = m[2], ling = m[3] || "", ind = m[1].length;
        const corpo = [];
        i++;
        while (i < linhas.length) {
          const f = new RegExp("^ {0,3}" + cerca[0] + "{" + cerca.length + ",}[ \\t]*$");
          if (f.test(linhas[i])) { i++; break; }
          corpo.push(linhas[i].replace(new RegExp("^ {0," + ind + "}"), ""));
          i++;
        }
        const cls = ling ? ' data-language="' + esc(ling) + '"' : "";
        out.push('<pre class="astro-code"' + cls + ' tabindex="0"><code>' +
          escCodigo(corpo.join("\n") + (corpo.length ? "\n" : ""), ctx) + "</code></pre>");
        continue;
      }
      if ((m = RE.titulo.exec(l))) {
        out.push(titulo(m[1].length, m[2] || "", ctx));
        i++;
        continue;
      }
      if (RE.regua.test(l)) { out.push("<hr>"); i++; continue; }
      if (RE.citacao.test(l)) {
        const dentro = [];
        while (i < linhas.length && !ehBranco(linhas[i])) {
          dentro.push(linhas[i].replace(RE.citacao, ""));
          i++;
        }
        out.push("<blockquote>\n" + blocos(dentro, ctx) + "\n</blockquote>");
        continue;
      }
      if (RE.item.test(l)) {
        const r = lista(linhas, i, ctx);
        out.push(r.html);
        i = r.fim;
        continue;
      }
      if (RE.html.test(l)) {
        const bloco = [];
        while (i < linhas.length && !ehBranco(linhas[i])) bloco.push(linhas[i++]);
        // Uma linha só de HTML em linha (`<abbr>GIF</abbr> é…`) é parágrafo, como no
        // CommonMark: só as tags de bloco e os componentes ficam soltos.
        const tag = (RE.html.exec(bloco[0])[1] || "").toLowerCase();
        const deBloco = !tag || BLOCO_HTML.has(tag) || /^[A-Z]/.test(RE.html.exec(bloco[0])[1] || "");
        out.push(deBloco ? bloco.join("\n") : "<p>" + inline(bloco.join("\n"), ctx) + "</p>");
        continue;
      }
      if (i + 1 < linhas.length && l.indexOf("|") >= 0 && RE.separador.test(linhas[i + 1]) && linhas[i + 1].indexOf("-") >= 0) {
        const r = tabela(linhas, i, ctx);
        out.push(r.html);
        i = r.fim;
        continue;
      }
      // parágrafo, que pode virar título setext
      const par = [l];
      i++;
      while (i < linhas.length && !ehBranco(linhas[i]) && !comecaBloco(linhas[i], ctx)) {
        if (RE.setext.test(linhas[i])) break;
        par.push(linhas[i]);
        i++;
      }
      if (i < linhas.length && RE.setext.test(linhas[i]) && !ehBranco(linhas[i])) {
        const n = linhas[i].trim()[0] === "=" ? 1 : 2;
        out.push(titulo(n, par.join(" "), ctx));
        i++;
        continue;
      }
      out.push("<p>" + inline(par.map((x) => x.replace(/^[ \t]+/, "")).join("\n"), ctx) + "</p>");
    }
    return out.join("\n");
  }

  const BLOCO_HTML = new Set(["address", "article", "aside", "blockquote", "details", "dialog", "div", "dl", "fieldset",
    "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "iframe", "li", "main",
    "nav", "ol", "p", "pre", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul", "video",
    "audio", "picture", "canvas", "style", "script", "center", "svg", "img", "br", "hgroup", "menu", "search", "template"]);

  function titulo(n, texto, ctx) {
    const html = inline(texto.trim(), ctx);
    const puro = html.replace(/<[^>]*>/g, "").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"');
    const slug = slugDe(puro, ctx.slugs);
    ctx.titulos.push({ depth: n, slug, text: puro });
    return "<h" + n + ' id="' + esc(slug) + '">' + html + "</h" + n + ">";
  }

  // Uma lista e os itens dela. O conteúdo de um item é o que está recuado até onde o
  // texto do primeiro começou, e vira blocos de novo — é assim que a lista aninha.
  function lista(linhas, i, ctx) {
    const m0 = RE.item.exec(linhas[i]);
    const ordenada = /\d/.test(m0[2]);
    const inicio = ordenada ? parseInt(m0[2], 10) : 1;
    const itens = [];
    let frouxa = false;
    while (i < linhas.length) {
      const m = RE.item.exec(linhas[i]);
      if (!m || /\d/.test(m[2]) !== ordenada) break;
      const recuo = m[1].length + m[2].length + (m[3].length > 4 || !m[3].length ? 1 : m[3].length);
      const dentro = [linhas[i].slice(m[0].length)];
      i++;
      let brancoAntes = false;
      while (i < linhas.length) {
        const l = linhas[i];
        if (ehBranco(l)) { brancoAntes = true; dentro.push(""); i++; continue; }
        const recuoDaLinha = l.match(/^[ \t]*/)[0].replace(/\t/g, "    ").length;
        if (recuoDaLinha >= recuo) { dentro.push(l.replace(/\t/g, "    ").slice(recuo)); brancoAntes = false; i++; continue; }
        if (brancoAntes || RE.item.test(l) || comecaBloco(l, ctx)) break;
        dentro.push(l); // continuação preguiçosa do parágrafo
        i++;
      }
      while (dentro.length && ehBranco(dentro[dentro.length - 1])) dentro.pop();
      if (dentro.some(ehBranco)) frouxa = true;
      itens.push(dentro);
      // uma linha em branco entre itens também afrouxa a lista
      let j = i - 1;
      while (j > 0 && ehBranco(linhas[j])) j--;
      if (i < linhas.length && ehBranco(linhas[i - 1]) && RE.item.test(linhas[i] || "")) frouxa = true;
    }
    const tag = ordenada ? "ol" : "ul";
    const abre = ordenada && inicio !== 1 ? "<ol start=\"" + inicio + "\">" : "<" + tag + ">";
    const temTarefa = itens.some((d) => /^\[[ xX]\][ \t]/.test(d[0]));
    const lis = itens.map((d) => {
      let tarefa = "";
      const t = /^\[([ xX])\][ \t]+/.exec(d[0]);
      if (t) {
        tarefa = '<input type="checkbox"' + (t[1] !== " " ? " checked" : "") + " disabled> ";
        d = [d[0].slice(t[0].length)].concat(d.slice(1));
      }
      let html = blocos(d, ctx);
      if (!frouxa) html = html.replace(/^<p>([\s\S]*?)<\/p>/, "$1").replace(/\n<p>([\s\S]*?)<\/p>/g, "\n$1");
      const cls = t ? ' class="task-list-item"' : "";
      return "<li" + cls + ">" + tarefa + html + "</li>";
    });
    return {
      html: (temTarefa ? abre.replace(">", ' class="contains-task-list">') : abre) + "\n" + lis.join("\n") + "\n</" + tag + ">",
      fim: i,
    };
  }

  function celulas(l) {
    let s = l.trim();
    if (s.startsWith("|")) s = s.slice(1);
    if (s.endsWith("|") && !s.endsWith("\\|")) s = s.slice(0, -1);
    const out = [];
    let atual = "", codigo = false;
    for (let k = 0; k < s.length; k++) {
      const c = s[k];
      if (c === "\\" && s[k + 1] === "|") { atual += "|"; k++; continue; }
      if (c === "`") codigo = !codigo;
      if (c === "|" && !codigo) { out.push(atual.trim()); atual = ""; continue; }
      atual += c;
    }
    out.push(atual.trim());
    return out;
  }

  function tabela(linhas, i, ctx) {
    const cab = celulas(linhas[i]);
    const alinha = celulas(linhas[i + 1]).map((c) =>
      c.startsWith(":") && c.endsWith(":") ? "center" : c.endsWith(":") ? "right" : c.startsWith(":") ? "left" : "");
    const al = (k) => (alinha[k] ? ' align="' + alinha[k] + '"' : "");
    let html = "<table>\n<thead>\n<tr>\n" + cab.map((c, k) => "<th" + al(k) + ">" + inline(c, ctx) + "</th>").join("\n") + "\n</tr>\n</thead>";
    i += 2;
    const linhasDoCorpo = [];
    while (i < linhas.length && !ehBranco(linhas[i]) && linhas[i].indexOf("|") >= 0 && !comecaBloco(linhas[i], ctx)) {
      const cs = celulas(linhas[i]);
      linhasDoCorpo.push("<tr>\n" + cab.map((_, k) => "<td" + al(k) + ">" + inline(cs[k] || "", ctx) + "</td>").join("\n") + "\n</tr>");
      i++;
    }
    if (linhasDoCorpo.length) html += "\n<tbody>\n" + linhasDoCorpo.join("\n") + "\n</tbody>";
    return { html: html + "\n</table>", fim: i };
  }

  // `opcoes.imagem(href)` reescreve o endereço de uma imagem relativa; `opcoes.mdx` deixa
  // as chaves do código como entidade (no MDX, fora dele, `{}` é expressão).
  function markdown(texto, opcoes) {
    const o = opcoes || {};
    const refs = new Map();
    const defsDeNota = new Map();
    const linhas = [];
    let cerca = null;
    // Definições de referência e de nota saem do texto antes, fora dos blocos de código.
    for (const l of String(texto).replace(/\r\n?/g, "\n").split("\n")) {
      const c = RE.cerca.exec(l);
      if (c && !cerca) cerca = c[2][0];
      else if (cerca && new RegExp("^ {0,3}" + (cerca === "`" ? "`" : "~") + "{3,}[ \\t]*$").test(l)) cerca = null;
      if (!cerca) {
        let m = RE.nota.exec(l);
        if (m) { defsDeNota.set(m[1], m[2]); continue; }
        m = RE.ref.exec(l);
        if (m) { refs.set(m[1].toLowerCase().trim(), { href: m[2], titulo: m[3] || m[4] || m[5] }); continue; }
      }
      linhas.push(l);
    }
    const ctx = {
      refs, imagem: o.imagem, mdx: !!o.mdx, smartypants: o.smartypants,
      slugs: new Map(), titulos: [], notas: { defs: defsDeNota, ordem: [] },
    };
    let html = blocos(linhas, ctx);
    if (ctx.notas.ordem.length) {
      const itens = ctx.notas.ordem.map((id) =>
        '<li id="user-content-fn-' + esc(id) + '">\n<p>' + inline(defsDeNota.get(id), ctx) +
        ' <a href="#user-content-fnref-' + esc(id) + '" data-footnote-backref="" aria-label="Back to reference ' +
        esc(id) + '" class="data-footnote-backref">↩</a></p>\n</li>');
      html += '\n<section data-footnotes="" class="footnotes"><h2 class="sr-only" id="footnote-label">Footnotes</h2>\n<ol>\n' +
        itens.join("\n") + "\n</ol>\n</section>";
    }
    return { html, headings: ctx.titulos };
  }

  // ---- frontmatter ----
  // O bloco `---` do começo de um .md, em YAML. O subconjunto que frontmatter usa:
  // escalares (com e sem aspas), números, booleanos, nulo, listas (`- x` e `[a, b]`),
  // mapas aninhados por recuo e texto em bloco (`|` e `>`). O que passar disso vai para o
  // js-yaml do projeto, se houver.
  function separaFrontmatter(texto) {
    const m = /^﻿?---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(texto);
    if (!m) return { dados: {}, corpo: texto, bruto: "" };
    return { dados: yaml(m[1]), corpo: texto.slice(m[0].length), bruto: m[1] };
  }

  function escalar(v) {
    const s = v.trim();
    if (s === "") return null;
    if (/^"(?:[^"\\]|\\.)*"$/.test(s)) {
      try { return JSON.parse(s); } catch (e) { return s.slice(1, -1); }
    }
    if (/^'(?:[^']|'')*'$/.test(s)) return s.slice(1, -1).replace(/''/g, "'");
    if (/^(true|True|TRUE)$/.test(s)) return true;
    if (/^(false|False|FALSE)$/.test(s)) return false;
    if (/^(null|Null|NULL|~)$/.test(s)) return null;
    if (/^[-+]?\d+$/.test(s)) return parseInt(s, 10);
    if (/^[-+]?(\d+\.\d*|\.\d+|\d+)(e[-+]?\d+)?$/i.test(s)) return parseFloat(s);
    if (/^\[.*\]$/.test(s)) return listaEmLinha(s.slice(1, -1)).map(escalar);
    if (/^\{.*\}$/.test(s)) {
      const o = {};
      for (const par of listaEmLinha(s.slice(1, -1))) {
        const i = par.indexOf(":");
        if (i > 0) o[escalar(par.slice(0, i))] = escalar(par.slice(i + 1));
      }
      return o;
    }
    return s.replace(/[ \t]+#.*$/, "");
  }

  function listaEmLinha(s) {
    const out = [];
    let atual = "", nivel = 0, aspas = null;
    for (const c of s) {
      if (aspas) { atual += c; if (c === aspas) aspas = null; continue; }
      if (c === '"' || c === "'") { aspas = c; atual += c; continue; }
      if (c === "[" || c === "{") nivel++;
      if (c === "]" || c === "}") nivel--;
      if (c === "," && !nivel) { out.push(atual.trim()); atual = ""; continue; }
      atual += c;
    }
    if (atual.trim()) out.push(atual.trim());
    return out;
  }

  function yaml(texto) {
    const linhas = texto.split(/\r?\n/).filter((l) => !/^\s*#/.test(l));
    let i = 0;
    const recuo = (l) => l.match(/^ */)[0].length;
    function valor(nivel) {
      while (i < linhas.length && !linhas[i].trim()) i++;
      if (i >= linhas.length) return null;
      if (/^\s*- /.test(linhas[i]) || /^\s*-$/.test(linhas[i])) return lista(recuo(linhas[i]));
      return mapa(recuo(linhas[i]));
    }
    function bloco(estilo, nivel) {
      const partes = [];
      let r = null;
      while (i < linhas.length && (!linhas[i].trim() || recuo(linhas[i]) > nivel)) {
        if (linhas[i].trim() && r === null) r = recuo(linhas[i]);
        partes.push(linhas[i].slice(r || 0));
        i++;
      }
      while (partes.length && !partes[partes.length - 1].trim()) partes.pop();
      const fim = estilo[1] === "-" ? "" : "\n";
      return estilo[0] === "|" ? partes.join("\n") + fim : partes.join(" ").replace(/\s+\n/g, "\n") + fim;
    }
    function depoisDosDoisPontos(resto, nivel) {
      const r = resto.trim();
      if (/^[|>][-+]?$/.test(r)) { i++; return bloco(r, nivel); }
      if (r === "") { i++; return valor(nivel); }
      i++;
      return escalar(r);
    }
    function mapa(nivel) {
      const o = {};
      while (i < linhas.length) {
        const l = linhas[i];
        if (!l.trim()) { i++; continue; }
        if (recuo(l) < nivel) break;
        if (recuo(l) > nivel) throw new Error("recuo inesperado");
        const m = /^\s*("[^"]*"|'[^']*'|[^:#]+?)\s*:(?:\s+(.*)|\s*)$/.exec(l);
        if (!m) throw new Error("linha que o YAML simples não lê: " + l);
        o[escalar(m[1])] = depoisDosDoisPontos(m[2] || "", nivel);
      }
      return o;
    }
    function lista(nivel) {
      const a = [];
      while (i < linhas.length) {
        const l = linhas[i];
        if (!l.trim()) { i++; continue; }
        if (recuo(l) < nivel || !/^\s*-(\s|$)/.test(l)) break;
        const resto = l.replace(/^\s*-\s?/, "");
        if (/^[^:"'\[{]+?:(\s|$)/.test(resto)) {
          // item que é mapa: a primeira chave está na linha do traço
          linhas[i] = " ".repeat(nivel + 2) + resto;
          a.push(mapa(nivel + 2));
        } else if (!resto.trim()) {
          i++;
          a.push(valor(nivel + 1));
        } else {
          i++;
          a.push(escalar(resto));
        }
      }
      return a;
    }
    const r = valor(0);
    return r && typeof r === "object" && !Array.isArray(r) ? r : {};
  }

  // Com o js-yaml do projeto (o Astro traz), quando o subconjunto não dá conta.
  function frontmatter(texto, jsYaml) {
    try {
      return separaFrontmatter(texto);
    } catch (e) {
      const m = /^﻿?---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(texto);
      if (!m || !jsYaml) throw e;
      return { dados: jsYaml.load(m[1]) || {}, corpo: texto.slice(m[0].length), bruto: m[1] };
    }
  }

  raiz.__odeteMarkdown = { markdown, frontmatter, yaml, slugDe };
  if (typeof module !== "undefined" && module.exports) module.exports = raiz.__odeteMarkdown;
})(typeof globalThis !== "undefined" ? globalThis : this);
