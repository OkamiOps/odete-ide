import Foundation
import JavaScriptCore
import OdeteCore
import OdeteI18n

/// Resolução Node de módulos e leitura/transformação de fontes para o `require` do JS.
enum ModuleLoader {
    static let extensions = [".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".json", ".node"]

    static func install(_ rt: JSRuntime) {
        let h = rt.host
        let cache = CacheDeModulos()
        let resolve: @convention(block) (String, String) -> Any = { spec, from in
            if let r = resolveModule(spec, from: from, cache: cache) {
                return r
            }
            return ["error": "MODULE_NOT_FOUND", "message": "Cannot find module '\(spec)' from '\(from)'"]
        }
        h.setObject(resolve, forKeyedSubscript: "resolve" as NSString)

        let load: @convention(block) (String) -> Any = { [unowned rt] path in
            guard let data = FileManager.default.contents(atPath: path) else { return ["error": "ENOENT"] }
            var src = String(decoding: data, as: UTF8.self)
            let ext = (path as NSString).pathExtension.lowercased()
            let needsTransform = ["ts", "tsx", "jsx", "mts", "cts"].contains(ext) || looksLikeESM(src, ext: ext)
            if needsTransform {
                guard let t = rt.transform else {
                    return [
                        "error": "ESM",
                        "message": tr(
                            "%1$@: módulos ES e TypeScript precisam do transformador (esbuild), que chega no marco 3",
                            "\(path)"
                        ),
                    ]
                }
                do { src = try t(src, path) } catch { return [
                    "error": "TRANSFORM",
                    "message": error.localizedDescription,
                ] }
                src = embrulharModuloES(src)
            }
            return src
        }
        h.setObject(load, forKeyedSubscript: "loadModule" as NSString)
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
        return "return (() => {" + corpo + "\n})();"
    }

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
    }

    static func resolveModule(_ spec: String, from: String, cache: CacheDeModulos? = nil) -> String? {
        let fromDir = (from as NSString).deletingLastPathComponent
        if spec.hasPrefix("node:") {
            return "node:" + String(spec.dropFirst(5))
        }
        if spec.hasPrefix("./") || spec.hasPrefix("../") || spec.hasPrefix("/") {
            let base = spec.hasPrefix("/") ? spec : (fromDir as NSString).appendingPathComponent(spec)
            return resolveFileOrDir(base, cache: cache)
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
