import Clibgit2
import Foundation
import OdeteCore

/// Um repositório git. Todas as chamadas ao libgit2 passam por este actor.
public actor Repository {
    nonisolated(unsafe) let repo: OpaquePointer
    public let workdir: URL

    private init(repo: OpaquePointer, workdir: URL) {
        self.repo = repo
        self.workdir = workdir
    }

    deinit { git_repository_free(repo) }

    public static func isRepository(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: ".git").path)
    }

    public static func open(_ url: URL) throws -> Repository {
        Libgit2.start()
        var r: OpaquePointer?
        try check(git_repository_open(&r, url.path), "abrir repositório")
        return Repository(repo: r!, workdir: url)
    }

    public static func initialize(at url: URL, defaultBranch: String = "main") throws -> Repository {
        Libgit2.start()
        var r: OpaquePointer?
        var opts = git_repository_init_options()
        git_repository_init_options_init(&opts, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
        opts.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue
        try defaultBranch.withCString { cstr in
            opts.initial_head = cstr
            try check(git_repository_init_ext(&r, url.path, &opts), "iniciar repositório")
        }
        return Repository(repo: r!, workdir: url)
    }

    // MARK: HEAD e branch atual

    public func headSha() throws -> String? {
        var oid = git_oid()
        let code = git_reference_name_to_id(&oid, repo, "HEAD")
        if code == GIT_ENOTFOUND.rawValue || code == GIT_EUNBORNBRANCH.rawValue { return nil }
        try check(code, "HEAD")
        return Self.hex(oid)
    }

    public func isUnborn() -> Bool { git_repository_head_unborn(repo) == 1 }

    public func currentBranch() throws -> Branch? {
        var ref: OpaquePointer?
        let code = git_repository_head(&ref, repo)
        if code == GIT_EUNBORNBRANCH.rawValue || code == GIT_ENOTFOUND.rawValue {
            return nil
        }
        try check(code, "branch atual")
        defer { git_reference_free(ref) }
        return branch(from: ref!, isHead: true)
    }

    /// Nome da branch em HEAD mesmo quando ainda não há commits ("main").
    public func headBranchName() -> String? {
        var ref: OpaquePointer?
        guard git_reference_lookup(&ref, repo, "HEAD") == 0 else { return nil }
        defer { git_reference_free(ref) }
        guard let sym = git_reference_symbolic_target(ref) else { return nil }
        let full = String(cString: sym)
        return full.hasPrefix("refs/heads/") ? String(full.dropFirst(11)) : full
    }

    func branch(from ref: OpaquePointer, isHead: Bool) -> Branch? {
        var namePtr: UnsafePointer<CChar>?
        guard git_branch_name(&namePtr, ref) == 0, let namePtr else { return nil }
        let name = String(cString: namePtr)
        let isRemote = git_reference_is_remote(ref) == 1
        var oid = git_oid()
        git_reference_name_to_id(&oid, repo, git_reference_name(ref))
        var upstream: String?
        if !isRemote {
            var up: OpaquePointer?
            if git_branch_upstream(&up, ref) == 0, let up {
                var upName: UnsafePointer<CChar>?
                if git_branch_name(&upName, up) == 0, let upName { upstream = String(cString: upName) }
                git_reference_free(up)
            }
        }
        return Branch(name: name, isRemote: isRemote, isHead: isHead, target: Self.hex(oid), upstream: upstream)
    }

    // MARK: status

    public func status() throws -> [StatusEntry] {
        var opts = git_status_options()
        git_status_options_init(&opts, UInt32(GIT_STATUS_OPTIONS_VERSION))
        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue
            | GIT_STATUS_OPT_SORT_CASE_INSENSITIVELY.rawValue
        var list: OpaquePointer?
        try check(git_status_list_new(&list, repo, &opts), "status")
        defer { git_status_list_free(list) }
        let n = git_status_list_entrycount(list)
        var out: [StatusEntry] = []
        for i in 0 ..< n {
            guard let e = git_status_byindex(list, i)?.pointee else { continue }
            let s = e.status.rawValue
            var staged: Change?
            var unstaged: Change?
            if s & GIT_STATUS_INDEX_NEW.rawValue != 0 { staged = .added }
            if s & GIT_STATUS_INDEX_MODIFIED.rawValue != 0 { staged = .modified }
            if s & GIT_STATUS_INDEX_DELETED.rawValue != 0 { staged = .deleted }
            if s & GIT_STATUS_INDEX_RENAMED.rawValue != 0 { staged = .renamed }
            if s & GIT_STATUS_INDEX_TYPECHANGE.rawValue != 0 { staged = .typeChange }
            if s & GIT_STATUS_WT_NEW.rawValue != 0 { unstaged = .untracked }
            if s & GIT_STATUS_WT_MODIFIED.rawValue != 0 { unstaged = .modified }
            if s & GIT_STATUS_WT_DELETED.rawValue != 0 { unstaged = .deleted }
            if s & GIT_STATUS_WT_RENAMED.rawValue != 0 { unstaged = .renamed }
            if s & GIT_STATUS_WT_TYPECHANGE.rawValue != 0 { unstaged = .typeChange }
            if s & GIT_STATUS_CONFLICTED.rawValue != 0 { unstaged = .conflicted }
            let delta = e.index_to_workdir?.pointee ?? e.head_to_index?.pointee
            guard let delta else { continue }
            let path = String(cString: delta.new_file.path ?? delta.old_file.path)
            if staged == nil, unstaged == nil { continue }
            out.append(StatusEntry(path: path, staged: staged, unstaged: unstaged))
        }
        return out
    }

    // MARK: índice

    /// Índice do repositório; quem chama libera com `git_index_free`.
    func index() throws -> OpaquePointer {
        var idx: OpaquePointer?
        try check(git_repository_index(&idx, repo), "índice")
        return idx!
    }

    func withIndex<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var idx: OpaquePointer?
        try check(git_repository_index(&idx, repo), "índice")
        defer { git_index_free(idx) }
        return try body(idx!)
    }

    public func stage(_ paths: [String]) throws {
        try withIndex { idx in
            for p in paths {
                let full = workdir.appending(path: p).path
                if FileManager.default.fileExists(atPath: full) {
                    try check(git_index_add_bypath(idx, p), "stage \(p)")
                } else {
                    try check(git_index_remove_bypath(idx, p), "stage \(p)")
                }
            }
            try check(git_index_write(idx), "gravar índice")
        }
    }

    public func stageAll() throws {
        let entries = try status()
        try stage(entries.filter { $0.unstaged != nil && $0.unstaged != .ignored }.map(\.path))
    }

    public func unstage(_ paths: [String]) throws {
        var head: OpaquePointer?
        let code = git_revparse_single(&head, repo, "HEAD")
        defer { git_object_free(head) }
        if code == GIT_ENOTFOUND.rawValue || isUnborn() {
            try withIndex { idx in
                for p in paths { git_index_remove_bypath(idx, p) }
                try check(git_index_write(idx), "gravar índice")
            }
            return
        }
        try check(code, "HEAD")
        var arr = Self.strarray(paths)
        defer { Self.free(&arr) }
        try check(git_reset_default(repo, head, &arr.array), "unstage")
    }

    public func unstageAll() throws {
        try unstage(try status().filter { $0.staged != nil }.map(\.path))
    }

    /// Descarta alterações do workdir (volta ao índice). Untracked é apagado.
    public func discard(_ paths: [String]) throws {
        let st = try status()
        var tracked: [String] = []
        for p in paths {
            if st.first(where: { $0.path == p })?.unstaged == .untracked {
                try? FileManager.default.removeItem(at: workdir.appending(path: p))
            } else {
                tracked.append(p)
            }
        }
        guard !tracked.isEmpty else { return }
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        var arr = Self.strarray(tracked)
        defer { Self.free(&arr) }
        opts.paths = arr.array
        try check(git_checkout_index(repo, nil, &opts), "descartar")
    }

    // MARK: commit

    @discardableResult
    public func commit(message: String, author: Signature) throws -> Commit {
        let tree = try withIndex { idx -> git_oid in
            var oid = git_oid()
            try check(git_index_write_tree(&oid, idx), "árvore")
            return oid
        }
        var treeObj: OpaquePointer?
        var treeOid = tree
        try check(git_tree_lookup(&treeObj, repo, &treeOid), "árvore")
        defer { git_tree_free(treeObj) }
        var sig: UnsafeMutablePointer<git_signature>?
        try check(git_signature_now(&sig, author.name, author.email), "autor")
        defer { git_signature_free(sig) }
        var parent: OpaquePointer?
        if !isUnborn() {
            var head = git_oid()
            try check(git_reference_name_to_id(&head, repo, "HEAD"), "HEAD")
            try check(git_commit_lookup(&parent, repo, &head), "pai")
        }
        defer { git_commit_free(parent) }
        var oid = git_oid()
        let parentsArr: [OpaquePointer?] = parent == nil ? [] : [parent]
        let buf = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: max(parentsArr.count, 1))
        defer { buf.deallocate() }
        for (i, p) in parentsArr.enumerated() { buf[i] = p }
        let code = git_commit_create(&oid, repo, "HEAD", sig, sig, "UTF-8", message, treeObj, parentsArr.count, buf)
        try check(code, "commit")
        return try lookupCommit(Self.hex(oid))
    }

    /// Volta HEAD um commit, mantendo as alterações no índice (reset --soft).
    public func undoLastCommit() throws {
        var head: OpaquePointer?
        try check(git_revparse_single(&head, repo, "HEAD~1"), "commit anterior")
        defer { git_object_free(head) }
        try check(git_reset(repo, head, GIT_RESET_SOFT, nil), "desfazer commit")
    }

    public func lookupCommit(_ sha: String) throws -> Commit {
        var oid = git_oid()
        try check(git_oid_fromstr(&oid, sha), "sha")
        var c: OpaquePointer?
        try check(git_commit_lookup(&c, repo, &oid), "commit")
        defer { git_commit_free(c) }
        return Self.commit(from: c!)
    }

    static func commit(from c: OpaquePointer) -> Commit {
        let id = hex(git_commit_id(c).pointee)
        let full = git_commit_message(c).map { String(cString: $0) } ?? ""
        let summary = git_commit_summary(c).map { String(cString: $0) } ?? ""
        let body = git_commit_body(c).map { String(cString: $0) } ?? ""
        let a = git_commit_author(c).pointee
        let sig = Signature(name: String(cString: a.name), email: String(cString: a.email))
        let date = Date(timeIntervalSince1970: TimeInterval(git_commit_time(c)))
        var parents: [String] = []
        for i in 0 ..< git_commit_parentcount(c) {
            if let p = git_commit_parent_id(c, i) { parents.append(hex(p.pointee)) }
        }
        _ = full
        return Commit(id: id, summary: summary, body: body, author: sig, date: date, parents: parents)
    }

    public func log(limit: Int = 200, from: String? = nil) throws -> [Commit] {
        if isUnborn() { return [] }
        var walk: OpaquePointer?
        try check(git_revwalk_new(&walk, repo), "log")
        defer { git_revwalk_free(walk) }
        git_revwalk_sorting(walk, GIT_SORT_TIME.rawValue)
        if let from {
            var oid = git_oid()
            try check(git_oid_fromstr(&oid, from), "sha")
            try check(git_revwalk_push(walk, &oid), "log")
        } else {
            try check(git_revwalk_push_head(walk), "log")
        }
        var out: [Commit] = []
        var oid = git_oid()
        while out.count < limit, git_revwalk_next(&oid, walk) == 0 {
            var c: OpaquePointer?
            guard git_commit_lookup(&c, repo, &oid) == 0 else { continue }
            out.append(Self.commit(from: c!))
            git_commit_free(c)
        }
        return out
    }

    // MARK: utilidades

    static func hex(_ oid: git_oid) -> String {
        var o = oid
        var buf = [CChar](repeating: 0, count: Int(GIT_OID_MAX_HEXSIZE) + 1)
        git_oid_tostr(&buf, buf.count, &o)
        return String(cString: buf)
    }

    struct StrArray {
        var array: git_strarray
        var storage: [UnsafeMutablePointer<CChar>?]
    }

    static func strarray(_ strings: [String]) -> StrArray {
        var storage = strings.map { strdup($0) as UnsafeMutablePointer<CChar>? }
        let arr = storage.withUnsafeMutableBufferPointer { git_strarray(strings: $0.baseAddress, count: $0.count) }
        return StrArray(array: arr, storage: storage)
    }

    static func free(_ a: inout StrArray) {
        for p in a.storage { Foundation.free(p) }
        a.storage.removeAll()
    }
}
