import Foundation
import JavaScriptCore
import OdeteCore
import OdeteI18n

/// Resolução Node de módulos e leitura/transformação de fontes para o `require` do JS.
enum ModuleLoader {
    static let extensions = [".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".json", ".node"]

    static func install(_ rt: JSRuntime) {
        let h = rt.host
        let cache = rt.cacheDeModulos
        let resolve: @convention(block) (String, String) -> Any = { spec, from in
            if let r = resolveModule(spec, from: from, cache: cache) {
                return r
            }
            return ["error": "MODULE_NOT_FOUND", "message": "Cannot find module '\(spec)' from '\(from)'"]
        }
        h.setObject(resolve, forKeyedSubscript: "resolve" as NSString)

        // `loadModule(caminho, ehEntrada)`: o fonte pronto para o embrulho CJS do loader.js.
        let load: @convention(block) (String, Bool) -> Any = { [unowned rt] path, ehEntrada in
            if let e = rt.bloqueado(path) {
                return e
            }
            guard let data = FileManager.default.contents(atPath: path) else { return ["error": "ENOENT"] }
            do {
                return try fonte(String(decoding: data, as: UTF8.self), caminho: path, ehEntrada: ehEntrada, rt: rt)
            } catch let e as ErroDeCarga {
                return ["error": e.codigo, "message": e.mensagem]
            } catch {
                return ["error": "TRANSFORM", "message": error.localizedDescription]
            }
        }
        h.setObject(load, forKeyedSubscript: "loadModule" as NSString)
    }

    struct ErroDeCarga: Error {
        var codigo: String
        var mensagem: String
    }

    /// O fonte de um módulo como o loader.js o avalia.
    ///
    /// - ES/TS passa pelo esbuild (com cache em disco — ver `CacheDeTransformacao`).
    /// - O módulo de entrada com `async`/`await` passa pelo transformador de entrada, que
    ///   rebaixa o async para a Promise do runtime (só assim o `main()` que rejeita sem
    ///   `catch` é visto) e, se houver top-level await, embrulha o corpo numa função async.
    /// - CJS cru só troca `import(` por `__odete_import(` (ver `ReescritaDeImport`).
    static func fonte(_ original: String, caminho path: String, ehEntrada: Bool, rt: JSRuntime) throws -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let esm = ["ts", "tsx", "jsx", "mts", "cts"].contains(ext) || looksLikeESM(original, ext: ext)
            || (ext == "js" && pacoteEhModulo(path, rt: rt))
        if ehEntrada, let te = rt.transformEntrada, esm || usaAsync(original) {
            let cjs = try CacheDeTransformacao.transformar(
                original, caminho: path, tipo: "entrada", versao: rt.versaoDoTransformador
            ) { src, arquivo in
                interopDeModuloES(try transformarEntrada(src, arquivo, te))
            }
            return esm ? embrulharModuloES(cjs) : cjs
        }
        if esm {
            guard let t = rt.transform else {
                throw ErroDeCarga(codigo: "ESM", mensagem: tr(
                    "%1$@: módulos ES e TypeScript precisam do transformador (esbuild), que chega no marco 3",
                    "\(path)"
                ))
            }
            let cjs = try CacheDeTransformacao.transformar(
                original, caminho: path, tipo: "cjs", versao: rt.versaoDoTransformador
            ) { src, arquivo in
                interopDeModuloES(try t(src, arquivo))
            }
            return embrulharModuloES(cjs)
        }
        return ReescritaDeImport.reescrever(original) ?? original
    }

    /// O `"type": "module"` do package.json mais próximo: um `.js` ali é módulo ES, como no
    /// Node, mesmo minificado numa linha só (o `marked.esm.js`, que o teste por texto não via).
    static func pacoteEhModulo(_ arquivo: String, rt: JSRuntime) -> Bool {
        var dir = (arquivo as NSString).deletingLastPathComponent
        while true {
            let pj = (dir as NSString).appendingPathComponent("package.json")
            if tipo(pj) == .arquivo {
                return rt.cacheDeModulos.packageJSON(pj)["type"] as? String == "module"
            }
            let pai = (dir as NSString).deletingLastPathComponent
            if pai == dir || pai.isEmpty {
                return false
            }
            dir = pai
        }
    }

    /// O `import x from "pacote-esm"` num `.mjs` vira, no CJS do esbuild,
    /// `__toESM(require("pacote-esm"), 1)` — o "modo Node", em que `default` é o
    /// `module.exports` inteiro, como quando o Node importa CommonJS. Só que aqui o pacote ES
    /// também virou CJS, e o `default` dele sumia (chalk, mime, yargs, node-fetch: "x.default
    /// is not a function"). O módulo ES convertido leva a marca `odete.esm` (ver
    /// `embrulharModuloES`), e o `__toESM` passa a respeitá-la.
    static func interopDeModuloES(_ cjs: String) -> String {
        guard cjs.contains("isNodeMode || !mod || !mod.__esModule") else { return cjs }
        return cjs.replacingOccurrences(
            of: "isNodeMode || !mod || !mod.__esModule",
            with: #"isNodeMode && !(mod && mod[Symbol.for("odete.esm")]) || !mod || !mod.__esModule"#
        )
    }

    /// Há `async` ou `await` como palavra? Filtro barato: sem isso o módulo de entrada não
    /// precisa do esbuild.
    static func usaAsync(_ src: String) -> Bool {
        src.range(of: #"\b(async|await)\b"#, options: .regularExpression) != nil
    }

    /// O transformador de entrada, com o caminho do top-level await: o formato CJS não o
    /// aceita, então o módulo sai primeiro como ESM (só sem tipos), os imports sobem e o
    /// resto vai para dentro de uma função async. Módulo de entrada com `export` fica como
    /// está — exportar de dentro de uma função não existe.
    static func transformarEntrada(_ src: String, _ arquivo: String, _ te: TransformadorDeEntrada) throws -> String {
        do {
            return try te.paraCJS(src, arquivo)
        } catch {
            let msg = "\(error.localizedDescription)"
            guard msg.contains("Top-level await") else { throw error }
            let esm = try te.paraESM(src, arquivo)
            guard let embrulhado = embrulharTopLevelAwait(esm) else { throw error }
            return try te.paraCJS(embrulhado, arquivo)
        }
    }

    /// Separa as declarações `import` do topo (o esbuild as imprime na coluna 0, uma por
    /// linha ou em várias até o `;`) e põe o resto numa função async que é chamada na hora.
    /// Nil quando há `export` no topo.
    static func embrulharTopLevelAwait(_ esm: String) -> String? {
        var imports: [Substring] = []
        var corpo: [Substring] = []
        var dentroDeImport = false
        for linha in esm.split(separator: "\n", omittingEmptySubsequences: false) {
            if dentroDeImport {
                imports.append(linha)
                if linha.hasSuffix(";") {
                    dentroDeImport = false
                }
                continue
            }
            if linha.hasPrefix("export ") || linha.hasPrefix("export{") {
                return nil
            }
            if linha.hasPrefix("import ") || linha.hasPrefix("import{") || linha.hasPrefix("import\"")
                || linha.hasPrefix("import*")
            {
                imports.append(linha)
                dentroDeImport = !linha.hasSuffix(";")
                continue
            }
            corpo.append(linha)
        }
        return imports.joined(separator: "\n")
            + "\n(async () => {\n" + corpo.joined(separator: "\n")
            + "\n})().catch((e) => globalThis.__odete_reportUncaught(e));\n"
    }

    /// Um módulo ES convertido para CJS roda numa função própria dentro do embrulho CJS.
    ///
    /// O loader.js põe todo módulo em `function (exports, require, module, __filename,
    /// __dirname)`. Um módulo ES não tem essas variáveis, e é comum ele mesmo declará-las:
    /// `const __dirname = path.dirname(fileURLToPath(import.meta.url))` ou
    /// `const require = createRequire(import.meta.url)` — o vite, por exemplo. No mesmo
    /// escopo dos parâmetros isso é SyntaxError ("Cannot declare a const variable twice");
    /// numa função de dentro é só sombra. A seta mantém `this` e enxerga os parâmetros de
    /// fora, e fica na mesma linha para não deslocar a pilha. O `#!` que o esbuild preserva
    /// vira comentário, senão ficaria no meio do código.
    static func embrulharModuloES(_ cjs: String) -> String {
        let corpo = cjs.hasPrefix("#!") ? "//" + cjs.dropFirst(2) : cjs
        return "(() => {" + corpo + "\n})(); " + marcaDeModuloES
    }

    /// Marca o `module.exports` de um módulo ES convertido (ver `interopDeModuloES`).
    static let marcaDeModuloES = #"try { if (module.exports && typeof module.exports === "object" || typeof module.exports === "function") Object.defineProperty(module.exports, Symbol.for("odete.esm"), { value: true }); } catch {}"#

    static func looksLikeESM(_ src: String, ext: String) -> Bool {
        if ext == "mjs" {
            return true
        }
        if ext == "cjs" {
            return false
        }
        return src.range(of: #"^\s*(import\s|export\s)"#, options: [.regularExpression, .anchored]) != nil
            || src.range(
                of: #"\n\s*(import\s+[\w{*]|export\s+(default|const|function|class|let|var|\{|\*))"#,
                options: .regularExpression
            ) != nil
            // Minificado: `…;export{a as b}` no fim de uma linha longa.
            || src.range(of: #"[;}]export\s*\{[\w$, ]+\}\s*;?\s*(//.*)?$"#, options: .regularExpression) != nil
    }

    /// O caminho sai sempre normalizado (sem `./` nem `../` no meio). Antes cada ciclo de
    /// `require` relativo acumulava `././././` no nome, o cache do loader.js via um módulo
    /// novo a cada volta, e zod 4, yargs 17 e readable-stream 4 não carregavam.
    static func resolveModule(_ spec: String, from: String, cache: CacheDeModulos? = nil) -> String? {
        if spec.hasPrefix("node:") {
            return "node:" + String(spec.dropFirst(5))
        }
        return resolverSemNormalizar(spec, from: from, cache: cache).map(Confinamento.normalizar)
    }

    private static func resolverSemNormalizar(_ spec: String, from: String, cache: CacheDeModulos?) -> String? {
        let fromDir = (from as NSString).deletingLastPathComponent
        if spec == "." || spec == ".." || spec.hasPrefix("./") || spec.hasPrefix("../") || spec.hasPrefix("/") {
            let base = spec.hasPrefix("/") ? spec : (fromDir as NSString).appendingPathComponent(spec)
            return resolveFileOrDir(Confinamento.normalizar(base), cache: cache)
        }
        if spec.hasPrefix("#") {
            return resolverImports(spec, fromDir: fromDir, cache: cache)
        }
        // pacote
        let chave = spec + "\u{0}" + fromDir
        if let r = cache?.resolucao(chave) {
            return r
        }
        var dir = fromDir
        while true {
            let nm = (dir as NSString).appendingPathComponent("node_modules")
            if let (r, pacote) = resolvePackage(spec, in: nm, cache: cache) {
                cache?.guardar(chave, resultado: r, pacote: pacote)
                return r
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty {
                break
            }
            dir = parent
        }
        return nil
    }

    /// `#interno` pelo campo `imports` do package.json mais próximo (o chalk 5 importa
    /// `#ansi-styles` assim). O alvo é um caminho do pacote (`./…`) ou outro pacote.
    static func resolverImports(_ spec: String, fromDir: String, cache: CacheDeModulos?) -> String? {
        var dir = fromDir
        while true {
            let pj = (dir as NSString).appendingPathComponent("package.json")
            if tipo(pj) == .arquivo {
                // O package.json mais próximo decide sozinho, como no Node.
                guard let imports = packageJSON(pj, cache: cache)["imports"] as? [String: Any],
                      let alvo = casarSubpath(imports, key: spec).flatMap(pickCondition) else { return nil }
                if alvo.hasPrefix("./") || alvo.hasPrefix("../") {
                    return resolveFileOrDir(Confinamento.normalizar((dir as NSString).appendingPathComponent(alvo)), cache: cache)
                }
                return resolveModule(alvo, from: pj, cache: cache)
            }
            let pai = (dir as NSString).deletingLastPathComponent
            if pai == dir || pai.isEmpty {
                return nil
            }
            dir = pai
        }
    }

    /// Chave exata ou padrão com `*` num mapa de subpaths (`exports`, `imports`). Devolve o
    /// valor com o `*` já trocado nas strings.
    static func casarSubpath(_ map: [String: Any], key: String) -> Any? {
        if let v = map[key] {
            return v
        }
        // O padrão mais específico (prefixo mais longo) ganha, como no Node.
        let padroes = map.keys.filter { $0.contains("*") }.sorted { $0.count > $1.count }
        for pattern in padroes {
            let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, key.hasPrefix(parts[0]), key.hasSuffix(parts[1]),
                  key.count >= pattern.count - 1, let v = map[pattern] else { continue }
            let star = String(key.dropFirst(parts[0].count).dropLast(parts[1].count))
            return trocarEstrela(v, star)
        }
        return nil
    }

    private static func trocarEstrela(_ v: Any, _ star: String) -> Any {
        if let s = v as? String {
            return s.replacingOccurrences(of: "*", with: star)
        }
        if let a = v as? [Any] {
            return a.map { trocarEstrela($0, star) }
        }
        if let m = v as? [String: Any] {
            return m.mapValues { trocarEstrela($0, star) }
        }
        return v
    }

    static func resolveFileOrDir(_ base: String, cache: CacheDeModulos? = nil) -> String? {
        let t = tipo(base)
        if t == .arquivo {
            return base
        }
        for e in extensions where tipo(base + e) == .arquivo {
            return base + e
        }
        if t == nil, let ts = fonteTypeScript(de: base) {
            return ts
        }
        if t == .pasta {
            let pkg = (base as NSString).appendingPathComponent("package.json")
            if let main = packageJSON(pkg, cache: cache)["main"] as? String,
               let r = resolveFileOrDir((base as NSString).appendingPathComponent(main), cache: cache)
            {
                return r
            }
            for e in extensions where tipo((base as NSString).appendingPathComponent("index" + e)) == .arquivo {
                return (base as NSString).appendingPathComponent("index" + e)
            }
        }
        return nil
    }

    /// `./math.js` que no disco é `./math.ts`: o jeito que o TypeScript manda escrever imports
    /// com `moduleResolution: node16/nodenext`, e que o vite, o vitest e o tsx aceitam. Só vale
    /// quando o `.js` não existe — um `.js` de verdade sempre ganha.
    static func fonteTypeScript(de base: String) -> String? {
        let trocas = [".js": [".ts", ".tsx"], ".jsx": [".tsx"], ".mjs": [".mts"], ".cjs": [".cts"]]
        for (ext, alternativas) in trocas where base.hasSuffix(ext) {
            let semExt = String(base.dropLast(ext.count))
            for alt in alternativas where tipo(semExt + alt) == .arquivo {
                return semExt + alt
            }
        }
        return nil
    }

    /// Resolve `spec` dentro de uma pasta `node_modules`. Devolve o arquivo e o package.json
    /// que decidiu (para o cache saber quando a resposta envelhece).
    static func resolvePackage(_ spec: String, in nodeModules: String, cache: CacheDeModulos? = nil)
        -> (String, String)?
    {
        let parts = spec.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        let nameCount = spec.hasPrefix("@") ? 2 : 1
        guard parts.count >= nameCount else { return nil }
        let name = parts.prefix(nameCount).joined(separator: "/")
        let sub = parts.dropFirst(nameCount).joined(separator: "/")
        let pkgDir = (nodeModules as NSString).appendingPathComponent(name)
        guard tipo(pkgDir) != nil else { return nil }
        let pkgJSON = (pkgDir as NSString).appendingPathComponent("package.json")
        let j = packageJSON(pkgJSON, cache: cache)
        func achou(_ r: String?) -> (String, String)? {
            r.map { ($0, pkgJSON) }
        }
        if let exports = j["exports"] {
            let key = sub.isEmpty ? "." : "./" + sub
            if let target = resolveExports(exports, key: key),
               let r = resolveFileOrDir((pkgDir as NSString).appendingPathComponent(target), cache: cache)
            {
                return achou(r)
            }
        }
        if !sub.isEmpty {
            return achou(resolveFileOrDir((pkgDir as NSString).appendingPathComponent(sub), cache: cache))
        }
        for k in ["main", "module"] {
            if let m = j[k] as? String,
               let r = resolveFileOrDir((pkgDir as NSString).appendingPathComponent(m), cache: cache)
            {
                return achou(r)
            }
        }
        return achou(resolveFileOrDir(pkgDir, cache: cache))
    }

    /// package.json parseado (vazio se não existe ou não é JSON), pelo cache quando há um.
    static func packageJSON(_ caminho: String, cache: CacheDeModulos?) -> [String: Any] {
        if let cache {
            return cache.packageJSON(caminho)
        }
        return CacheDeModulos.ler(caminho)
    }

    enum Tipo { case arquivo, pasta }

    /// Arquivo, pasta ou nada, por `stat` (segue links, como o `fileExists` do FileManager, mas
    /// sem a ponte NSString dele: resolver um import faz até uma dúzia destas perguntas).
    static func tipo(_ caminho: String) -> Tipo? {
        var st = stat()
        guard stat(caminho, &st) == 0 else { return nil }
        return (st.st_mode & S_IFMT) == S_IFDIR ? .pasta : .arquivo
    }

    /// Campo `exports` com condições `node`, `require`, `import`, `default`; subpaths e `*`.
    static func resolveExports(_ exports: Any, key: String) -> String? {
        if let s = exports as? String {
            return key == "." ? s : nil
        }
        guard let map = exports as? [String: Any] else { return nil }
        let isConditions = map.keys.allSatisfy { !$0.hasPrefix(".") }
        if isConditions {
            return key == "." ? pickCondition(map) : nil
        }
        if let v = map[key] {
            return pickCondition(v)
        }
        for (pattern, v) in map where pattern.contains("*") {
            let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, key.hasPrefix(parts[0]), key.hasSuffix(parts[1]),
                  key.count >= pattern.count - 1 else { continue }
            let star = String(key.dropFirst(parts[0].count).dropLast(parts[1].count))
            if let t = pickCondition(v) {
                return t.replacingOccurrences(of: "*", with: star)
            }
        }
        return nil
    }

    static func pickCondition(_ v: Any) -> String? {
        if let s = v as? String {
            return s
        }
        if let arr = v as? [Any] {
            for x in arr {
                if let r = pickCondition(x) {
                    return r
                }
            }; return nil
        }
        guard let map = v as? [String: Any] else { return nil }
        for cond in ["node", "require", "import", "module", "default"] {
            if let x = map[cond], let r = pickCondition(x) {
                return r
            }
        }
        return nil
    }
}

/// Cache de resolução de um runtime; usado só na fila dele.
///
/// O dev server vive num JSEngine por horas e o esbuild chama `resolve` a cada import de cada
/// rebuild: reler e reparsear o package.json do `react` centenas de vezes por build era trabalho
/// jogado fora. Nada daqui é usado sem conferir, porque o mesmo runtime atravessa um
/// `npm install` ou uma edição do package.json: o package.json guardado é revalidado por um
/// `stat` (mtime, tamanho, inode) a cada uso, e uma resolução de pacote guardada só vale se o
/// package.json que a decidiu não mudou e o arquivo resolvido ainda existe. Resultado negativo
/// não é guardado — um pacote instalado no meio da sessão aparece na hora. Imports relativos
/// não passam por aqui: custam só alguns `stat`.
final class CacheDeModulos {
    struct Carimbo: Equatable {
        var segundos: Int
        var nanos: Int
        var tamanho: Int64
        var inode: UInt64

        init?(_ caminho: String) {
            var st = stat()
            guard stat(caminho, &st) == 0 else { return nil }
            segundos = st.st_mtimespec.tv_sec
            nanos = st.st_mtimespec.tv_nsec
            tamanho = st.st_size
            inode = st.st_ino
        }
    }

    private var pacotes: [String: (carimbo: Carimbo, json: [String: Any])] = [:]
    private var resolucoes: [String: (resultado: String, pacote: String, carimbo: Carimbo)] = [:]

    func packageJSON(_ caminho: String) -> [String: Any] {
        guard let c = Carimbo(caminho) else {
            pacotes[caminho] = nil
            return [:]
        }
        if let guardado = pacotes[caminho], guardado.carimbo == c {
            return guardado.json
        }
        let json = Self.ler(caminho)
        pacotes[caminho] = (c, json)
        return json
    }

    static func ler(_ caminho: String) -> [String: Any] {
        FileManager.default.contents(atPath: caminho)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    func resolucao(_ chave: String) -> String? {
        guard let r = resolucoes[chave] else { return nil }
        guard Carimbo(r.pacote) == r.carimbo, ModuleLoader.tipo(r.resultado) == .arquivo else {
            resolucoes[chave] = nil
            return nil
        }
        return r.resultado
    }

    func guardar(_ chave: String, resultado: String, pacote: String) {
        guard let c = Carimbo(pacote) else { return } // sem package.json não há o que conferir
        resolucoes[chave] = (resultado, pacote, c)
    }
}
