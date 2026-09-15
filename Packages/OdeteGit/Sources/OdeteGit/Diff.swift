import Clibgit2
import Foundation
import OdeteI18n

/// Coleta callbacks do `git_diff_foreach` num `Diff`.
final class DiffCollector {
    var files: [FileDiff] = []
    func file(_ delta: git_diff_delta) {
        let new = String(cString: delta.new_file.path)
        let old = String(cString: delta.old_file.path)
        let change: Change = switch delta.status {
        case GIT_DELTA_ADDED, GIT_DELTA_UNTRACKED: .added
        case GIT_DELTA_DELETED: .deleted
        case GIT_DELTA_RENAMED: .renamed
        case GIT_DELTA_TYPECHANGE: .typeChange
        case GIT_DELTA_CONFLICTED: .conflicted
        default: .modified
        }
        let binary = delta.flags & GIT_DIFF_FLAG_BINARY.rawValue != 0
        files.append(FileDiff(path: new, oldPath: old == new ? nil : old, change: change, isBinary: binary, hunks: []))
    }

    func hunk(_ h: git_diff_hunk) {
        var hh = h
        let header = withUnsafePointer(to: &hh.header) { p in
            p.withMemoryRebound(to: CChar.self, capacity: Int(h.header_len)) { String(cString: $0) }
        }.trimmingCharacters(in: .newlines)
        files[files.count - 1].hunks.append(Hunk(
            header: header,
            oldStart: Int(h.old_start),
            oldLines: Int(h.old_lines),
            newStart: Int(h.new_start),
            newLines: Int(h.new_lines),
            lines: []
        ))
    }

    func line(_ l: git_diff_line) {
        let kind: LineKind
        switch l.origin {
        case Int8(GIT_DIFF_LINE_ADDITION.rawValue): kind = .addition
        case Int8(GIT_DIFF_LINE_DELETION.rawValue): kind = .deletion
        case Int8(GIT_DIFF_LINE_CONTEXT.rawValue): kind = .context
        default: return
        }
        let text = String(decoding: UnsafeRawBufferPointer(start: l.content, count: l.content_len), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        let line = DiffLine(
            kind: kind,
            text: text,
            oldLine: l.old_lineno >= 0 ? Int(l.old_lineno) : nil,
            newLine: l.new_lineno >= 0 ? Int(l.new_lineno) : nil
        )
        guard !files.isEmpty, !files[files.count - 1].hunks.isEmpty else { return }
        let fi = files.count - 1
        let hi = files[fi].hunks.count - 1
        files[fi].hunks[hi].lines.append(line)
    }
}

private let fileCB: git_diff_file_cb = { delta, _, payload in
    guard let delta, let payload else { return 0 }
    Unmanaged<DiffCollector>.fromOpaque(payload).takeUnretainedValue().file(delta.pointee)
    return 0
}

private let hunkCB: git_diff_hunk_cb = { _, hunk, payload in
    guard let hunk, let payload else { return 0 }
    Unmanaged<DiffCollector>.fromOpaque(payload).takeUnretainedValue().hunk(hunk.pointee)
    return 0
}

private let lineCB: git_diff_line_cb = { _, _, line, payload in
    guard let line, let payload else { return 0 }
    Unmanaged<DiffCollector>.fromOpaque(payload).takeUnretainedValue().line(line.pointee)
    return 0
}

public extension Repository {
    enum DiffSource: Sendable, Hashable {
        case workdir // índice → workdir (não staged)
        case index // HEAD → índice (staged)
        case headToWorkdir // HEAD → workdir (tudo)
        case commits(String, String)
        case commit(String) // pai → commit
    }

    func diff(_ source: DiffSource, path: String? = nil, context: Int = 3) throws -> Diff {
        var opts = git_diff_options()
        git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION))
        opts.context_lines = UInt32(context)
        opts.flags = GIT_DIFF_INCLUDE_UNTRACKED.rawValue | GIT_DIFF_SHOW_UNTRACKED_CONTENT
            .rawValue | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
        var arr = Self.strarray(path.map { [$0] } ?? [])
        defer { Self.free(&arr) }
        if path != nil {
            opts.pathspec = arr.array
        }

        var d: OpaquePointer?
        switch source {
        case .workdir:
            let idx = try index()
            defer { git_index_free(idx) }
            try check(git_diff_index_to_workdir(&d, repo, idx, &opts), "diff")
        case .index:
            let tree = try headTree()
            defer { git_tree_free(tree) }
            let idx = try index()
            defer { git_index_free(idx) }
            try check(git_diff_tree_to_index(&d, repo, tree, idx, &opts), "diff")
        case .headToWorkdir:
            let tree = try headTree()
            defer { git_tree_free(tree) }
            try check(git_diff_tree_to_workdir_with_index(&d, repo, tree, &opts), "diff")
        case let .commits(a, b):
            let ta = try tree(of: a), tb = try tree(of: b)
            defer { git_tree_free(ta); git_tree_free(tb) }
            try check(git_diff_tree_to_tree(&d, repo, ta, tb, &opts), "diff")
        case let .commit(sha):
            let c = try lookupCommit(sha)
            let tb = try tree(of: sha)
            defer { git_tree_free(tb) }
            if let p = c.parents.first {
                let ta = try tree(of: p)
                defer { git_tree_free(ta) }
                try check(git_diff_tree_to_tree(&d, repo, ta, tb, &opts), "diff")
            } else {
                try check(git_diff_tree_to_tree(&d, repo, nil, tb, &opts), "diff")
            }
        }
        defer { git_diff_free(d) }
        if case .workdir = source {} else {
            var find = git_diff_find_options()
            git_diff_find_options_init(&find, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION))
            git_diff_find_similar(d, &find)
        }
        let collector = DiffCollector()
        let payload = Unmanaged.passUnretained(collector).toOpaque()
        try check(git_diff_foreach(d, fileCB, nil, hunkCB, lineCB, payload), "diff")
        return Diff(files: collector.files)
    }

    internal func headTree() throws -> OpaquePointer? {
        if isUnborn() {
            return nil
        }
        var obj: OpaquePointer?
        try check(git_revparse_single(&obj, repo, "HEAD^{tree}"), tr("árvore do HEAD"))
        return obj
    }

    internal func tree(of sha: String) throws -> OpaquePointer? {
        var obj: OpaquePointer?
        try check(git_revparse_single(&obj, repo, "\(sha)^{tree}"), tr("árvore"))
        return obj
    }
}
