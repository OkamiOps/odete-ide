import Foundation

public enum FileError: LocalizedError, Equatable {
    case invalidName(String)
    case alreadyExists(String)
    case notFound(String)
    case outsideRoot(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidName(n): "Nome inválido: \(n)"
        case let .alreadyExists(p): "Já existe: \(p)"
        case let .notFound(p): "Não encontrado: \(p)"
        case let .outsideRoot(p): "Fora do projeto: \(p)"
        }
    }
}

enum PathRules {
    static func validName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." {
            return false
        }
        if trimmed.contains("/") || trimmed.contains("\0") {
            return false
        }
        return true
    }

    static func validRelativePath(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") {
            return false
        }
        return !path.split(separator: "/").contains { $0 == ".." || $0.isEmpty }
    }
}
