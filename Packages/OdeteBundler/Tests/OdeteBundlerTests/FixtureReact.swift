import Darwin
import Foundation

/// Um projeto Vite + React de verdade no formato, sem rede.
///
/// O que pesa num rebuild é o `react-dom`: um megabyte de JS que o esbuild analisa de novo
/// a cada build do zero. Quem mede precisa desse peso, e teste não pode baixar pacote.
/// Então o React vem de uma cópia local quando `ODETE_REACT_DIR` aponta para um
/// `node_modules` que tenha `react`, `react-dom` e `scheduler` (medição realista), e na
/// falta dela é gerado aqui um par falso com o mesmo formato e peso parecido.
enum FixtureReact {
    static func projeto() throws -> URL {
        let fm = FileManager.default
        let u = fm.temporaryDirectory.appending(path: "odete-react-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: u.appending(path: "src/componentes/ui"), withIntermediateDirectories: true)
        let arquivos: [String: String] = [
            "package.json": #"{"name":"app","private":true,"type":"module","dependencies":{"react":"^19.2.0","react-dom":"^19.2.0"}}"#,
            "index.html": """
            <!doctype html>
            <html lang="pt-BR">
              <head><meta charset="UTF-8" /><title>app</title></head>
              <body><div id="root"></div><script type="module" src="/src/main.tsx"></script></body>
            </html>
            """,
            "src/main.tsx": """
            import { StrictMode } from "react";
            import { createRoot } from "react-dom/client";
            import { App } from "./App";
            import "./style.css";

            createRoot(document.getElementById("root")!).render(
              <StrictMode>
                <App />
              </StrictMode>,
            );
            """,
            "src/App.tsx": appTSX(rotulo: "cliques"),
            "src/componentes/Painel.tsx": """
            import { Cartao } from "./ui/Cartao";

            export function Painel({ n }: { n: number }) {
              return <section className="painel"><Cartao titulo="contagem" valor={n} /></section>;
            }

            """,
            "src/componentes/ui/Cartao.tsx": cartaoTSX(rotulo: "valor"),
            "src/style.css": ":root { font-family: system-ui, sans-serif; }\n.page { text-align: center; }\n",
            "README.md": "# app\n",
        ]
        for (caminho, corpo) in arquivos {
            try corpo.write(to: u.appending(path: caminho), atomically: true, encoding: .utf8)
        }
        let nm = u.appending(path: "node_modules")
        if reactDeVerdade, let origem = ProcessInfo.processInfo.environment["ODETE_REACT_DIR"] {
            try fm.createDirectory(at: nm, withIntermediateDirectories: true)
            for pacote in ["react", "react-dom", "scheduler"] {
                try fm.copyItem(atPath: origem + "/" + pacote, toPath: nm.appending(path: pacote).path)
            }
        } else {
            try reactFalso(em: nm)
        }
        return u
    }

    static var reactDeVerdade: Bool {
        guard let d = ProcessInfo.processInfo.environment["ODETE_REACT_DIR"], !d.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: d + "/react-dom/package.json")
    }

    /// O `App.tsx`. `importaNovo` acrescenta um import de pacote que o projeto ainda não
    /// usava (`react-dom` puro, além do `react-dom/client` do main): é o caso de quem começa
    /// a usar mais uma coisa de um pacote já instalado.
    static func appTSX(rotulo: String, importaNovo: Bool = false) -> String {
        """
        import { useState } from "react";
        \(importaNovo ? "import * as ReactDOM from \"react-dom\";" : "")
        import { Painel } from "./componentes/Painel";

        export function App() {
          const [n, setN] = useState(0);
          return (
            <main className="page">
              <h1>app\(importaNovo ? " {typeof ReactDOM} com-react-dom" : "")</h1>
              <p>React no iPad.</p>
              <button onClick={() => setN(n + 1)}>{n} \(rotulo)</button>
              <Painel n={n} />
            </main>
          );
        }

        """
    }

    /// Um componente dois níveis abaixo do App, para medir a edição longe da entrada.
    static func cartaoTSX(rotulo: String) -> String {
        """
        export function Cartao({ titulo, valor }: { titulo: string; valor: number }) {
          return <div className="cartao"><h2>{titulo}</h2><p>\(rotulo): {valor}</p></div>;
        }

        """
    }

    /// Um `react` e um `react-dom` falsos, CJS como os de verdade, com o `react-dom`
    /// inchado até perto de um megabyte de funções que o esbuild precisa analisar.
    static func reactFalso(em nm: URL) throws {
        let fm = FileManager.default
        let react = nm.appending(path: "react")
        let dom = nm.appending(path: "react-dom")
        try fm.createDirectory(at: react, withIntermediateDirectories: true)
        try fm.createDirectory(at: dom, withIntermediateDirectories: true)
        try #"{"name":"react","version":"19.0.0","main":"index.js","exports":{".":"./index.js","./jsx-dev-runtime":"./jsx-dev-runtime.js","./jsx-runtime":"./jsx-runtime.js"}}"#
            .write(to: react.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try """
        "use strict";
        exports.StrictMode = Symbol.for("react.strict_mode");
        exports.useState = function (v) { return [v, function () {}]; };
        exports.createElement = function (t, p) { return { t: t, p: p }; };
        """.write(to: react.appending(path: "index.js"), atomically: true, encoding: .utf8)
        try "exports.jsxDEV = function (t, p) { return { t: t, p: p }; }; exports.Fragment = 'f';"
            .write(to: react.appending(path: "jsx-dev-runtime.js"), atomically: true, encoding: .utf8)
        try "exports.jsx = function (t, p) { return { t: t, p: p }; }; exports.jsxs = exports.jsx; exports.Fragment = 'f';"
            .write(to: react.appending(path: "jsx-runtime.js"), atomically: true, encoding: .utf8)
        try #"{"name":"react-dom","version":"19.0.0","main":"index.js","exports":{".":"./index.js","./client":"./client.js"}}"#
            .write(to: dom.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try "module.exports = require('./client.js');".write(
            to: dom.appending(path: "index.js"), atomically: true, encoding: .utf8
        )
        var corpo = "\"use strict\";\nvar React = require('react');\nvar tabela = {};\n"
        for i in 0 ..< 1500 {
            corpo += """
            function trabalho\(i)(fibra, props, fila) {
              var estado = { id: \(i), nome: "no\(i)", filhos: [], pendente: null };
              for (var k = 0; k < (props && props.n || 3); k++) {
                if (fila && fila.length > k) { estado.filhos.push(fila[k] + \(i)); } else { estado.pendente = k; }
              }
              switch (fibra & 7) { case 0: return estado; case 1: return React.createElement("div", estado); default: tabela["t\(i)"] = estado; }
              return typeof props === "object" ? Object.assign({}, props, estado) : estado;
            }
            tabela.f\(i) = trabalho\(i);

            """
        }
        corpo += "exports.createRoot = function (el) { return { render: function (x) { tabela.raiz = x; } }; };\n"
        try corpo.write(to: dom.appending(path: "client.js"), atomically: true, encoding: .utf8)
    }

    /// CPU do processo inteiro (usuário + sistema), em segundos.
    static func cpu() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        let s = Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec)
        let us = Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec)
        return s + us / 1_000_000
    }

    /// Relógio e CPU gastos por um trecho.
    static func mede(_ corpo: () async throws -> Void) async rethrows -> (parede: Double, cpu: Double) {
        let c0 = cpu()
        let t0 = ContinuousClock.now
        try await corpo()
        let d = ContinuousClock.now - t0
        let parede = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return (parede, cpu() - c0)
    }
}
