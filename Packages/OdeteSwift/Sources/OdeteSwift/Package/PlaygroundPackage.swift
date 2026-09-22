import Foundation
import OdeteCore

/// O pacote `.swiftpm` (ou os .swift soltos) de um projeto.
public struct PlaygroundPackage: Sendable {
    public var root: URL
    public var name: String
    public var isPackage: Bool
    public var swiftFiles: [URL]

    /// Acha o primeiro `.swiftpm` do projeto; senão, usa os `.swift` da raiz.
    public static func find(in project: URL) -> PlaygroundPackage? {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil),
           let pkg = items.first(where: { $0.pathExtension == "swiftpm" })
        {
            return PlaygroundPackage(
                root: pkg,
                name: pkg.deletingPathExtension().lastPathComponent,
                isPackage: true,
                swiftFiles: files(under: pkg)
            )
        }
        let loose = files(under: project)
        return loose.isEmpty ? nil : PlaygroundPackage(
            root: project,
            name: project.lastPathComponent,
            isPackage: false,
            swiftFiles: loose
        )
    }

    static func files(under dir: URL) -> [URL] {
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        else { return out }
        while let u = e.nextObject() as? URL {
            let name = u.lastPathComponent
            if name == ".build" || name == "node_modules" || name == Ignore.modulosForaDaNuvem
                || name == ".git" || name == ".odete"
            {
                e.skipDescendants(); continue
            }
            if u.pathExtension == "swift", name != "Package.swift" {
                out.append(u)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Nome do app no Package.swift (`name:` do produto), se houver.
    public var displayName: String {
        guard isPackage, let s = try? String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8),
              let m = s.range(of: #"name:\s*"([^"]+)""#, options: .regularExpression) else { return name }
        return String(s[m]).replacingOccurrences(of: #"name:\s*""#, with: "", options: .regularExpression)
            .replacingOccurrences(
                of: "\"",
                with: ""
            )
    }

    /// Lê e parseia todos os arquivos.
    public func load(projectRoot: URL) -> [SwiftFile] {
        swiftFiles.compactMap { u in
            guard let src = try? String(contentsOf: u, encoding: .utf8) else { return nil }
            let rel = u.path
                .hasPrefix(projectRoot.path + "/") ? String(u.path.dropFirst(projectRoot.path.count + 1)) : u
                .lastPathComponent
            return Parser.parse(file: rel, source: src)
        }
    }
}
