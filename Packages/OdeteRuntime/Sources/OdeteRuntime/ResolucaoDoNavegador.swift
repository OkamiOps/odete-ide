import Foundation
import JavaScriptCore

/// Resolução de import para código que vai rodar no navegador — a do Vite e do esbuild,
/// não a do Node.
///
/// O `require` do runtime (ModuleLoader) resolve como o Node: condições `node` e `require`
/// primeiro, e o campo `browser` ignorado. Era ele que o bundle do dev server e do
/// `vite build` usava, e o que saía era a versão de servidor dos pacotes: o `axios`
/// entrava como `dist/node` (`require("http")`), o `uuid` como `dist/cjs`
/// (`require("crypto")`), e a página ficava branca com "Dynamic require of … is not
/// supported". Aqui:
///   - condições `browser`, `import` (ou `require`, para uma chamada `require`), `module` e
///     `default` no `exports` e no `imports`; `style` antes de todas para o `@import` de CSS
///     (o `@import "tailwindcss"` é o `index.css` do pacote, não o `lib.js`);
///   - sem `exports`, os campos `browser` (quando é texto), `module` e `main`, nessa ordem —
///     e `style` para CSS;
///   - o campo `browser` como mapa, dentro do pacote: `"./lib/adapters/http.js":
///     "./lib/helpers/null.js"` troca o arquivo, e `false` o apaga (módulo vazio). Vale
///     também para nome de pacote (`"fs": false`) importado de dentro dele;
///   - módulo do Node (`fs`, `node:path`) que nenhum pacote instalado substitui volta como
///     `embutido`: quem empacota decide (o bundler.js põe um módulo vazio, como o Vite).
///
/// As condições vão numa ordem fixa, como o ModuleLoader faz: o dicionário do
/// `JSONSerialization` não guarda a ordem das chaves do package.json. Só muda algo num
/// pacote que ponha `import` antes de `browser` no mesmo nível — e aí o que vem é a versão
/// de navegador, que é o que se quer aqui.
enum ResolucaoDoNavegador {
    enum Modo: String {
        case importacao = "import"
        case require
        case estilo = "style"

        var condicoes: [String] {
            switch self {
            case .importacao: ["browser", "import", "module", "default"]
            case .require: ["browser", "require", "module", "default"]
            case .estilo: ["style", "browser", "import", "module", "default"]
            }
        }
    }

    enum Achado: Equatable {
        case arquivo(String)
        /// O pacote diz que no navegador isto não existe (`"browser": { "x": false }`).
        case vazio
        /// Módulo do Node sem substituto instalado.
        case embutido(String)
    }

    static func install(_ rt: JSRuntime) {
        let cache = CacheDeModulos()
        let resolve: @convention(block) (String, String, String) -> Any = { spec, from, modo in
            switch resolver(spec, from: from, modo: Modo(rawValue: modo) ?? .importacao, cache: cache) {
            case let .arquivo(p)?: p
            case .vazio?: ["vazio": true]
            case let .embutido(n)?: ["embutido": n]
            case nil: ["error": "MODULE_NOT_FOUND", "message": "Cannot find module '\(spec)' from '\(from)'"]
            }
        }
        rt.host.setObject(resolve, forKeyedSubscript: "resolveNavegador" as NSString)
    }

    static func resolver(_ spec: String, from: String, modo: Modo, cache: CacheDeModulos? = nil) -> Achado? {
        if spec.hasPrefix("node:") {
            return .embutido(String(spec.dropFirst(5)))
        }
        let fromDir = (from as NSString).deletingLastPathComponent
        let relativo = spec.hasPrefix("./") || spec.hasPrefix("../") || spec.hasPrefix("/") || spec == "." || spec == ".."
        var alvo = spec
        // Nome de pacote trocado pelo campo `browser` de quem importa: `"fs": false` num
        // pacote que só usa `fs` no Node, ou `"ws": "./ws-navegador.js"`.
        if !relativo, let pacote = pacoteDe(fromDir, cache: cache),
           let troca = (pacote.json["browser"] as? [String: Any])?[spec]
        {
            if let t = troca as? Bool, !t {
                return .vazio
            }
            if let t = troca as? String {
                if t.hasPrefix("./") || t.hasPrefix("../") {
                    return achado(arquivo(t, em: pacote.dir, modo: modo, cache: cache), cache: cache)
                }
                alvo = t
            }
        }
        if relativo {
            let base = alvo.hasPrefix("/") ? alvo : (fromDir as NSString).appendingPathComponent(alvo)
            return achado(arquivo(base, em: nil, modo: modo, cache: cache), cache: cache)
        }
        if alvo.hasPrefix("#") {
            return achado(importsDoPacote(alvo, fromDir: fromDir, modo: modo, cache: cache), cache: cache)
        }
        var dir = fromDir
        while true {
            let nm = (dir as NSString).appendingPathComponent("node_modules")
            if let r = pacoteEm(alvo, nodeModules: nm, modo: modo, cache: cache) {
                return achado(r, cache: cache)
            }
            let pai = (dir as NSString).deletingLastPathComponent
            if pai == dir || pai.isEmpty {
                break
            }
            dir = pai
        }
        if embutidos.contains(alvo) {
            return .embutido(alvo)
        }
        return nil
    }

    /// Um arquivo (ou pasta) no disco, com a extensão implícita. Para CSS, `.css` também
    /// é implícita: `@import "./base"` é o `base.css`.
    private static func arquivo(_ caminho: String, em base: String?, modo: Modo, cache: CacheDeModulos?) -> String? {
        let abs = base.map { ($0 as NSString).appendingPathComponent(caminho) } ?? caminho
        let limpo = normaliza(abs)
        if modo == .estilo, (limpo as NSString).pathExtension.isEmpty,
           ModuleLoader.tipo(limpo + ".css") == .arquivo
        {
            return limpo + ".css"
        }
        return ModuleLoader.resolveFileOrDir(limpo, cache: cache)
    }

    /// O arquivo achado passa pelo mapa `browser` do pacote onde ele mora.
    private static func achado(_ r: String?, cache: CacheDeModulos?) -> Achado? {
        guard let r else { return nil }
        let arquivo = normaliza(r)
        guard let pacote = pacoteDe((arquivo as NSString).deletingLastPathComponent, cache: cache),
              let mapa = pacote.json["browser"] as? [String: Any], !mapa.isEmpty
        else { return .arquivo(arquivo) }
        for (chave, valor) in mapa where chave.hasPrefix("./") || chave.hasPrefix("../") || chave.contains("/") {
            let alvo = normaliza((pacote.dir as NSString).appendingPathComponent(chave))
            // A chave pode vir sem extensão (`"./lib/node"`) ou ser a pasta: vale o arquivo que
            // ela resolveria. Comparado pelo texto — um `stat` por chave, a cada arquivo do
            // pacote, pesaria num mapa de vinte entradas.
            guard arquivo.hasPrefix(alvo) else { continue }
            let resto = arquivo.dropFirst(alvo.count)
            guard resto.isEmpty || ModuleLoader.extensions.contains(where: { resto == $0 || resto == "/index" + $0 })
            else { continue }
            if let v = valor as? Bool, !v {
                return .vazio
            }
            if let v = valor as? String,
               let troca = ModuleLoader.resolveFileOrDir(
                   normaliza((pacote.dir as NSString).appendingPathComponent(v)),
                   cache: cache
               )
            {
                return .arquivo(troca)
            }
        }
        return .arquivo(arquivo)
    }

    /// `a/./b/../c` vira `a/c`, só pelo texto. O `standardizingPath` do NSString também
    /// tira o `/private` da frente de caminhos que existem sem ele, e o caminho que volta
    /// para o JS tem de ser o mesmo que o observador e o metafile usam.
    static func normaliza(_ caminho: String) -> String {
        var partes: [Substring] = []
        for p in caminho.split(separator: "/", omittingEmptySubsequences: true) {
            if p == "." {
                continue
            }
            if p == "..", let ultima = partes.last, ultima != ".." {
                partes.removeLast()
                continue
            }
            partes.append(p)
        }
        return (caminho.hasPrefix("/") ? "/" : "") + partes.joined(separator: "/")
    }

    /// O pacote que contém `dir`: a pasta do package.json mais perto, subindo.
    private static func pacoteDe(_ dir: String, cache: CacheDeModulos?) -> (dir: String, json: [String: Any])? {
        var d = dir
        while !d.isEmpty {
            let pj = (d as NSString).appendingPathComponent("package.json")
            if ModuleLoader.tipo(pj) == .arquivo {
                return (d, ModuleLoader.packageJSON(pj, cache: cache))
            }
            // A pasta de pacotes não é pacote: um arquivo solto nela não herda o do projeto.
            let nome = (d as NSString).lastPathComponent
            if nome == "node_modules" || nome == "node_modules.nosync" {
                return nil
            }
            let pai = (d as NSString).deletingLastPathComponent
            if pai == d {
                return nil
            }
            d = pai
        }
        return nil
    }

    /// `pacote` ou `pacote/sub` dentro de uma pasta `node_modules`.
    private static func pacoteEm(_ spec: String, nodeModules: String, modo: Modo, cache: CacheDeModulos?) -> String? {
        let partes = spec.split(separator: "/").map(String.init)
        let n = spec.hasPrefix("@") ? 2 : 1
        guard partes.count >= n else { return nil }
        let nome = partes.prefix(n).joined(separator: "/")
        let sub = partes.dropFirst(n).joined(separator: "/")
        let dir = (nodeModules as NSString).appendingPathComponent(nome)
        guard ModuleLoader.tipo(dir) == .pasta else { return nil }
        let j = ModuleLoader.packageJSON((dir as NSString).appendingPathComponent("package.json"), cache: cache)
        if let exports = j["exports"] {
            if let t = subcaminho(exports, chave: sub.isEmpty ? "." : "./" + sub, condicoes: modo.condicoes),
               let r = arquivo(t, em: dir, modo: modo, cache: cache)
            {
                return r
            }
        }
        if !sub.isEmpty {
            return arquivo(sub, em: dir, modo: modo, cache: cache)
        }
        let campos = modo == .estilo ? ["style", "main"] : ["browser", "module", "main"]
        for campo in campos {
            if let m = j[campo] as? String, let r = arquivo(m, em: dir, modo: modo, cache: cache) {
                return r
            }
        }
        return ModuleLoader.resolveFileOrDir(dir, cache: cache)
    }

    /// `#interno` pelo campo `imports` do package.json mais perto, com as mesmas condições.
    private static func importsDoPacote(
        _ spec: String,
        fromDir: String,
        modo: Modo,
        cache: CacheDeModulos?
    ) -> String? {
        guard let pacote = pacoteDe(fromDir, cache: cache), let imports = pacote.json["imports"],
              let t = subcaminho(imports, chave: spec, condicoes: modo.condicoes)
        else { return nil }
        if t.hasPrefix("./") || t.hasPrefix("../") {
            return arquivo(t, em: pacote.dir, modo: modo, cache: cache)
        }
        // `"#dep": "outro-pacote"`: um pacote de verdade, resolvido de lá.
        if case let .arquivo(r)? = resolver(
            t,
            from: (pacote.dir as NSString).appendingPathComponent("package.json"),
            modo: modo,
            cache: cache
        ) {
            return r
        }
        return nil
    }

    /// A entrada de `exports` (ou `imports`) para `chave`: exata, ou por padrão com `*`.
    static func subcaminho(_ mapa: Any, chave: String, condicoes: [String]) -> String? {
        if let s = mapa as? String {
            return chave == "." ? s : nil
        }
        if mapa is [Any] {
            return chave == "." ? condicao(mapa, condicoes) : nil
        }
        guard let m = mapa as? [String: Any] else { return nil }
        // Um mapa só de condições é o `"."`.
        if !chave.hasPrefix("#"), m.keys.allSatisfy({ !$0.hasPrefix(".") }) {
            return chave == "." ? condicao(m, condicoes) : nil
        }
        if let v = m[chave] {
            return condicao(v, condicoes)
        }
        // O padrão com o prefixo mais longo ganha, como no Node.
        var melhor: (prefixo: Int, alvo: String)?
        for (padrao, v) in m {
            let partes = padrao.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
            guard partes.count == 2, chave.hasPrefix(partes[0]), chave.hasSuffix(partes[1]),
                  chave.count >= padrao.count - 1 else { continue }
            if let atual = melhor, atual.prefixo >= partes[0].count {
                continue
            }
            let estrela = String(chave.dropFirst(partes[0].count).dropLast(partes[1].count))
            if let t = condicao(v, condicoes) {
                melhor = (partes[0].count, t.replacingOccurrences(of: "*", with: estrela))
            }
        }
        return melhor?.alvo
    }

    static func condicao(_ v: Any, _ condicoes: [String]) -> String? {
        if let s = v as? String {
            return s
        }
        if let lista = v as? [Any] {
            for x in lista {
                if let r = condicao(x, condicoes) {
                    return r
                }
            }
            return nil
        }
        guard let m = v as? [String: Any] else { return nil }
        for c in condicoes {
            if let x = m[c], let r = condicao(x, condicoes) {
                return r
            }
        }
        return nil
    }

    /// Os módulos do Node. Sem pacote instalado com o mesmo nome (o `buffer` e o `events`
    /// do npm são para o navegador), no navegador eles não existem.
    static let embutidos: Set<String> = [
        "assert", "assert/strict", "async_hooks", "buffer", "child_process", "cluster", "console", "constants",
        "crypto", "dgram", "diagnostics_channel", "dns", "dns/promises", "domain", "events", "fs", "fs/promises",
        "http", "http2", "https", "inspector", "module", "net", "os", "path", "path/posix", "path/win32",
        "perf_hooks", "process", "punycode", "querystring", "readline", "readline/promises", "repl", "stream",
        "stream/consumers", "stream/promises", "stream/web", "string_decoder", "sys", "timers", "timers/promises",
        "tls", "trace_events", "tty", "url", "util", "util/types", "v8", "vm", "wasi", "worker_threads", "zlib",
    ]
}
