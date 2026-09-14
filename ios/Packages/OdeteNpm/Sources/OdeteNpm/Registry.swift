import Foundation

public struct PackumentVersion: Sendable, Hashable {
    public var version: Version
    public var dependencies: [String: String]
    public var optionalDependencies: [String: String]
    public var peerDependencies: [String: String]
    public var bin: [String: String]
    public var tarball: String
    public var integrity: String?
    public var os: [String]
    public var cpu: [String]
    public var hasInstallScript: Bool
    public var deprecated: String?
}

public struct Packument: Sendable, Hashable {
    public var name: String
    public var distTags: [String: String]
    public var versions: [Version: PackumentVersion]

    public init(name: String, distTags: [String: String], versions: [Version: PackumentVersion]) {
        self.name = name; self.distTags = distTags; self.versions = versions
    }

    public static func parse(_ data: Data) throws -> Packument {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = j["name"] as? String else { throw NpmError.registry("packument inválido") }
        var out: [Version: PackumentVersion] = [:]
        for (k, v) in (j["versions"] as? [String: Any]) ?? [:] {
            guard let ver = Version(k), let m = v as? [String: Any], let dist = m["dist"] as? [String: Any],
                  let tar = dist["tarball"] as? String else { continue }
            func deps(_ key: String) -> [String: String] {
                (m[key] as? [String: String]) ?? [:]
            }
            var bin: [String: String] = [:]
            if let b = m["bin"] as? [String: String] {
                bin = b
            } else if let b = m["bin"] as? String {
                let short = name.split(separator: "/").last.map(String.init) ?? name
                bin = [short: b]
            }
            out[ver] = PackumentVersion(
                version: ver,
                dependencies: deps("dependencies"),
                optionalDependencies: deps("optionalDependencies"),
                peerDependencies: deps("peerDependencies"),
                bin: bin,
                tarball: tar,
                integrity: dist["integrity"] as? String,
                os: (m["os"] as? [String]) ?? [],
                cpu: (m["cpu"] as? [String]) ?? [],
                hasInstallScript: (m["hasInstallScript"] as? Bool) ?? false,
                deprecated: m["deprecated"] as? String
            )
        }
        return Packument(name: name, distTags: (j["dist-tags"] as? [String: String]) ?? [:], versions: out)
    }

    /// Escolhe a versão para uma faixa (ou tag).
    public func pick(_ spec: String) -> PackumentVersion? {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if let tagged = distTags[s.isEmpty ? "latest" : s], let v = Version(tagged), let pv = versions[v] {
            return pv
        }
        let range = SemverRange(s)
        if range.isAny, let latest = distTags["latest"], let v = Version(latest), let pv = versions[v] {
            return pv
        }
        guard let v = range.maxSatisfying(Array(versions.keys)) else { return nil }
        return versions[v]
    }
}

public enum NpmError: LocalizedError, Sendable {
    case registry(String), notFound(String), noVersion(String, String), tarball(String), io(String), native(String)
    public var errorDescription: String? {
        switch self {
        case let .registry(m): "registro: \(m)"
        case let .notFound(n): "pacote não encontrado: \(n)"
        case let .noVersion(n, r): "nenhuma versão de \(n) satisfaz \(r)"
        case let .tarball(m): "tarball: \(m)"
        case let .io(m): m
        case let .native(n): "\(n) tem código nativo e não roda no iPad"
        }
    }
}

/// De onde vêm packuments e tarballs.
public protocol RegistryClient: Sendable {
    func packument(_ name: String) async throws -> Packument
    func tarball(_ url: String, integrity: String?) async throws -> Data
}

/// registry.npmjs.org com cache em disco.
public struct HTTPRegistry: RegistryClient {
    public var base: URL
    public var cacheDir: URL
    public var session: URLSession

    public static func defaultCache() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(
            path: "odete-npm",
            directoryHint: .isDirectory
        )
    }

    public init(
        base: URL = URL(string: "https://registry.npmjs.org")!,
        cacheDir: URL = HTTPRegistry.defaultCache(),
        session: URLSession = .shared
    ) {
        self.base = base; self.cacheDir = cacheDir; self.session = session
    }

    /// URL do packument; escopos viram `@scope%2Fnome` (appending(path:) codificaria o `%` de novo).
    public func packumentURL(_ name: String) -> URL {
        let enc = name.hasPrefix("@") ? name.replacingOccurrences(of: "/", with: "%2F") : name
        let b = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        return URL(string: b + "/" + enc)!
    }

    public func packument(_ name: String) async throws -> Packument {
        var req = URLRequest(url: packumentURL(name))
        req.setValue("application/vnd.npm.install-v1+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 {
            throw NpmError.notFound(name)
        }
        guard (200 ..< 300).contains(code) else { throw NpmError.registry("HTTP \(code) para \(name)") }
        return try Packument.parse(data)
    }

    public func tarball(_ url: String, integrity: String?) async throws -> Data {
        let key = (integrity ?? url).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(
                of: "=",
                with: ""
            )
        let file = cacheDir.appending(path: key + ".tgz")
        if let d = try? Data(contentsOf: file) {
            return d
        }
        guard let u = URL(string: url) else { throw NpmError.tarball("URL inválida \(url)") }
        let (data, resp) = try await session.data(from: u)
        guard (200 ..< 300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0)
        else { throw NpmError.tarball("HTTP ao baixar \(url)") }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }
}
