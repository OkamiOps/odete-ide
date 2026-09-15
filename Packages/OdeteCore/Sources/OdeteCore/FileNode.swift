import Foundation

/// Nó da árvore de arquivos. `path` é relativo à raiz do projeto, com "/" como separador.
public struct FileNode: Identifiable, Hashable, Sendable {
    public var path: String
    public var isDirectory: Bool
    public var children: [FileNode]?

    public var id: String {
        path
    }

    public var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

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

    /// `nil` em `children` de uma pasta quer dizer "ainda não li o que tem aqui dentro",
    /// diferente de `[]`, que é pasta vazia. É assim que node_modules e .git entram na
    /// árvore sem custar a varredura inteira de uma vez.
    public var naoLido: Bool {
        isDirectory && children == nil
    }

    /// Nó daquele caminho, em qualquer profundidade.
    public func find(_ alvo: String) -> FileNode? {
        if path == alvo {
            return self
        }
        guard let children, alvo.hasPrefix(path.isEmpty ? "" : path + "/") else { return nil }
        for c in children {
            if let achado = c.find(alvo) {
                return achado
            }
        }
        return nil
    }

    /// Coloca os filhos recém-lidos no nó daquele caminho.
    @discardableResult
    public mutating func inserir(_ filhos: [FileNode], em alvo: String) -> Bool {
        if path == alvo {
            children = filhos
            return true
        }
        guard children != nil else { return false }
        for i in children!.indices where alvo == children![i].path || alvo
            .hasPrefix(children![i].path + "/")
        {
            if children![i].inserir(filhos, em: alvo) {
                return true
            }
        }
        return false
    }

    /// Percorre a árvore em profundidade, só arquivos.
    public func allFiles() -> [FileNode] {
        if !isDirectory {
            return [self]
        }
        return (children ?? []).flatMap { $0.allFiles() }
    }
}
