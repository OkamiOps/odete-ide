import Clibgit2
import Foundation

public extension Repository {
    func branches(includeRemote: Bool = true) throws -> [Branch] {
        var it: OpaquePointer?
        try check(git_branch_iterator_new(&it, repo, includeRemote ? GIT_BRANCH_ALL : GIT_BRANCH_LOCAL), "branches")
        defer { git_branch_iterator_free(it) }
        let head = try currentBranch()
        var out: [Branch] = []
        var ref: OpaquePointer?
        var type = git_branch_t(0)
        while git_branch_next(&ref, &type, it) == 0 {
            if let b = branch(from: ref!, isHead: false) {
                var bb = b
                bb.isHead = !b.isRemote && b.name == head?.name
                if !(bb.isRemote && bb.name.hasSuffix("/HEAD")) { out.append(bb) }
            }
            git_reference_free(ref)
        }
        return out.sorted { a, b in
            if a.isRemote != b.isRemote { return !a.isRemote }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func createBranch(_ name: String, at sha: String? = nil, checkout: Bool = true) throws {
        var target: OpaquePointer?
        try check(git_revparse_single(&target, repo, sha ?? "HEAD"), "commit base")
        defer { git_object_free(target) }
        var c: OpaquePointer?
        try check(git_commit_lookup(&c, repo, git_object_id(target)), "commit base")
        defer { git_commit_free(c) }
        var ref: OpaquePointer?
        try check(git_branch_create(&ref, repo, name, c, 0), "criar branch")
        git_reference_free(ref)
        if checkout { try self.checkout(name) }
    }

    func checkout(_ name: String) throws {
        let refName = name.contains("/") && (try? branches()).map { $0.contains { $0.isRemote && $0.name == name } } == true
            ? "refs/remotes/\(name)" : "refs/heads/\(name)"
        var obj: OpaquePointer?
        try check(git_revparse_single(&obj, repo, refName), "branch \(name)")
        defer { git_object_free(obj) }
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        try check(git_checkout_tree(repo, obj, &opts), "trocar branch")
        try check(git_repository_set_head(repo, refName), "HEAD")
    }

    func deleteBranch(_ name: String) throws {
        var ref: OpaquePointer?
        try check(git_branch_lookup(&ref, repo, name, GIT_BRANCH_LOCAL), "branch \(name)")
        defer { git_reference_free(ref) }
        try check(git_branch_delete(ref), "apagar branch")
    }

    func renameBranch(_ name: String, to newName: String) throws {
        var ref: OpaquePointer?
        try check(git_branch_lookup(&ref, repo, name, GIT_BRANCH_LOCAL), "branch \(name)")
        defer { git_reference_free(ref) }
        var out: OpaquePointer?
        try check(git_branch_move(&out, ref, newName, 0), "renomear branch")
        git_reference_free(out)
    }
}
