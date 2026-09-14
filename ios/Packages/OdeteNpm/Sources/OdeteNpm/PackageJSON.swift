import Foundation

/// Leitura e escrita mínima do package.json preservando os outros campos.
public struct PackageJSON: @unchecked Sendable {
    public var raw: [String: Any]
    public var url: URL

    public init(url: URL) {
        self.url = url
        raw = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    public var name: String { (raw["name"] as? String) ?? url.deletingLastPathComponent().lastPathComponent }
    public var dependencies: [String: String] { (raw["dependencies"] as? [String: String]) ?? [:] }
    public var devDependencies: [String: String] { (raw["devDependencies"] as? [String: String]) ?? [:] }
    public var scripts: [String: String] { (raw["scripts"] as? [String: String]) ?? [:] }
    public var allDependencies: [String: String] { dependencies.merging(devDependencies) { a, _ in a } }

    public mutating func set(_ name: String, range: String, dev: Bool) {
        var deps = (raw[dev ? "devDependencies" : "dependencies"] as? [String: String]) ?? [:]
        deps[name] = range
        raw[dev ? "devDependencies" : "dependencies"] = deps
        var other = (raw[dev ? "dependencies" : "devDependencies"] as? [String: String]) ?? [:]
        other.removeValue(forKey: name)
        raw[dev ? "dependencies" : "devDependencies"] = other.isEmpty ? nil : other
    }

    public mutating func remove(_ name: String) {
        for key in ["dependencies", "devDependencies"] {
            var deps = (raw[key] as? [String: String]) ?? [:]
            deps.removeValue(forKey: name)
            raw[key] = deps.isEmpty ? nil : deps
        }
    }

    public func save() throws {
        var ordered: [String: Any] = raw
        ordered = ordered.compactMapValues { $0 }
        let data = try JSONSerialization.data(withJSONObject: ordered, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
