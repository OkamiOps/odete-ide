import Clibgit2
import Foundation

private final class StashCollector {
    var items: [StashEntry] = []
}

private let stashCB: git_stash_cb = { index, message, _, payload in
    guard let payload else { return 0 }
    let msg = message.map { String(cString: $0) } ?? ""
    Unmanaged<StashCollector>.fromOpaque(payload).takeUnretainedValue().items.append(StashEntry(index: index, message: msg))
    return 0
}

public extension Repository {
    func stashes() throws -> [StashEntry] {
        let c = StashCollector()
        try check(git_stash_foreach(repo, stashCB, Unmanaged.passUnretained(c).toOpaque()), "stash")
        return c.items
    }

    func stashPush(message: String, author: Signature, includeUntracked: Bool = true) throws {
        var sig: UnsafeMutablePointer<git_signature>?
        try check(git_signature_now(&sig, author.name, author.email), "autor")
        defer { git_signature_free(sig) }
        var opts = git_stash_save_options()
        git_stash_save_options_init(&opts, UInt32(GIT_STASH_SAVE_OPTIONS_VERSION))
        opts.flags = includeUntracked ? GIT_STASH_INCLUDE_UNTRACKED.rawValue : GIT_STASH_DEFAULT.rawValue
        opts.stasher = UnsafePointer(sig)
        var oid = git_oid()
        let m = strdup(message)
        defer { Foundation.free(m) }
        opts.message = UnsafePointer(m)
        try check(git_stash_save_with_opts(&oid, repo, &opts), "guardar stash")
    }

    func stashPop(_ index: Int = 0) throws {
        var opts = git_stash_apply_options()
        git_stash_apply_options_init(&opts, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION))
        opts.flags = GIT_STASH_APPLY_REINSTATE_INDEX.rawValue
        try check(git_stash_pop(repo, index, &opts), "aplicar stash")
    }

    func stashDrop(_ index: Int = 0) throws {
        try check(git_stash_drop(repo, index), "apagar stash")
    }
}
