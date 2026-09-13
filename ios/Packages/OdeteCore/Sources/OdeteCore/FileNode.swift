import Foundation

/// Nó da árvore de arquivos. `path` é relativo à raiz do projeto, com "/" como separador.
public struct FileNode: Identifiable, Hashable, Sendable {
    public var path: String
    public var isDirectory: Bool
    public var children: [FileNode]?

    public var id: String { path }
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    public var ext: String {
        let n = name
        guard let dot = n.lastIndex(of: "."), dot != n.startIndex else { return "" }
        return String(n[n.index(after: dot)...]).lowercased()
    }

    public init(path: String, isDirectory: Bool, children: [FileNode]? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.children = children
    }

    /// Percorre a árvore em profundidade, só arquivos.
    public func allFiles() -> [FileNode] {
        if !isDirectory { return [self] }
        return (children ?? []).flatMap { $0.allFiles() }
    }
}
