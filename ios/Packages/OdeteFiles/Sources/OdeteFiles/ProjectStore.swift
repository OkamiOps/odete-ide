import Foundation
import OdeteCore

/// Projetos em `<root>/<name>`, com um `.odete/project.json` guardando id e datas.
public struct ProjectStore: Sendable {
    public let root: URL

    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Projects", directoryHint: .isDirectory)
    }

    public init(root: URL = ProjectStore.defaultRoot()) {
        self.root = root
    }

    public func url(for project: Project) -> URL {
        root.appending(path: project.name, directoryHint: .isDirectory)
    }

    private func metaURL(_ dir: URL) -> URL {
        dir.appending(path: ".odete/project.json")
    }

    public func list() throws -> [Project] {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var out: [Project] = []
        for dir in items where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try out.append(readOrCreateMeta(dir))
        }
        return out.sorted { ($0.lastOpenedAt ?? $0.createdAt) > ($1.lastOpenedAt ?? $1.createdAt) }
    }

    private func readOrCreateMeta(_ dir: URL) throws -> Project {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: metaURL(dir)), var p = try? dec.decode(Project.self, from: data) {
            p.name = dir.lastPathComponent
            return p
        }
        let created = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
        let p = Project(name: dir.lastPathComponent, createdAt: created)
        try writeMeta(p, at: dir)
        return p
    }

    private func writeMeta(_ p: Project, at dir: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: dir.appending(path: ".odete"), withIntermediateDirectories: true)
        try enc.encode(p).write(to: metaURL(dir), options: .atomic)
    }

    @discardableResult
    public func create(name: String, template: Template = .blank) throws -> Project {
        guard PathRules.validName(name) else { throw FileError.invalidName(name) }
        let dir = root.appending(path: name, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: dir.path) {
            throw FileError.alreadyExists(name)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (path, contents) in template.files(projectName: name) {
            let f = dir.appending(path: path)
            try FileManager.default.createDirectory(
                at: f.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: f, atomically: true, encoding: .utf8)
        }
        let p = Project(name: name)
        try writeMeta(p, at: dir)
        return p
    }

    public func rename(_ project: Project, to newName: String) throws -> Project {
        guard PathRules.validName(newName) else { throw FileError.invalidName(newName) }
        let from = url(for: project)
        let to = root.appending(path: newName, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: to.path) {
            throw FileError.alreadyExists(newName)
        }
        try FileManager.default.moveItem(at: from, to: to)
        var p = project
        p.name = newName
        try writeMeta(p, at: to)
        return p
    }

    @discardableResult
    public func duplicate(_ project: Project) throws -> Project {
        var candidate = "\(project.name) cópia"
        var n = 2
        while FileManager.default.fileExists(atPath: root.appending(path: candidate).path) {
            candidate = "\(project.name) cópia \(n)"
            n += 1
        }
        let to = root.appending(path: candidate, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: url(for: project), to: to)
        let p = Project(name: candidate)
        try writeMeta(p, at: to)
        return p
    }

    public func delete(_ project: Project) throws {
        let dir = url(for: project)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw FileError.notFound(project.name) }
        try FileManager.default.removeItem(at: dir)
    }

    public func touch(_ project: Project) throws -> Project {
        var p = project
        p.lastOpenedAt = .now
        try writeMeta(p, at: url(for: p))
        return p
    }
}
