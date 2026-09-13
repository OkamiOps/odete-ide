import Clibgit2
import Foundation

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
        try check(git_remote_set_url(repo, name, url), "url do remoto")
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

    static func clone(
        _ url: String,
        to dir: URL,
        credentials: Credentials? = nil,
        progress: (@Sendable (CloneProgress) -> Void)? = nil
    ) async throws -> Repository {
        Libgit2.start()
        let box = RemotePayload(credentials: credentials, progress: progress)
        let payload = Unmanaged.passRetained(box)
        defer { payload.release() }
        var opts = git_clone_options()
        git_clone_options_init(&opts, UInt32(GIT_CLONE_OPTIONS_VERSION))
        opts.fetch_opts.callbacks = remoteCallbacks(payload.toOpaque())
        var r: OpaquePointer?
        try check(git_clone(&r, url, dir.path, &opts), "clonar")
        guard let ptr = r else { throw GitError(kind: .other, code: -1, message: "clone sem repositório") }
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
        var r: OpaquePointer?
        try check(git_remote_lookup(&r, repo, remote), "remoto \(remote)")
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
        guard let b = try currentBranch() else { throw GitError(kind: .invalid, code: -1, message: "sem branch atual") }
        let up = b.upstream ?? "\(remote)/\(b.name)"
        var ref: OpaquePointer?
        try check(git_reference_lookup(&ref, repo, "refs/remotes/\(up)"), "upstream \(up)")
        defer { git_reference_free(ref) }
        var their: OpaquePointer?
        try check(git_annotated_commit_from_ref(&their, repo, ref), "pull")
        defer { git_annotated_commit_free(their) }
        return try mergeAnnotated(their!, label: up, author: author)
    }

    func push(
        remote: String = "origin",
        branch: String? = nil,
        credentials: Credentials? = nil,
        setUpstream: Bool = true
    ) throws {
        let name = try branch ?? currentBranch()?.name ?? headBranchName() ?? "main"
        var r: OpaquePointer?
        try check(git_remote_lookup(&r, repo, remote), "remoto \(remote)")
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
        if setUpstream {
            try? self.setUpstream(branch: name, to: "\(remote)/\(name)")
        }
    }
}
