import Clibgit2
import Foundation
import OdeteI18n

public extension Repository {
    func remotes() throws -> [Remote] {
        var arr = git_strarray()
        try check(git_remote_list(&arr, repo), "remotos")
        defer { git_strarray_dispose(&arr) }
        var out: [Remote] = []
        for i in 0 ..< arr.count {
            let name = String(cString: arr.strings[i]!)
            var r: OpaquePointer?
            guard git_remote_lookup(&r, repo, name) == 0 else { continue }
            let url = git_remote_url(r).map { String(cString: $0) } ?? ""
            git_remote_free(r)
            out.append(Remote(name: name, url: url))
        }
        return out
    }

    func addRemote(name: String, url: String) throws {
        var r: OpaquePointer?
        try check(git_remote_create(&r, repo, name, url), "adicionar remoto")
        git_remote_free(r)
    }

    func removeRemote(name: String) throws {
        try check(git_remote_delete(repo, name), "remover remoto")
    }

    func setRemoteURL(name: String, url: String) throws {
        try check(git_remote_set_url(repo, name, url), tr("url do remoto"))
    }

    /// (à frente, atrás) da branch atual em relação ao upstream. `nil` sem upstream.
    func aheadBehind() throws -> (ahead: Int, behind: Int)? {
        guard let b = try currentBranch(), let up = b.upstream else { return nil }
        var local = git_oid(), upstream = git_oid()
        try check(git_oid_fromstr(&local, b.target), "sha")
        guard git_reference_name_to_id(&upstream, repo, "refs/remotes/\(up)") == 0 else { return nil }
        var a = 0, bh = 0
        try check(git_graph_ahead_behind(&a, &bh, repo, &local, &upstream), "ahead/behind")
        return (a, bh)
    }

    func setUpstream(branch: String, to upstream: String) throws {
        var ref: OpaquePointer?
        try check(git_branch_lookup(&ref, repo, branch, GIT_BRANCH_LOCAL), "branch \(branch)")
        defer { git_reference_free(ref) }
        try check(git_branch_set_upstream(ref, upstream), "upstream")
    }

    // MARK: rede

    /// Abre o remoto para uma operação de rede.
    ///
    /// A libgit2 da Odete não tem SSH, então `git@github.com:dono/repo.git` falhava com
    /// "unsupported URL protocol". Com conta conectada para o host, a mesma operação vai
    /// pelo HTTPS equivalente — só nesta instância do remoto, sem mexer no `.git/config`
    /// de quem escolheu SSH. Sem conta, o erro diz o que fazer.
    internal func openRemote(_ name: String, credentials: Credentials?) throws -> OpaquePointer {
        var r: OpaquePointer?
        try check(git_remote_lookup(&r, repo, name), tr("remoto %1$@", name))
        guard let remote = r else {
            throw GitError(kind: .notFound, code: -1, message: tr("o remoto %1$@ não existe", name))
        }
        let url = git_remote_url(remote).map { String(cString: $0) }
        let pushURL = git_remote_pushurl(remote).map { String(cString: $0) }
        for (endereco, ehPush) in [(url, false), (pushURL, true)] {
            guard let endereco, Remote.isSSH(endereco) else { continue }
            guard credentials != nil, let https = Remote.httpsEquivalent(endereco) else {
                git_remote_free(remote)
                throw GitError.sshWithoutAccount(endereco)
            }
            let code = ehPush
                ? git_remote_set_instance_pushurl(remote, https)
                : git_remote_set_instance_url(remote, https)
            if code < 0 {
                git_remote_free(remote)
                try check(code, "url")
            }
        }
        return remote
    }

    static func clone(
        _ url: String,
        to dir: URL,
        credentials: Credentials? = nil,
        progress: (@Sendable (CloneProgress) -> Void)? = nil
    ) async throws -> Repository {
        Libgit2.start()
        // Clone de endereço SSH: vai pelo HTTPS quando há conta (ver `openRemote`).
        var endereco = url
        if Remote.isSSH(url) {
            guard credentials != nil, let https = Remote.httpsEquivalent(url) else {
                throw GitError.sshWithoutAccount(url)
            }
            endereco = https
        }
        let box = RemotePayload(credentials: credentials, progress: progress)
        let payload = Unmanaged.passRetained(box)
        defer { payload.release() }
        var opts = git_clone_options()
        git_clone_options_init(&opts, UInt32(GIT_CLONE_OPTIONS_VERSION))
        opts.fetch_opts.callbacks = remoteCallbacks(payload.toOpaque())
        var r: OpaquePointer?
        try check(git_clone(&r, endereco, dir.path, &opts), "clonar")
        guard let ptr = r else { throw GitError(kind: .other, code: -1, message: tr("clone sem repositório")) }
        let repo = Repository(repo: ptr, workdir: dir)
        try await repo.checkoutRemoteIfUnborn()
        return repo
    }

    /// Remoto sem HEAD (bare recém-criado): pega a única branch remota e faz checkout dela.
    func checkoutRemoteIfUnborn() throws {
        guard isUnborn() else { return }
        let remote = try branches().filter(\.isRemote)
        guard remote.count == 1, let rb = remote.first else { return }
        let local = rb.name.split(separator: "/").dropFirst().joined(separator: "/")
        try createBranch(local, at: rb.target, checkout: true)
        try setUpstream(branch: local, to: rb.name)
    }

    func fetch(
        remote: String = "origin",
        credentials: Credentials? = nil,
        progress: (@Sendable (CloneProgress) -> Void)? = nil
    ) throws {
        let r = try openRemote(remote, credentials: credentials)
        defer { git_remote_free(r) }
        let box = RemotePayload(credentials: credentials, progress: progress)
        let payload = Unmanaged.passRetained(box)
        defer { payload.release() }
        var opts = git_fetch_options()
        git_fetch_options_init(&opts, UInt32(GIT_FETCH_OPTIONS_VERSION))
        opts.callbacks = remoteCallbacks(payload.toOpaque())
        opts.prune = GIT_FETCH_PRUNE
        try check(git_remote_fetch(r, nil, &opts, "fetch"), "fetch")
    }

    /// fetch + merge do upstream da branch atual.
    func pull(remote: String = "origin", credentials: Credentials? = nil, author: Signature) throws -> MergeResult {
        try fetch(remote: remote, credentials: credentials)
        guard let b = try currentBranch() else {
            if git_repository_head_detached(repo) == 1 {
                throw GitError(
                    kind: .detachedHead,
                    code: -1,
                    message: tr("HEAD solto: troque para uma branch antes do pull")
                )
            }
            throw GitError(kind: .invalid, code: -1, message: tr("sem branch atual"))
        }
        let up = b.upstream ?? "\(remote)/\(b.name)"
        var ref: OpaquePointer?
        try check(git_reference_lookup(&ref, repo, "refs/remotes/\(up)"), "upstream \(up)")
        defer { git_reference_free(ref) }
        var their: OpaquePointer?
        try check(git_annotated_commit_from_ref(&their, repo, ref), "pull")
        defer { git_annotated_commit_free(their) }
        return try mergeAnnotated(their!, label: up, author: author)
    }

    /// Envia a branch atual (ou `branch`) e só então marca o upstream.
    ///
    /// Duas mentiras saíam daqui. Com HEAD solto, o nome caía em "main" e o push
    /// mandava a `main` local — não o que estava na tela. E a recusa do servidor
    /// (branch protegida, hook pre-receive) só chega pelo `push_update_reference`: sem
    /// olhar para ela, o painel dizia "push ok" e ainda marcava o upstream.
    func push(
        remote: String = "origin",
        branch: String? = nil,
        credentials: Credentials? = nil,
        setUpstream: Bool = true
    ) throws {
        let name: String
        if let branch, branch != "HEAD" {
            name = branch
        } else {
            if git_repository_head_detached(repo) == 1 {
                throw GitError.detached
            }
            guard !isUnborn(), let atual = try currentBranch()?.name else {
                throw GitError(kind: .invalid, code: -1, message: tr("ainda não há commit para enviar"))
            }
            name = atual
        }
        let r = try openRemote(remote, credentials: credentials)
        defer { git_remote_free(r) }
        let box = RemotePayload(credentials: credentials, progress: nil)
        let payload = Unmanaged.passRetained(box)
        defer { payload.release() }
        var opts = git_push_options()
        git_push_options_init(&opts, UInt32(GIT_PUSH_OPTIONS_VERSION))
        opts.callbacks = remoteCallbacks(payload.toOpaque())
        var arr = Self.strarray(["refs/heads/\(name):refs/heads/\(name)"])
        defer { Self.free(&arr) }
        try check(git_remote_push(r, &arr.array, &opts), "push")
        if let recusa = box.rejections.first {
            throw GitError.pushRejected(ref: recusa.ref, reason: recusa.reason, remoteText: box.remoteText)
        }
        if setUpstream {
            try? self.setUpstream(branch: name, to: "\(remote)/\(name)")
        }
    }

    /// O commit do HEAD já está em alguma branch remota? Desfazê-lo aqui reescreve
    /// história que o remoto já tem: o próximo push é recusado ou precisa de força.
    func headIsOnRemote() -> Bool {
        var head = git_oid()
        guard !isUnborn(), git_reference_name_to_id(&head, repo, "HEAD") == 0 else { return false }
        var remotas: [git_oid] = []
        var it: OpaquePointer?
        guard git_branch_iterator_new(&it, repo, GIT_BRANCH_REMOTE) == 0 else { return false }
        defer { git_branch_iterator_free(it) }
        var ref: OpaquePointer?
        var type = git_branch_t(0)
        while git_branch_next(&ref, &type, it) == 0 {
            var alvo = git_oid()
            if let nome = git_reference_name(ref), git_reference_name_to_id(&alvo, repo, nome) == 0 {
                remotas.append(alvo)
            }
            git_reference_free(ref)
        }
        guard !remotas.isEmpty else { return false }
        let r = remotas.withUnsafeBufferPointer { buf in
            git_graph_reachable_from_any(repo, &head, buf.baseAddress, buf.count)
        }
        return r == 1
    }
}
