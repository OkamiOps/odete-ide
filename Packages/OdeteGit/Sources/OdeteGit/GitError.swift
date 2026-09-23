import Clibgit2
import Foundation
import OdeteI18n

/// Erro do libgit2 com mensagem curta em português e classe para a interface decidir o que fazer.
public struct GitError: LocalizedError, Sendable, Equatable {
    public enum Kind: Sendable {
        case auth, network, conflict, notFound, exists, invalid, other
        /// O remoto recebeu o push e recusou a atualização: branch protegida, hook.
        case rejected
        /// O remoto tem commits que não estão aqui: falta pull antes do push.
        case nonFastForward
        /// Alterações locais seriam sobrescritas (checkout, merge, pull). Não é conflito
        /// de merge: não há nada para resolver, e sim algo para guardar antes.
        case localChanges
        /// Um arquivo `.lock` impede a operação, muitas vezes deixado por uma operação
        /// que morreu no meio.
        case locked
        /// HEAD fora de qualquer branch: um push não tem para onde ir.
        case detachedHead
        /// Remoto SSH: a libgit2 da Odete não tem SSH.
        case ssh
    }

    public var kind: Kind
    public var code: Int32
    public var message: String
    /// Os arquivos do erro: os que bloqueiam o checkout, ou o `.lock` que travou.
    public var paths: [String]

    public init(kind: Kind, code: Int32 = 0, message: String, paths: [String] = []) {
        self.kind = kind
        self.code = code
        self.message = message
        self.paths = paths
    }

    public var errorDescription: String? {
        message
    }

    /// Lê `git_error_last()` para o código devolvido.
    static func last(_ code: Int32, _ fallback: String = tr("erro no git")) -> GitError {
        let e = git_error_last()
        let klass = e?.pointee.klass ?? 0
        // Desde a 1.8 o `git_error_last()` nunca é nulo: sem erro guardado ele devolve
        // "no error", que não diz nada a ninguém. Aí vale o nome da operação.
        let raw = klass == GIT_ERROR_NONE.rawValue ? fallback
            : e.flatMap(\.pointee.message).map { String(cString: $0) } ?? fallback
        return classify(code: code, klass: klass, raw: raw)
    }

    /// Classe e frase em português a partir do código e do texto cru do libgit2.
    ///
    /// Antes só três frases eram traduzidas e o resto aparecia em inglês cru na tela
    /// ("cannot push non-fastforwardable reference"). Pior: tudo que tinha "conflict"
    /// no texto virava "há conflitos para resolver" — inclusive "1 conflict prevents
    /// checkout", que é uma alteração local no caminho, e o painel não mostrava
    /// conflito nenhum para resolver.
    static func classify(code: Int32, klass: Int32, raw: String) -> GitError {
        let s = raw.lowercased()
        func erro(_ kind: Kind, _ message: String, _ paths: [String] = []) -> GitError {
            GitError(kind: kind, code: code, message: message, paths: paths)
        }
        if code == GIT_ELOCKED.rawValue || s.contains("index is locked") || s.contains("failed to lock file") {
            let lock = lockPath(in: raw) ?? ".git/index.lock"
            return erro(.locked, lockMessage(lock), [lock])
        }
        if code == GIT_ENONFASTFORWARD.rawValue || s.contains("non-fastforwardable")
            || s.contains("not present locally")
        {
            return erro(.nonFastForward, tr("o remoto tem commits que você ainda não tem: faça pull antes do push"))
        }
        if s.contains("prevent") && s.contains("checkout") || s.contains("would be overwritten") {
            return erro(.localChanges, localChangesMessage([]))
        }
        if s.contains("unsupported url protocol") {
            return erro(.ssh, tr("a Odete não fala esse protocolo: use uma URL https://"))
        }
        if s.contains("status code: 404") || s.contains("repository not found") {
            return erro(
                .notFound,
                tr("repositório não encontrado no remoto: confira a URL e se a conta tem acesso a ele")
            )
        }
        if s.contains("status code: 403") {
            return erro(
                .auth,
                tr("o remoto negou acesso (403): a conta não tem permissão de escrita nesse repositório")
            )
        }
        if code == GIT_EAUTH.rawValue || code == GIT_ECERTIFICATE.rawValue || s.contains("authentication")
            || s.contains("status code: 401") || s.contains("no callback set")
        {
            return erro(.auth, tr("autenticação recusada pelo remoto"))
        }
        if klass == GIT_ERROR_NET.rawValue || klass == GIT_ERROR_HTTP.rawValue || klass == GIT_ERROR_SSL.rawValue
            || s.contains("could not resolve") || s.contains("failed to resolve") || s.contains("failed to connect")
            || s.contains("timed out") || s.contains("network is unreachable")
        {
            return erro(klass == GIT_ERROR_SSL.rawValue ? .auth : .network, tr("sem conexão com o remoto"))
        }
        if s.contains("cannot delete branch"), s.contains("current head") {
            return erro(.invalid, tr("não dá para apagar a branch atual: troque de branch antes"))
        }
        if s.contains("non-bare") {
            return erro(.invalid, tr("o remoto local não é bare: crie com git init --bare para poder enviar a ele"))
        }
        if code == GIT_ECONFLICT.rawValue || code == GIT_EMERGECONFLICT.rawValue || code == GIT_EUNMERGED.rawValue {
            return erro(.conflict, tr("há conflitos para resolver"))
        }
        if code == GIT_ENOTFOUND.rawValue {
            if s.hasPrefix("remote '"), s.contains("does not exist"), let nome = quoted(raw) {
                return erro(.notFound, tr("o remoto %1$@ não existe", nome))
            }
            if let nome = quoted(raw) {
                return erro(.notFound, tr("não encontrei %1$@", nome.replacingOccurrences(of: "refs/heads/", with: "")))
            }
            return erro(.notFound, raw)
        }
        if code == GIT_EEXISTS.rawValue {
            return erro(.exists, quoted(raw).map { tr("%1$@ já existe", $0) } ?? raw)
        }
        if code == GIT_EINVALIDSPEC.rawValue || code == GIT_EAMBIGUOUS.rawValue {
            return erro(.invalid, raw)
        }
        return erro(.other, raw)
    }

    /// O primeiro trecho entre aspas simples: o nome da branch, do remoto, do arquivo.
    static func quoted(_ s: String) -> String? {
        let partes = s.split(separator: "'", omittingEmptySubsequences: false)
        return partes.count >= 3 ? String(partes[1]) : nil
    }

    /// Caminho do `.lock` citado na mensagem ("failed to lock file '…/main.lock'").
    static func lockPath(in s: String) -> String? {
        guard let q = quoted(s), q.hasSuffix(".lock") else { return nil }
        return q
    }

    static func lockMessage(_ lock: String) -> String {
        let nome = lock.range(of: ".git/").map { String(lock[$0.lowerBound...]) } ?? lock
        return tr(
            "o repositório está travado por %1$@. Se nenhuma outra operação do git estiver rodando, o lock ficou órfão e pode ser removido.",
            nome
        )
    }

    static func localChangesMessage(_ paths: [String]) -> String {
        guard !paths.isEmpty else {
            return tr("suas alterações locais seriam sobrescritas: faça commit ou guarde em stash antes")
        }
        let lista = paths.prefix(3).joined(separator: ", ") + (paths.count > 3 ? "…" : "")
        return tr("suas alterações em %1$@ seriam sobrescritas: faça commit ou guarde em stash antes", lista)
    }

    /// Alterações locais no caminho, com os arquivos, para a interface oferecer o stash.
    static func localChanges(_ paths: [String], code: Int32 = GIT_ECONFLICT.rawValue) -> GitError {
        GitError(kind: .localChanges, code: code, message: localChangesMessage(paths), paths: paths)
    }

    /// Recusa do remoto a um push, com o motivo que ele deu e o que escreveu no
    /// canal lateral ("remote: error: GH006: Protected branch update failed…").
    static func pushRejected(ref: String, reason: String, remoteText: String) -> GitError {
        let branch = ref.replacingOccurrences(of: "refs/heads/", with: "")
        let tudo = (reason + "\n" + remoteText).lowercased()
        let detalhe = remoteDetail(remoteText) ?? reason
        if tudo.contains("protected branch") || tudo.contains("gh006") || tudo.contains("protected") {
            return GitError(kind: .rejected, code: -1, message: tr(
                "a branch %1$@ é protegida no remoto e recusou o push direto: envie numa branch nova e abra um pull request",
                branch
            ))
        }
        if tudo.contains("non-fast-forward") || tudo.contains("fetch first") || tudo.contains("stale info") {
            return GitError(kind: .nonFastForward, code: -1, message: tr(
                "o remoto tem commits que você ainda não tem: faça pull antes do push"
            ))
        }
        if tudo.contains("hook declined") || tudo.contains("pre-receive") {
            return GitError(kind: .rejected, code: -1, message: tr(
                "o remoto recusou o push de %1$@ (hook pre-receive): %2$@",
                branch,
                detalhe
            ))
        }
        return GitError(kind: .rejected, code: -1, message: tr(
            "o remoto recusou o push de %1$@: %2$@",
            branch,
            detalhe
        ))
    }

    /// As linhas de erro que o servidor mandou, sem o "remote:" e sem progresso.
    static func remoteDetail(_ texto: String) -> String? {
        let linhas = texto.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("remote:") ? String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) : $0 }
            .filter { !$0.isEmpty }
        let erros = linhas.filter { $0.lowercased().contains("error") }
        let escolhidas = erros.isEmpty ? linhas : erros
        return escolhidas.isEmpty ? nil : escolhidas.prefix(2).joined(separator: " ")
    }

    /// HEAD solto: sem branch, o push não sabe o que atualizar no remoto.
    static var detached: GitError {
        GitError(
            kind: .detachedHead,
            code: -1,
            message: tr(
                "HEAD solto: você não está em nenhuma branch, então não há o que enviar. Crie uma branch a partir daqui antes do push."
            )
        )
    }

    /// Remoto SSH sem conta para ir por HTTPS.
    static func sshWithoutAccount(_ url: String) -> GitError {
        let host = Remote.host(of: url) ?? url
        let https = Remote.httpsEquivalent(url)
        let msg = https.map {
            tr(
                "a Odete não fala SSH. Conecte uma conta para %1$@ em Ajustes → Contas (o envio vai por HTTPS) ou troque o remoto para %2$@",
                host,
                $0
            )
        } ?? tr("a Odete não fala SSH: use uma URL https://")
        return GitError(kind: .ssh, code: -1, message: msg)
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
