// Runtime das ilhas, no navegador.
//
// O servidor marcou cada componente de cliente com `<odete-ilha data-ilha data-props>`.
// Aqui cada marca vira um `hydrateRoot` com o mesmo componente e as mesmas props, então
// o HTML que já está na tela passa a responder sem ser redesenhado.
import * as ReactMod from "react";
import { hydrateRoot } from "react-dom/client";
import { MODULOS } from "virtual:odete-ilhas";

const React = ReactMod.default || ReactMod;

for (const no of document.querySelectorAll("odete-ilha[data-ilha]")) {
  if (no.getAttribute("data-estatica")) continue;
  const id = no.getAttribute("data-ilha");
  const carrega = MODULOS[id];
  if (!carrega) {
    console.warn("[odete] ilha sem módulo:", id);
    continue;
  }
  let props = {};
  try { props = JSON.parse(no.getAttribute("data-props") || "{}"); } catch (e) { props = {}; }
  try {
    hydrateRoot(no, React.createElement(carrega, props));
  } catch (e) {
    console.error("[odete] ilha não hidratou:", id, e);
  }
}
