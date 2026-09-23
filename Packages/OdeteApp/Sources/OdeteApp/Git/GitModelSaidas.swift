import Foundation
import OdeteGit
import OdeteI18n

// O que o painel oferece quando o git para no meio: a saída de cada erro (stash, lock)
// e o conflito sem marcadores, que se resolve com uma versão inteira.

public extension GitModel {
    /// O que o alerta de erro oferece além do OK.
    enum ErrorExit: Equatable, Sendable {
        /// Alteração local no caminho: guardar em stash e tentar de novo.
        case stash
        /// Um `.lock` órfão travando o repositório: apagar o lock.
        case removeLock(String)
    }
}

public extension GitModel {
    /// Erro do git para a tela, com a saída que ele tiver.
    internal func show(_ e: GitError, retry: (@Sendable (Repository) async throws -> String?)? = nil) {
        errorExit = nil
        retryAfterStash = nil
        switch e.kind {
        case .auth:
            error = e.message + " " + tr("Confira a conta em Ajustes → Contas.")
        case .localChanges:
            error = e.message
            // Do abort do merge não se oferece stash: guardar a mudança e abortar a
            // devolveria por cima do mesmo arquivo depois.
            if let retry, !mergeInProgress {
                retryAfterStash = retry
                errorExit = .stash
            }
        case .locked:
            error = e.message
            errorExit = .removeLock(e.paths.first ?? ".git/index.lock")
        default:
            error = e.message
        }
    }

    /// Guarda tudo em stash e repete a ação que esbarrou nas alterações locais.
    func stashAndRetry() {
        guard let retry = retryAfterStash else { return }
        let author = author
        retryAfterStash = nil
        errorExit = nil
        error = nil
        run("guardando…") { repo in
            try await repo.stashPush(message: tr("guardado pela Odete"), author: author)
            return try await retry(repo)
        }
    }

    /// Apaga o `.lock` que travou o repositório.
    func removeLock(_ path: String) {
        errorExit = nil
        error = nil
        run("removendo lock…") { try await $0.removeStaleLock(path); return tr("lock removido") }
    }

    /// Conflito sem marcadores (binário, apagado de um lado): fica uma versão inteira.
    func resolve(path: String, using side: ConflictSide) {
        run("resolvendo…") { try await $0.resolveConflict(path: path, using: side); return nil }
    }

    func resolveByDeleting(path: String) {
        run("resolvendo…") { try await $0.resolveConflictByDeleting(path: path); return nil }
    }

    /// Marca como resolvido do jeito que o arquivo está — depois de editar à mão. Com
    /// marcador de conflito ainda no texto, recusa: o commit gravaria os `<<<<<<<`.
    func markResolved(path: String) {
        let url = root.appending(path: path)
        run("resolvendo…") { repo in
            if let texto = try? String(contentsOf: url, encoding: .utf8),
               texto.split(separator: "\n").contains(where: { $0.hasPrefix("<<<<<<<") || $0.hasPrefix(">>>>>>>") })
            {
                throw GitError(
                    kind: .conflict,
                    code: -1,
                    message: tr("ainda há marcadores de conflito em %1$@", path)
                )
            }
            try await repo.stage([path])
            return nil
        }
    }
}
