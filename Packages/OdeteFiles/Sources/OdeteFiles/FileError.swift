import Foundation
import OdeteI18n

public enum FileError: LocalizedError, Equatable {
    case invalidName(String)
    case alreadyExists(String)
    case notFound(String)
    case outsideRoot(String)
    /// O conteúdo não é texto em UTF-8; abrir no editor destruiria o arquivo ao salvar.
    case naoEhTexto(String)
    /// Não deu para pôr na lixeira do projeto. Nada foi apagado.
    case lixeiraFalhou(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidName(n): tr("Nome inválido: %1$@", "\(n)")
        case let .alreadyExists(p): tr("Já existe: %1$@", "\(p)")
        case let .notFound(p): tr("Não encontrado: %1$@", "\(p)")
        case let .outsideRoot(p): tr("Fora do projeto: %1$@", "\(p)")
        case let .naoEhTexto(p): tr("%1$@ não é texto em UTF-8", "\(p)")
        case let .lixeiraFalhou(p): tr("Não deu para mover %1$@ para a lixeira; nada foi apagado.", "\(p)")
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
