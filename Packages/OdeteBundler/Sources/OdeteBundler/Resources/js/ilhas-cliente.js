// Runtime das ilhas, no navegador.
//
// O servidor marcou cada componente de cliente com `<odete-ilha data-ilha data-props>`.
// Aqui cada marca vira um `hydrateRoot` com o mesmo componente e as mesmas props, então
// o HTML que já está na tela passa a responder sem ser redesenhado.
//
// Filhos vindos do servidor (`<Providers>{children}</Providers>`) chegam como HTML dentro
// de `<odete-filhos>`: o componente recebe um nó que mostra esse HTML, e as ilhas que
// moram lá dentro são montadas como portais *da ilha de fora* — assim o contexto dela
// (QueryClient, tema, sessão) chega a elas, como chegaria no Next.
import * as ReactMod from "react";
import * as ReactDOMMod from "react-dom";
import { hydrateRoot } from "react-dom/client";
import { MODULOS } from "virtual:odete-ilhas";

const React = ReactMod.default || ReactMod;
const ReactDOM = ReactDOMMod.default || ReactDOMMod;
const h = React.createElement;

// Server Action recebida como prop: a função fica no servidor; daqui vai a chamada pela
// rede, com os argumentos que ela já tinha ligados (`bind`) na frente.
function acao(id, ligados) {
  return async (...args) => {
    const serializa = (v) => {
      if (typeof FormData !== "undefined" && v instanceof FormData) {
        const pares = [];
        v.forEach((x, k) => { if (typeof x === "string") pares.push([k, x]); });
        return { __odeteFormData: pares };
      }
      return v;
    };
    const r = await fetch("/@odete/acao/" + encodeURIComponent(id), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(ligados.concat(args).map(serializa)),
    });
    const t = await r.text();
    let j = null;
    try { j = JSON.parse(t); } catch (e) { throw new Error(t || "acao " + id + " falhou"); }
    if (!r.ok || j.erro) throw new Error(j && j.erro ? j.erro : "acao " + id + " falhou");
    if (j.redireciona) { location.assign(j.redireciona); return undefined; }
    return j.valor;
  };
}

// O slot desta ilha: o `<odete-filhos>` com esse nome cuja ilha mais próxima é ela (e
// não uma ilha que mora dentro dos filhos dela).
function htmlDoSlot(no, nome) {
  for (const f of no.querySelectorAll("odete-filhos")) {
    if (f.getAttribute("data-slot") === nome && f.parentElement.closest("odete-ilha") === no) return f.innerHTML;
  }
  return "";
}

// Desfaz as marcas que o servidor pôs nas props (next.js, `serializaProps`).
function revive(v, no) {
  if (Array.isArray(v)) return v.map((x) => revive(x, no));
  if (v && typeof v === "object") {
    if (typeof v.$odeteSlot === "string") return h(Filhos, { html: htmlDoSlot(no, v.$odeteSlot), nome: v.$odeteSlot });
    if ("$odeteData" in v) return v.$odeteData == null ? new Date(NaN) : new Date(v.$odeteData);
    if (typeof v.$odeteAcao === "string") return acao(v.$odeteAcao, v.ligados || []);
    if (v.$odeteErro) return Object.assign(new Error(v.$odeteErro.message), v.$odeteErro);
    const o = {};
    for (const k of Object.keys(v)) o[k] = revive(v[k], no);
    return o;
  }
  return v;
}

// O elemento que monta uma ilha: o componente com as props de volta. Lê tudo do DOM
// agora, antes que alguém mexa nele.
function elementoDaIlha(no) {
  const id = no.getAttribute("data-ilha");
  const C = MODULOS[id];
  if (!C) {
    console.warn("[odete] ilha sem módulo:", id);
    return null;
  }
  let dados = {};
  try { dados = JSON.parse(no.getAttribute("data-props") || "{}"); } catch (e) { dados = {}; }
  return h(C, revive(dados, no));
}

// A ilha é de quem? De ninguém (é raiz) ou da ilha dona do `<odete-filhos>` onde ela mora
// — desde que essa dona hidrate: dentro de uma ilha estática, quem monta é a raiz.
function donoDaIlha(no) {
  const f = no.parentElement && no.parentElement.closest("odete-filhos");
  if (!f) return null;
  const dona = f.closest("odete-ilha");
  if (!dona || dona.getAttribute("data-estatica")) return null;
  return f;
}

// O HTML que o servidor renderizou para os filhos. O React não mexe nele (é
// `dangerouslySetInnerHTML` com o mesmo texto que já estava lá); as ilhas de dentro viram
// portais daqui, então enxergam o contexto de quem está em volta.
//
// O objeto do `dangerouslySetInnerHTML` é o mesmo a cada render: o React 19 compara a
// prop pela identidade, e um objeto novo regravava o HTML a cada render do provider —
// apagando os portais que moram lá dentro.
function Filhos({ html, nome }) {
  const ref = React.useRef(null);
  const [alvos, setAlvos] = React.useState([]);
  const dentro = React.useMemo(() => ({ __html: html }), [html]);
  React.useLayoutEffect(() => {
    const achadas = [];
    for (const x of ref.current.querySelectorAll("odete-ilha[data-ilha]")) {
      if (x.getAttribute("data-estatica") || donoDaIlha(x) !== ref.current) continue;
      const el = elementoDaIlha(x);
      if (el) achadas.push({ no: x, el });
    }
    // O conteúdo de servidor delas sai antes do portal entrar, no mesmo quadro: a tela
    // não chega a mostrar a ilha vazia.
    for (const a of achadas) a.no.textContent = "";
    setAlvos(achadas);
  }, []);
  return h(
    React.Fragment,
    null,
    h("odete-filhos", { ref, "data-slot": nome, suppressHydrationWarning: true, dangerouslySetInnerHTML: dentro }),
    alvos.map((a, i) => ReactDOM.createPortal(a.el, a.no, "ilha" + i))
  );
}

for (const no of document.querySelectorAll("odete-ilha[data-ilha]")) {
  if (no.getAttribute("data-estatica") || donoDaIlha(no)) continue;
  const el = elementoDaIlha(no);
  if (!el) continue;
  try {
    hydrateRoot(no, el);
  } catch (e) {
    console.error("[odete] ilha não hidratou:", no.getAttribute("data-ilha"), e);
  }
}
