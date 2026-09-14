import Foundation

/// package-lock.json v3 (só o que usamos).
public struct Lockfile: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var version: String
        public var resolved: String?
        public var integrity: String?
        public var dependencies: [String: String]
        public var optionalDependencies: [String: String]
        public var bin: [String: String]
        public var dev: Bool
        public var native: Bool
    }

    public var name: String
    /// chave: "node_modules/a" ou "node_modules/a/node_modules/b"
    public var packages: [String: Entry]

    public init(name: String, packages: [String: Entry] = [:]) { self.name = name; self.packages = packages }

    public static func load(_ url: URL) -> Lockfile? {
        guard let d = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], (j["lockfileVersion"] as? Int ?? 0) >= 2, let pk = j["packages"] as? [String: Any] else { return nil }
        var out = Lockfile(name: (j["name"] as? String) ?? "")
        for (k, v) in pk where k.hasPrefix("node_modules/") {
            guard let m = v as? [String: Any], let ver = m["version"] as? String else { continue }
            out.packages[k] = Entry(version: ver, resolved: m["resolved"] as? String, integrity: m["integrity"] as? String, dependencies: (m["dependencies"] as? [String: String]) ?? [:], optionalDependencies: (m["optionalDependencies"] as? [String: String]) ?? [:], bin: (m["bin"] as? [String: String]) ?? [:], dev: (m["dev"] as? Bool) ?? false, native: (m["odete:native"] as? Bool) ?? false)
        }
        return out
    }

    public func save(to url: URL, root: [String: Any]) throws {
        var pk: [String: Any] = ["": root]
        for (k, e) in packages {
            var m: [String: Any] = ["version": e.version]
            if let r = e.resolved { m["resolved"] = r }
            if let i = e.integrity { m["integrity"] = i }
            if !e.dependencies.isEmpty { m["dependencies"] = e.dependencies }
            if !e.optionalDependencies.isEmpty { m["optionalDependencies"] = e.optionalDependencies }
            if !e.bin.isEmpty { m["bin"] = e.bin }
            if e.dev { m["dev"] = true }
            if e.native { m["odete:native"] = true }
            pk[k] = m
        }
        let j: [String: Any] = ["name": name, "lockfileVersion": 3, "requires": true, "packages": pk]
        let data = try JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// Entrada que atende `name` a partir de um caminho ("node_modules/a" procura a/node_modules/name, depois node_modules/name).
    public func resolve(_ name: String, from: String) -> (key: String, entry: Entry)? {
        var base = from
        while true {
            let key = base.isEmpty ? "node_modules/\(name)" : "\(base)/node_modules/\(name)"
            if let e = packages[key] { return (key, e) }
            if base.isEmpty { return nil }
            guard let r = base.range(of: "/node_modules/", options: .backwards) else { base = ""; continue }
            base = String(base[..<r.lowerBound])
        }
    }
}
