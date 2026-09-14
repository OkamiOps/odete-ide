import Foundation

/// Import map para esm.sh, usado quando um pacote não pôde ser instalado ou não há node_modules.
public enum EsmFallback {
    public static func importMap(packages: [String: String], dev: Bool = true) -> String {
        var imports: [String: String] = [:]
        for (name, version) in packages {
            let v = version.trimmingCharacters(in: CharacterSet(charactersIn: "^~=v "))
            let base = "https://esm.sh/\(name)@\(v.isEmpty ? "latest" : v)\(dev ? "?dev" : "")"
            imports[name] = base
            imports[name + "/"] = "https://esm.sh/\(name)@\(v.isEmpty ? "latest" : v)/"
        }
        let data = try! JSONSerialization.data(
            withJSONObject: ["imports": imports],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// Pacotes do package.json sem pasta em node_modules.
    public static func missing(project: URL) -> [String: String] {
        let pkg = PackageJSON(url: project.appending(path: "package.json"))
        var out: [String: String] = [:]
        for (n, r) in pkg.dependencies
            where !FileManager.default
            .fileExists(atPath: project.appending(path: "node_modules/\(n)/package.json").path)
        {
            out[n] = r
        }
        return out
    }
}
