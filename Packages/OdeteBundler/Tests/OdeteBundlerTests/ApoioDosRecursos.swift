import Foundation
import JavaScriptCore
@testable import OdeteBundler

/// O que os testes de resolução, alias, CSS, Tailwind e recursos do Vite repetem: um
/// projeto em pasta temporária, o `vite build`, o dev server e rodar o JS que saiu.
enum Apoio {
    static func raiz(_ nome: String) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "odete-\(nome)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    static func grava(_ texto: String, _ raiz: URL, _ caminho: String) throws {
        let u = raiz.appending(path: caminho)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try texto.write(to: u, atomically: true, encoding: .utf8)
    }

    static func le(_ raiz: URL, _ caminho: String) throws -> String {
        try String(contentsOf: raiz.appending(path: caminho), encoding: .utf8)
    }

    /// index.html com um script de entrada.
    static func pagina(_ raiz: URL, entrada: String = "/src/main.ts", cabeca: String = "") throws {
        try grava("""
        <!doctype html><html><head><title>t</title>\(cabeca)</head><body><div id="root"></div>
        <script type="module" src="\(entrada)"></script></body></html>
        """, raiz, "index.html")
    }

    /// O `vite build` e o JS e o CSS que saíram em dist/.
    static func viteBuild(_ raiz: URL) async throws -> (r: ViteBuild.Resultado, js: String, css: String) {
        let r = try await ViteBuild.rodar(raiz: raiz, esbuild: Esbuild(root: raiz))
        guard r.ok else { return (r, "", "") }
        var js = "", css = ""
        for g in r.gravados {
            if g.caminho.hasPrefix("dist/assets/index-"), g.caminho.hasSuffix(".js") {
                js = try le(raiz, g.caminho)
            }
            if g.caminho.hasPrefix("dist/assets/index-"), g.caminho.hasSuffix(".css") {
                css = try le(raiz, g.caminho)
            }
        }
        return (r, js, css)
    }

    /// Roda o JS (sem DOM) e devolve `globalThis.__r`.
    static func roda(_ js: String) -> (valor: String?, erro: String?) {
        let c = JSContext()!
        var erro: String?
        c.exceptionHandler = { _, e in erro = e?.toString() }
        c.evaluateScript("globalThis.console = { log() {}, warn() {}, error() {} };")
        c.evaluateScript(js)
        return (c.evaluateScript("globalThis.__r")?.toString(), erro)
    }

    static func porta() -> Int {
        20000 + Int.random(in: 0 ..< 20000)
    }

    static func texto(_ u: URL) async throws -> String {
        let (d, _) = try await URLSession.shared.data(from: u)
        return String(decoding: d, as: UTF8.self)
    }

    /// Espera até a condição valer (ou o prazo acabar).
    static func ate(_ prazo: Duration = .seconds(10), _ condicao: () async -> Bool) async -> Bool {
        let fim = ContinuousClock.now + prazo
        while ContinuousClock.now < fim {
            if await condicao() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return await condicao()
    }

    /// Um pacote em node_modules: package.json e arquivos.
    static func pacote(_ raiz: URL, _ nome: String, _ packageJSON: String, _ arquivos: [String: String]) throws {
        try grava(packageJSON, raiz, "node_modules/\(nome)/package.json")
        for (f, t) in arquivos {
            try grava(t, raiz, "node_modules/\(nome)/\(f)")
        }
    }

    /// Copia pacotes de verdade de um `node_modules` do Mac (variável de ambiente), para os
    /// testes que precisam do Sass, do Less ou do Tailwind de verdade. `false` se não há.
    static func copiaPacotes(_ variavel: String, _ nomes: [String], para raiz: URL) throws -> Bool {
        guard let origem = ProcessInfo.processInfo.environment[variavel], !origem.isEmpty else { return false }
        let fm = FileManager.default
        for n in nomes {
            let de = origem + "/" + n
            guard fm.fileExists(atPath: de) else { return false }
            let para = raiz.appending(path: "node_modules/" + n)
            try fm.createDirectory(at: para.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(atPath: de, toPath: para.path)
        }
        return true
    }
}
