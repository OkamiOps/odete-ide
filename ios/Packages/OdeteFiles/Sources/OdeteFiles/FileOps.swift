import Foundation
import OdeteCore

/// Operações sobre caminhos relativos à raiz do projeto.
public struct FileOps: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func url(_ rel: String) throws -> URL {
        guard rel.isEmpty || PathRules.validRelativePath(rel) else { throw FileError.outsideRoot(rel) }
        return rel.isEmpty ? root : root.appending(path: rel)
    }

    public func exists(_ rel: String) -> Bool {
        guard let u = try? url(rel) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    public func read(_ rel: String) throws -> String {
        let u = try url(rel)
        guard FileManager.default.fileExists(atPath: u.path) else { throw FileError.notFound(rel) }
        let data = try Data(contentsOf: u)
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ rel: String, _ text: String) throws {
        let u = try url(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    public func createFile(_ rel: String, contents: String = "") throws {
        if exists(rel) {
            throw FileError.alreadyExists(rel)
        }
        try write(rel, contents)
    }

    public func createDirectory(_ rel: String) throws {
        if exists(rel) {
            throw FileError.alreadyExists(rel)
        }
        try FileManager.default.createDirectory(at: url(rel), withIntermediateDirectories: true)
    }

    /// Renomeia o último componente, mantendo a pasta.
    public func rename(_ rel: String, to newName: String) throws -> String {
        guard PathRules.validName(newName) else { throw FileError.invalidName(newName) }
        let parent = rel.split(separator: "/").dropLast().joined(separator: "/")
        let dest = parent.isEmpty ? newName : "\(parent)/\(newName)"
        try move(rel, to: dest)
        return dest
    }

    public func move(_ rel: String, to dest: String) throws {
        guard exists(rel) else { throw FileError.notFound(rel) }
        if exists(dest) {
            throw FileError.alreadyExists(dest)
        }
        if dest.hasPrefix(rel + "/") {
            throw FileError.outsideRoot(dest)
        }
        let to = try url(dest)
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url(rel), to: to)
    }

    public func delete(_ rel: String) throws {
        guard exists(rel) else { throw FileError.notFound(rel) }
        try FileManager.default.removeItem(at: url(rel))
    }

    /// Data de modificação, para saber quando um arquivo aberto mudou por fora.
    public func modifiedAt(_ rel: String) -> Date? {
        guard let u = try? url(rel) else { return nil }
        return try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    public func isDirectory(_ rel: String) -> Bool {
        guard let u = try? url(rel) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Nome livre para "novo arquivo" dentro de uma pasta: `sem-titulo.txt`, `sem-titulo-2.txt`...
    public func freeName(in dir: String, base: String, ext: String) -> String {
        var n = 1
        while true {
            let name = n == 1 ? "\(base).\(ext)" : "\(base)-\(n).\(ext)"
            let rel = dir.isEmpty ? name : "\(dir)/\(name)"
            if !exists(rel) {
                return rel
            }
            n += 1
        }
    }
}
