import Clibgit2
import Foundation

/// Erro do libgit2 com mensagem curta em português e classe para a interface decidir o que fazer.
public struct GitError: LocalizedError, Sendable, Equatable {
    public enum Kind: Sendable { case auth, network, conflict, notFound, exists, invalid, other }
    public var kind: Kind
    public var code: Int32
    public var message: String

    public var errorDescription: String? {
        message
    }

    /// Lê `git_error_last()` para o código devolvido.
    static func last(_ code: Int32, _ fallback: String = "erro no git") -> GitError {
        let raw = git_error_last().flatMap(\.pointee.message).map { String(cString: $0) } ?? fallback
        let kind: Kind
        switch code {
        case GIT_EAUTH.rawValue, GIT_ECERTIFICATE.rawValue: kind = .auth
        case GIT_ECONFLICT.rawValue, GIT_EMERGECONFLICT.rawValue, GIT_EUNMERGED.rawValue: kind = .conflict
        case GIT_ENOTFOUND.rawValue: kind = .notFound
        case GIT_EEXISTS.rawValue: kind = .exists
        case GIT_EINVALIDSPEC.rawValue, GIT_EAMBIGUOUS.rawValue: kind = .invalid
        default:
            let klass = git_error_last()?.pointee.klass ?? 0
            kind = klass == GIT_ERROR_NET.rawValue || klass == GIT_ERROR_HTTP.rawValue ? .network
                : klass == GIT_ERROR_SSL.rawValue ? .auth : .other
        }
        return GitError(kind: kind, code: code, message: translate(raw))
    }

    static func translate(_ s: String) -> String {
        if s.contains("authentication") || s.contains("401") {
            return "autenticação recusada pelo remoto"
        }
        if s.contains("could not resolve") || s.contains("failed to connect") {
            return "sem conexão com o remoto"
        }
        if s.contains("conflict") {
            return "há conflitos para resolver"
        }
        return s
    }
}

/// Executa uma chamada do libgit2 e lança `GitError` se falhar.
@discardableResult
func check(_ code: Int32, _ what: String = "git") throws -> Int32 {
    if code < 0 {
        throw GitError.last(code, what)
    }
    return code
}

/// Garante `git_libgit2_init()` uma vez por processo.
enum Libgit2 {
    private nonisolated(unsafe) static var started = false
    private static let lock = NSLock()
    static func start() {
        lock.lock(); defer { lock.unlock() }
        if !started {
            git_libgit2_init(); started = true
        }
    }
}
