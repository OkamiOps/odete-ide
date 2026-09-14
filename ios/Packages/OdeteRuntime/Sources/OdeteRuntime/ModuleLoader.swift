import Foundation
import JavaScriptCore
import OdeteCore

/// Resolução Node de módulos e leitura/transformação de fontes para o `require` do JS.
enum ModuleLoader {
    static let extensions = [".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".json", ".node"]

    static func install(_ rt: JSRuntime) {
        let h = rt.host
        let resolve: @convention(block) (String, String) -> Any = { spec, from in
            if let r = resolveModule(spec, from: from) {
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
                        "message": "\(path): módulos ES e TypeScript precisam do transformador (esbuild), que chega no marco 3",
                    ]
                }
                do { src = try t(src, path) } catch { return [
                    "error": "TRANSFORM",
                    "message": error.localizedDescription,
                ] }
            }
            return src
        }
        h.setObject(load, forKeyedSubscript: "loadModule" as NSString)
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

    static func resolveModule(_ spec: String, from: String) -> String? {
        let fromDir = (from as NSString).deletingLastPathComponent
        var s = spec
        if s.hasPrefix("node:") {
            return "node:" + String(s.dropFirst(5))
        }
        if s.hasPrefix("./") || s.hasPrefix("../") || s.hasPrefix("/") {
            let base = s.hasPrefix("/") ? s : (fromDir as NSString).appendingPathComponent(s)
            return resolveFileOrDir(base)
        }
        // pacote
        var dir = fromDir
        while true {
            let nm = (dir as NSString).appendingPathComponent("node_modules")
            if let r = resolvePackage(s, in: nm) {
                return r
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty {
                break
            }
            dir = parent
        }
        s = spec
        return nil
    }

    static func resolveFileOrDir(_ base: String) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: base, isDirectory: &isDir), !isDir.boolValue {
            return base
        }
        for e in extensions where fm.fileExists(atPath: base + e) {
            return base + e
        }
        if isDir.boolValue {
            let pkg = (base as NSString).appendingPathComponent("package.json")
            if let d = fm.contents(atPath: pkg), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                if let main = j["main"] as? String,
                   let r = resolveFileOrDir((base as NSString).appendingPathComponent(main))
                {
                    return r
                }
            }
            for e in extensions where fm.fileExists(atPath: (base as NSString).appendingPathComponent("index" + e)) {
                return (base as NSString).appendingPathComponent("index" + e)
            }
        }
        return nil
    }

    static func resolvePackage(_ spec: String, in nodeModules: String) -> String? {
        let parts = spec.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        let nameCount = spec.hasPrefix("@") ? 2 : 1
        guard parts.count >= nameCount else { return nil }
        let name = parts.prefix(nameCount).joined(separator: "/")
        let sub = parts.dropFirst(nameCount).joined(separator: "/")
        let pkgDir = (nodeModules as NSString).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: pkgDir) else { return nil }
        let pkgJSON = (pkgDir as NSString).appendingPathComponent("package.json")
        let j = FileManager.default.contents(atPath: pkgJSON)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let exports = j["exports"] {
            let key = sub.isEmpty ? "." : "./" + sub
            if let target = resolveExports(exports, key: key),
               let r = resolveFileOrDir((pkgDir as NSString).appendingPathComponent(target))
            {
                return r
            }
        }
        if !sub.isEmpty {
            return resolveFileOrDir((pkgDir as NSString).appendingPathComponent(sub))
        }
        for k in ["main", "module"] {
            if let m = j[k] as? String,
               let r = resolveFileOrDir((pkgDir as NSString).appendingPathComponent(m))
            {
                return r
            }
        }
        return resolveFileOrDir(pkgDir)
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
