import Foundation
import OdeteCore

public enum FileTreeBuilder {
    /// Monta a árvore a partir da raiz. Pastas antes de arquivos, ordem alfabética sem distinguir caixa.
    /// Caminhos de ruído (`Ignore`) e `.odete` ficam de fora.
    public static func build(at root: URL, ocultos: Bool = false) throws -> FileNode {
        try FileNode(path: "", isDirectory: true, children: children(of: root, prefix: "", ocultos: ocultos))
    }

    /// Lê um nível só. Com `ocultos`, node_modules, .git, dist e companhia entram na
    /// lista mas ficam por ler: são milhares de arquivos que ninguém quer esperar para
    /// abrir o projeto, e a pessoa só paga a leitura se abrir a pasta.
    public static func children(of dir: URL, prefix: String, ocultos: Bool = false) throws -> [FileNode] {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        var out: [FileNode] = []
        for item in items {
            let name = item.lastPathComponent
            let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let pesada = name == ".odete" || Ignore.isNoisePath(rel)
            if pesada, !ocultos {
                continue
            }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let filhos = pesada ? nil : try children(of: item, prefix: rel, ocultos: ocultos)
                out.append(FileNode(path: rel, isDirectory: true, children: filhos))
            } else {
                out.append(FileNode(path: rel, isDirectory: false))
            }
        }
        return out.sorted(by: order)
    }

    static func order(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.isDirectory != b.isDirectory {
            return a.isDirectory
        }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
