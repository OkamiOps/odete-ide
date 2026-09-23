// Aquecimento: o pacote de dependências feito antes de alguém pedir o dev server.
//
// O primeiro `npm run dev` de um projeto recém-instalado pagava tudo de uma vez: carregar
// o esbuild, fazer o build do app e empacotar o react-dom — uns oito segundos de CPU num
// iPad sem JIT. O pacote de dependências fica em disco (dependencias.js) e vale para
// qualquer servidor com a mesma base; então ele é feito aqui, logo depois do
// `npm install` (ou quando o Preview de um projeto JS aparece), e o servidor que subir
// depois acha tudo pronto.
//
// As chaves do pacote são os arquivos de node_modules que o app importa, e quem as diz é
// o build do app com as mesmas opções do servidor (`opcoesDoBundle` do devserver.js):
// mesmas chaves, mesmo nome de pacote guardado, e o servidor o acha pelo nome exato.
(function () {
  let contador = 0;

  globalThis.__devAquece = async function (root, soSeFaltar) {
    const fs = require("fs"), path = require("path");
    const inicio = Date.now();
    let nm;
    try { nm = fs.statSync(path.join(root, "node_modules")).isDirectory(); } catch (e) { nm = false; }
    if (!nm) return { feito: false, motivo: "sem-node-modules" };
    let html;
    try { html = fs.readFileSync(path.join(root, "index.html"), "utf8"); } catch (e) { return { feito: false, motivo: "sem-index" }; }
    const entradas = [];
    html.replace(/<script\s+type="module"\s+src="([^"]+)"\s*><\/script>/g, (m, s) => {
      if (!/^[a-z][a-z0-9+.-]*:/i.test(s)) entradas.push(s.replace(/^\//, ""));
      return m;
    });
    if (!entradas.length) return { feito: false, motivo: "sem-entradas" };
    const prefixo = "aquece" + ++contador + ":";
    const deps = globalThis.__depsCria(root, prefixo);
    if (soSeFaltar && deps.jaTemPacote()) return { feito: false, motivo: "ja-tinha" };
    const pedidas = new Set();
    try {
      for (const e of entradas) {
        if (!fs.existsSync(path.join(root, e))) continue;
        // `memoria: false`: o servidor que subir depois lê tudo de novo; guardar aqui
        // seria memória presa até alguém limpar.
        const r = await globalThis.__rebuild(prefixo + e, {
          root, entries: [e], format: "esm", platform: "browser", dev: true, outdir: "__odete",
          externalMissing: true, preempacota: true, banner: 'import "/@odete/deps.js";', memoria: false,
        });
        if (r.ok && r.dependencias) for (const d of r.dependencias) pedidas.add(d);
      }
      if (!pedidas.size) return { feito: false, motivo: "sem-pacotes" };
      const g = await deps.garante([...pedidas]);
      const est = deps.estatisticas();
      return {
        feito: !!g.ok, pacotes: pedidas.size, doDisco: est.depsDoDisco > 0, ms: Date.now() - inicio,
        erro: g.ok ? null : ((g.errors && g.errors[0] && g.errors[0].text) || "erro"),
      };
    } finally {
      await globalThis.__descartaContextos(prefixo);
    }
  };
})();
