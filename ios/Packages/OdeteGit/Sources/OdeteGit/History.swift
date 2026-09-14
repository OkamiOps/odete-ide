import Clibgit2
import Foundation

/// Um trecho do blame: linhas contíguas vindas do mesmo commit.
public struct BlameHunk: Sendable, Hashable, Identifiable {
    /// Primeira linha (1-based) no arquivo atual.
    public var startLine: Int
    public var lines: Int
    public var sha: String
    public var author: String
    public var date: Date
    public var summary: String
    public var id: Int {
        startLine
    }

    public var short: String {
        String(sha.prefix(7))
    }

    /// Linhas ainda não commitadas.
    public var isUncommitted: Bool {
        sha.allSatisfy { $0 == "0" }
    }
}

public extension Repository {
    /// Commits que tocaram um caminho, do mais novo para o mais velho. Percorre até `scan` commits.
    func log(path: String, limit: Int = 100, scan: Int = 2000) throws -> [Commit] {
        if isUnborn() {
            return []
        }
        var walk: OpaquePointer?
        try check(git_revwalk_new(&walk, repo), "log")
        defer { git_revwalk_free(walk) }
        git_revwalk_sorting(walk, GIT_SORT_TIME.rawValue)
        try check(git_revwalk_push_head(walk), "log")
        var arr = Self.strarray([path])
        defer { Self.free(&arr) }
        var opts = git_diff_options()
        git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION))
        opts.pathspec = arr.array
        var out: [Commit] = []
        var oid = git_oid()
        var seen = 0
        while out.count < limit, seen < scan, git_revwalk_next(&oid, walk) == 0 {
            seen += 1
            var c: OpaquePointer?
            guard git_commit_lookup(&c, repo, &oid) == 0, let c else { continue }
            defer { git_commit_free(c) }
            var tree: OpaquePointer?
            guard git_commit_tree(&tree, c) == 0 else { continue }
            defer { git_tree_free(tree) }
            var parentTree: OpaquePointer?
            if git_commit_parentcount(c) > 0 {
                var p: OpaquePointer?
                if git_commit_parent(&p, c, 0) == 0 {
                    git_commit_tree(&parentTree, p)
                    git_commit_free(p)
                }
            }
            var d: OpaquePointer?
            guard git_diff_tree_to_tree(&d, repo, parentTree, tree, &opts) == 0 else {
                git_tree_free(parentTree)
                continue
            }
            let touched = git_diff_num_deltas(d) > 0
            git_diff_free(d)
            git_tree_free(parentTree)
            if touched {
                out.append(Self.commit(from: c))
            }
        }
        return out
    }

    /// Blame do arquivo no workdir (linhas não commitadas ficam com sha zerado).
    func blame(path: String) throws -> [BlameHunk] {
        if isUnborn() {
            return []
        }
        var opts = git_blame_options()
        git_blame_options_init(&opts, UInt32(GIT_BLAME_OPTIONS_VERSION))
        var blame: OpaquePointer?
        try check(git_blame_file(&blame, repo, path, &opts), "blame")
        defer { git_blame_free(blame) }
        // Aplica o buffer do workdir por cima, para as linhas novas saírem como não commitadas.
        var final: OpaquePointer? = blame
        var withBuffer: OpaquePointer?
        if let data = try? Data(contentsOf: workdir.appending(path: path)), !data.isEmpty {
            let ok = data.withUnsafeBytes { raw -> Int32 in
                git_blame_buffer(&withBuffer, blame, raw.bindMemory(to: CChar.self).baseAddress, raw.count)
            }
            if ok == 0 {
                final = withBuffer
            }
        }
        defer {
            if withBuffer != nil {
                git_blame_free(withBuffer)
            }
        }
        var summaries: [String: String] = [:]
        var out: [BlameHunk] = []
        let n = git_blame_get_hunk_count(final)
        for i in 0 ..< n {
            guard let h = git_blame_get_hunk_byindex(final, i) else { continue }
            let sha = Self.hex(h.pointee.final_commit_id)
            let sig = h.pointee.final_signature
            let uncommitted = sha.allSatisfy { $0 == "0" }
            // `git_blame_buffer` copia hunks sem assinatura; nesse caso o commit responde.
            let commit: Commit? = (sig == nil && !uncommitted) ? try? lookupCommit(sha) : nil
            let author = sig.map { String(cString: $0.pointee.name) } ?? commit?.author.name ?? "não commitado"
            let date = sig.map { Date(timeIntervalSince1970: TimeInterval($0.pointee.when.time)) } ?? commit?
                .date ?? Date()
            let summary: String
            if let s = summaries[sha] {
                summary = s
            } else if uncommitted {
                summary = "alteração local"
                summaries[sha] = summary
            } else {
                summary = commit?.summary ?? (try? lookupCommit(sha).summary) ?? ""
                summaries[sha] = summary
            }
            out.append(BlameHunk(
                startLine: Int(h.pointee.final_start_line_number),
                lines: Int(h.pointee.lines_in_hunk),
                sha: sha, author: author, date: date, summary: summary
            ))
        }
        return out
    }
}
