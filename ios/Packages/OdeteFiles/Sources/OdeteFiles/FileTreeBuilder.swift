import Foundation
import OdeteCore

public enum FileTreeBuilder {
    /// Monta a árvore a partir da raiz. Pastas antes de arquivos, ordem alfabética sem distinguir caixa.
    /// Caminhos de ruído (`Ignore`) e `.odete` ficam de fora.
    public static func build(at root: URL) throws -> FileNode {
        FileNode(path: "", isDirectory: true, children: try children(of: root, prefix: ""))
    }

    static func children(of dir: URL, prefix: String) throws -> [FileNode] {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        var out: [FileNode] = []
        for item in items {
            let name = item.lastPathComponent
            let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if name == ".odete" || Ignore.isNoisePath(rel) { continue }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                out.append(FileNode(path: rel, isDirectory: true, children: try children(of: item, prefix: rel)))
            } else {
                out.append(FileNode(path: rel, isDirectory: false))
            }
        }
        return out.sorted(by: order)
    }

    static func order(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
