import Clibgit2
import Foundation
import OdeteCore
import OdeteI18n

public extension Repository {
    /// Faz merge de `name` (branch local ou remota) na branch atual.
    func merge(_ name: String, author: Signature) throws -> MergeResult {
        let refName = (try? branches()).map { $0.contains { $0.isRemote && $0.name == name } } == true
            ? "refs/remotes/\(name)" : "refs/heads/\(name)"
        var ref: OpaquePointer?
        try check(git_reference_lookup(&ref, repo, refName), "branch \(name)")
        defer { git_reference_free(ref) }
        var their: OpaquePointer?
        try check(git_annotated_commit_from_ref(&their, repo, ref), "merge")
        defer { git_annotated_commit_free(their) }
        return try mergeAnnotated(their!, label: name, author: author)
    }

    internal func mergeAnnotated(_ their: OpaquePointer, label: String, author: Signature) throws -> MergeResult {
        var analysis = git_merge_analysis_t(0)
        var pref = git_merge_preference_t(0)
        var heads: [OpaquePointer?] = [their]
        try heads.withUnsafeMutableBufferPointer { buf in
            try check(git_merge_analysis(&analysis, &pref, repo, buf.baseAddress, 1), tr("análise do merge"))
        }
        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            return .upToDate
        }
        let theirOid = git_annotated_commit_id(their).pointee
        if analysis.rawValue & GIT_MERGE_ANALYSIS_UNBORN.rawValue != 0 || analysis
            .rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0
        {
            var oid = theirOid
            var obj: OpaquePointer?
            try check(git_object_lookup(&obj, repo, &oid, GIT_OBJECT_COMMIT), "commit")
            defer { git_object_free(obj) }
            var opts = git_checkout_options()
            git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
            try check(git_checkout_tree(repo, obj, &opts), "fast-forward")
            if analysis.rawValue & GIT_MERGE_ANALYSIS_UNBORN.rawValue != 0 {
                let headName = headBranchName() ?? "main"
                var newRef: OpaquePointer?
                try check(git_reference_create(&newRef, repo, "refs/heads/\(headName)", &oid, 1, "merge"), "ref")
                git_reference_free(newRef)
            } else {
                var head: OpaquePointer?
                try check(git_repository_head(&head, repo), "HEAD")
                defer { git_reference_free(head) }
                var newRef: OpaquePointer?
                try check(git_reference_set_target(&newRef, head, &oid, "fast-forward"), "fast-forward")
                git_reference_free(newRef)
            }
            return .fastForward(Self.hex(theirOid))
        }
        var mopts = git_merge_options()
        git_merge_options_init(&mopts, UInt32(GIT_MERGE_OPTIONS_VERSION))
        var copts = git_checkout_options()
        git_checkout_options_init(&copts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        copts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue
        try heads.withUnsafeMutableBufferPointer { buf in
            try check(git_merge(repo, buf.baseAddress, 1, &mopts, &copts), "merge")
        }
        let conflicts = try conflictedPaths()
        if !conflicts.isEmpty {
            return .conflicts(conflicts)
        }
        let sha = try finishMerge(message: tr("Merge %1$@", "\(label)"), author: author, theirs: theirOid)
        return .merged(sha)
    }

    func conflictedPaths() throws -> [String] {
        try withIndex { idx in
            guard git_index_has_conflicts(idx) == 1 else { return [] }
            var it: OpaquePointer?
            try check(git_index_conflict_iterator_new(&it, idx), "conflitos")
            defer { git_index_conflict_iterator_free(it) }
            var a: UnsafePointer<git_index_entry>?, o: UnsafePointer<git_index_entry>?,
                t: UnsafePointer<git_index_entry>?
            var out: Set<String> = []
            while git_index_conflict_next(&a, &o, &t, it) == 0 {
                if let e = o ?? t ?? a {
                    out.insert(String(cString: e.pointee.path))
                }
            }
            return out.sorted()
        }
    }

    /// Marca um conflito como resolvido com o conteúdo dado.
    func resolveConflict(path: String, contents: String) throws {
        HistoricoDeArquivos.guardar(workdir.appending(path: path), raiz: workdir, origem: .git)
        try contents.write(to: workdir.appending(path: path), atomically: true, encoding: .utf8)
        try withIndex { idx in
            git_index_conflict_remove(idx, path)
            try check(git_index_add_bypath(idx, path), "resolver \(path)")
            try check(git_index_write(idx), tr("índice"))
        }
    }

    var mergeInProgress: Bool {
        git_repository_state(repo) == GIT_REPOSITORY_STATE_MERGE.rawValue
    }

    /// Conclui um merge em andamento (após resolver conflitos) com um commit de duas mães.
    @discardableResult
    func finishMerge(message: String, author: Signature, theirs: git_oid? = nil) throws -> String {
        if try !conflictedPaths().isEmpty {
            throw GitError(
                kind: .conflict,
                code: -1,
                message: tr("há conflitos para resolver")
            )
        }
        var theirOid = theirs ?? git_oid()
        if theirs == nil {
            try check(git_reference_name_to_id(&theirOid, repo, "MERGE_HEAD"), "MERGE_HEAD")
        }
        let treeOid = try withIndex { idx -> git_oid in
            var o = git_oid()
            try check(git_index_write_tree(&o, idx), tr("árvore"))
            return o
        }
        var tOid = treeOid
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, repo, &tOid), tr("árvore"))
        defer { git_tree_free(tree) }
        var headOid = git_oid()
        try check(git_reference_name_to_id(&headOid, repo, "HEAD"), "HEAD")
        var p1: OpaquePointer?, p2: OpaquePointer?
        try check(git_commit_lookup(&p1, repo, &headOid), "pai")
        try check(git_commit_lookup(&p2, repo, &theirOid), "pai")
        defer { git_commit_free(p1); git_commit_free(p2) }
        var sig: UnsafeMutablePointer<git_signature>?
        try check(git_signature_now(&sig, author.name, author.email), "autor")
        defer { git_signature_free(sig) }
        let buf = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 2)
        defer { buf.deallocate() }
        buf[0] = p1; buf[1] = p2
        var oid = git_oid()
        try check(
            git_commit_create(&oid, repo, "HEAD", sig, sig, "UTF-8", message, tree, 2, buf),
            tr("commit de merge")
        )
        git_repository_state_cleanup(repo)
        return Self.hex(oid)
    }

    func abortMerge() throws {
        HistoricoDeArquivos.guardar(((try? status()) ?? []).map { workdir.appending(path: $0.path) }, raiz: workdir, origem: .git)
        var head: OpaquePointer?
        try check(git_revparse_single(&head, repo, "HEAD"), "HEAD")
        defer { git_object_free(head) }
        try check(git_reset(repo, head, GIT_RESET_HARD, nil), "abortar merge")
        git_repository_state_cleanup(repo)
    }
}
