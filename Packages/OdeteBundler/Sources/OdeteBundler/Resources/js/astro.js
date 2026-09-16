// Compila `.astro` para um módulo CommonJS que devolve HTML.
//
// O compilador oficial do Astro é WebAssembly, e WebAssembly precisa de JIT — que um
// app de terceiro não tem no iPad. Sem isto o Preview mostrava 404 em todo projeto
// Astro, que é o modelo que o próprio Hub oferece. Este cobre o que uma página de
// verdade usa: frontmatter com imports, expressões, componentes, props, `<slot />` e
// blocos `<style>`. Não cobre ilhas com hidratação, MDX nem content collections.
(function (raiz) {
  "use strict";

  // ---- escape ----
  const MARCA = "__odeteHtmlSeguro";
  function seguro(s) { return { [MARCA]: true, valor: String(s) }; }
  function escapa(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }
  // Valor vindo de `{...}`: array vira concatenação, nulo some, string escapa.
  function texto(v) {
    if (v == null || v === false || v === true) return "";
    if (Array.isArray(v)) return v.map(texto).join("");
    if (typeof v === "object" && v[MARCA]) return v.valor;
    return escapa(v);
  }

  // ---- leitura do fonte ----
  // Frontmatter é o bloco entre os dois `---` do começo. Sem ele a página é só HTML.
  function separa(src) {
    const m = /^﻿?\s*---\r?\n([\s\S]*?)\r?\n---[ \t]*\r?\n?/.exec(src);
    if (!m) return { frente: "", corpo: src };
    return { frente: m[1], corpo: src.slice(m[0].length) };
  }

  // `import X from "y"` vira `const X = __req("y")`, porque o módulo gerado é CommonJS.
  function importsParaRequire(codigo) {
    let fora = codigo;
    // Cada import ganha um nome próprio: dois `import X from` no mesmo arquivo geravam
    // dois `const __m` no mesmo escopo, que é erro de sintaxe — e a página inteira
    // morria no eval, sem dizer onde.
    let seq = 0;
    const tmp = () => "__imp" + (++seq);
    fora = fora.replace(/^[ \t]*import[ \t]+['"]([^'"]+)['"][ \t]*;?[ \t]*$/gm, (m, alvo) => `__req(${JSON.stringify(alvo)});`);
    fora = fora.replace(
      /^[ \t]*import[ \t]+([\s\S]*?)[ \t]+from[ \t]*['"]([^'"]+)['"][ \t]*;?[ \t]*$/gm,
      (m, clausula, alvo) => {
        const req = `__req(${JSON.stringify(alvo)})`;
        const c = clausula.trim();
        const ns = /^\*\s+as\s+([A-Za-z_$][\w$]*)$/.exec(c);
        if (ns) return `const ${ns[1]} = ${req};`;
        const misto = /^([A-Za-z_$][\w$]*)\s*,\s*\{([\s\S]*)\}$/.exec(c);
        if (misto) { const n = tmp(); return `const ${n} = ${req}; const ${misto[1]} = ${n}.default ?? ${n}; const {${chaves(misto[2])}} = ${n};`; }
        const nomeada = /^\{([\s\S]*)\}$/.exec(c);
        if (nomeada) return `const {${chaves(nomeada[1])}} = ${req};`;
        const misto2 = /^([A-Za-z_$][\w$]*)\s*,\s*\*\s+as\s+([A-Za-z_$][\w$]*)$/.exec(c);
        if (misto2) return `const ${misto2[2]} = ${req}; const ${misto2[1]} = ${misto2[2]}.default ?? ${misto2[2]};`;
        const n = tmp();
        return `const ${n} = ${req}; const ${c} = ${n}.default ?? ${n};`;
      }
    );
    // `export const x` no frontmatter não exporta nada útil aqui; vira variável normal.
    fora = fora.replace(/^[ \t]*export[ \t]+(const|let|var|function|async[ \t]+function)\b/gm, "$1");
    return fora;
  }
  function chaves(dentro) {
    return dentro.split(",").map((p) => p.trim()).filter(Boolean)
      .map((p) => p.replace(/\s+as\s+/, ": ")).join(", ");
  }

  // ---- varredura do template ----
  const BRANCO = /\s/;
  function ehNomeComponente(c) { return c >= "A" && c <= "Z"; }

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
    const props = [];
    while (i < s.length) {
      while (i < s.length && BRANCO.test(s[i])) i++;
      if (s[i] === ">" ) return { nome, props, fim: i + 1, sozinho: false, texto: s.slice(abre, i + 1) };
      if (s[i] === "/" && s[i + 1] === ">") return { nome, props, fim: i + 2, sozinho: true, texto: s.slice(abre, i + 2) };
      if (s[i] === "{") { // spread
        const f = fimDaExpressao(s, i);
        if (f < 0) break;
        props.push({ spread: s.slice(i + 1, f).replace(/^\s*\.\.\./, "") });
        i = f + 1; continue;
      }
      let chave = "";
      while (i < s.length && !BRANCO.test(s[i]) && s[i] !== "=" && s[i] !== ">" && s[i] !== "/") chave += s[i++];
      if (!chave) { i++; continue; }
      if (s[i] !== "=") { props.push({ chave, bruto: "true" }); continue; }
      i++; // =
      if (s[i] === "{") {
        const f = fimDaExpressao(s, i);
        if (f < 0) break;
        props.push({ chave, bruto: s.slice(i + 1, f) });
        i = f + 1;
      } else if (s[i] === '"' || s[i] === "'") {
        const aspas = s[i], f = fimDaString(s, i, aspas);
        props.push({ chave, bruto: JSON.stringify(s.slice(i + 1, f - 1)) });
        i = f;
      } else {
        let v = "";
        while (i < s.length && !BRANCO.test(s[i]) && s[i] !== ">") v += s[i++];
        props.push({ chave, bruto: JSON.stringify(v) });
      }
    }
    return { nome, props, fim: i, sozinho: true, texto: s.slice(abre, i) };
  }

  // Do fim de um tag de abertura até o seu fecho, contando aninhamento do mesmo nome.
  function fimDoBloco(s, nome, i) {
    let nivel = 1;
    const abre = new RegExp("<" + nome + "(?=[\\s/>])", "g");
    const fecha = new RegExp("</" + nome + "\\s*>", "g");
    while (i < s.length) {
      abre.lastIndex = i; fecha.lastIndex = i;
      const a = abre.exec(s), f = fecha.exec(s);
      if (!f) return -1;
      if (a && a.index < f.index) { nivel++; i = a.index + 1; continue; }
      nivel--;
      if (nivel === 0) return { corpo: [f.index], fim: f.index + f[0].length };
      i = f.index + 1;
    }
    return -1;
  }

  function propsParaObjeto(props) {
    const partes = props.map((p) => p.spread ? `...(${p.spread})` : `${JSON.stringify(p.chave)}: (${p.bruto})`);
    return "{" + partes.join(", ") + "}";
  }

  // Blocos onde `{}` é sintaxe de CSS ou de JS do navegador, não do Astro.
  const CRUS = ["style", "script"];

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
  function compilaExpressao(expr) {
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
          fora += "__seguro(`" + compilaTemplate(expr.slice(i + 2, f)) + "`)";
          i = f + 3;
          continue;
        }
        if (/[A-Za-z]/.test(prox)) {
          const tag = leTag(expr, i);
          if (tag.sozinho) { fora += "__seguro(`" + compilaTemplate(tag.texto) + "`)"; i = tag.fim; continue; }
          const bloco = fimDoBloco(expr, tag.nome, tag.fim);
          if (bloco === -1) { fora += c; i++; continue; }
          fora += "__seguro(`" + compilaTemplate(expr.slice(i, bloco.fim)) + "`)";
          i = bloco.fim;
          continue;
        }
      }
      fora += c;
      i++;
    }
    return fora;
  }

  function compilaTemplate(s) {
    let fora = "";
    let i = 0;
    while (i < s.length) {
      const c = s[i];
      if (c === "{") {
        const f = fimDaExpressao(s, i);
        if (f < 0) { fora += literal(s.slice(i)); break; }
        const expr = s.slice(i + 1, f).trim();
        fora += expr ? "${__t(" + compilaExpressao(expr) + ")}" : "";
        i = f + 1;
        continue;
      }
      if (c === "<") {
        const cru = CRUS.find((t) => s.slice(i + 1, i + 1 + t.length).toLowerCase() === t &&
          /[\s>]/.test(s[i + 1 + t.length] || ">"));
        if (cru) {
          const bloco = fimDoBloco(s, cru, i + 1);
          const ate = bloco === -1 ? s.length : bloco.fim;
          fora += literal(s.slice(i, ate));
          i = ate;
          continue;
        }
        if (s.slice(i, i + 5) === "<!--") { const f = s.indexOf("-->", i); const ate = f < 0 ? s.length : f + 3; fora += literal(s.slice(i, ate)); i = ate; continue; }
        if (s.slice(i, i + 6).toLowerCase() === "<slot ".slice(0, 6) || /^<slot[\s/>]/.test(s.slice(i))) {
          const tag = leTag(s, i);
          const nome = (tag.props.find((p) => p.chave === "name") || {}).bruto || '"default"';
          if (tag.sozinho) { fora += "${await __slot(__slots, " + nome + ", null)}"; i = tag.fim; continue; }
          const bloco = fimDoBloco(s, "slot", tag.fim);
          const dentro = bloco === -1 ? "" : s.slice(tag.fim, bloco.corpo[0]);
          fora += "${await __slot(__slots, " + nome + ", async () => `" + compilaTemplate(dentro) + "`)}";
          i = bloco === -1 ? s.length : bloco.fim;
          continue;
        }
        if (ehNomeComponente(s[i + 1] || "")) {
          const tag = leTag(s, i);
          const obj = propsParaObjeto(tag.props);
          if (tag.sozinho) {
            fora += "${await __comp(" + tag.nome + ", " + obj + ", {})}";
            i = tag.fim;
            continue;
          }
          const bloco = fimDoBloco(s, tag.nome, tag.fim);
          const dentro = bloco === -1 ? "" : s.slice(tag.fim, bloco.corpo[0]);
          fora += "${await __comp(" + tag.nome + ", " + obj + ", { default: async () => `" + compilaTemplate(dentro) + "` })}";
          i = bloco === -1 ? s.length : bloco.fim;
          continue;
        }
        // tag comum: os atributos podem ter `{}`, então passam pelo mesmo tratamento
        const tag = leTag(s, i);
        if (tag.props.some((p) => p.spread || /^\{/.test(p.bruto || "")) || tag.texto.includes("{")) {
          fora += "<" + tag.nome;
          for (const p of tag.props) {
            if (p.spread) { fora += "${__attrs(" + p.spread + ")}"; continue; }
            if (/^".*"$/.test(p.bruto) || p.bruto === "true") {
              fora += p.bruto === "true" ? " " + p.chave : " " + p.chave + "=" + '"' + literal(JSON.parse(p.bruto)) + '"';
            } else {
              fora += "${__attr(" + JSON.stringify(p.chave) + ", " + p.bruto + ")}";
            }
          }
          fora += tag.sozinho ? " />" : ">";
          i = tag.fim;
          continue;
        }
        fora += literal(tag.texto);
        i = tag.fim;
        continue;
      }
      fora += literal(c);
      i++;
    }
    return fora;
  }

  function compila(src, arquivo) {
    const { frente, corpo } = separa(src);
    const cabeca = importsParaRequire(frente);
    return `"use strict";
const { __t, __comp, __slot, __attr, __attrs, __seguro } = __astroRuntime;
module.exports.render = async function (Astro, __slots) {
  const __props = (Astro && Astro.props) || {};
${declaraProps(cabeca)}
${cabeca}
  return \`${compilaTemplate(corpo)}\`;
};
module.exports.__arquivo = ${JSON.stringify(arquivo || "")};
`;
  }

  // `const { title } = Astro.props` é o jeito do Astro; quem escreveu isso já está
  // servido. Isto só garante que `Astro.props` exista mesmo quando ninguém passou nada.
  function declaraProps() { return "  void __props;"; }

  // ---- runtime ----
  async function comp(fn, props, slots) {
    const alvo = fn && fn.render ? fn.render : fn;
    if (typeof alvo !== "function") throw new Error("componente não é um .astro nem uma função: " + String(fn));
    return await alvo({ props: props || {}, slots: slots || {} }, slots || {});
  }
  // O que vem de um slot já é HTML compilado, não dado: escapar aqui transformava a
  // página inteira do layout em `&lt;main&gt;` na tela.
  async function slot(slots, nome, padrao) {
    const f = slots && slots[nome || "default"];
    if (f) return await f();
    return padrao ? await padrao() : "";
  }
  function attr(nome, v) {
    if (v == null || v === false) return "";
    if (v === true) return " " + nome;
    if (nome === "class" && typeof v === "object") {
      const lista = Array.isArray(v) ? v : Object.keys(v).filter((k) => v[k]);
      return lista.length ? ' class="' + escapa(lista.join(" ")) + '"' : "";
    }
    if (nome === "style" && typeof v === "object" && !Array.isArray(v)) {
      const css = Object.keys(v).map((k) => k.replace(/[A-Z]/g, (m) => "-" + m.toLowerCase()) + ":" + v[k]).join(";");
      return css ? ' style="' + escapa(css) + '"' : "";
    }
    return " " + nome + '="' + escapa(v) + '"';
  }
  function attrs(obj) {
    if (!obj) return "";
    return Object.keys(obj).map((k) => attr(k, obj[k])).join("");
  }

  raiz.__astroRuntime = { __t: texto, __comp: comp, __slot: slot, __attr: attr, __attrs: attrs, __seguro: seguro };
  raiz.__astroCompila = compila;
  if (typeof module !== "undefined" && module.exports) module.exports = { compila, runtime: raiz.__astroRuntime, texto, escapa };
})(typeof globalThis !== "undefined" ? globalThis : this);
