import Clibgit2
import Foundation
import OdeteCore
import OdeteI18n

/// Texto de patch unificado para um hunk, opcionalmente invertido.
enum PatchText {
    static func make(file: FileDiff, hunk: Hunk, reverse: Bool) -> String {
        let old = file.oldPath ?? file.path
        let new = file.path
        var out = tr("diff --git a/%1$@ b/%2$@\n", "\(reverse ? new : old)", "\(reverse ? old : new)")
        switch (file.change, reverse) {
        case (.added, false), (.deleted, true): out += "--- /dev/null\n+++ b/\(new)\n"
        case (.deleted, false), (.added, true): out += tr("--- a/%1$@\n+++ /dev/null\n", "\(old)")
        default: out += tr("--- a/%1$@\n+++ b/%2$@\n", "\(reverse ? new : old)", "\(reverse ? old : new)")
        }
        let (os, ol, ns, nl) = reverse
            ? (hunk.newStart, hunk.newLines, hunk.oldStart, hunk.oldLines)
            : (hunk.oldStart, hunk.oldLines, hunk.newStart, hunk.newLines)
        out += "@@ -\(os),\(ol) +\(ns),\(nl) @@\n"
        for l in hunk.lines {
            let kind = reverse ? (
                l.kind == .addition ? LineKind.deletion : l.kind == .deletion ? .addition : .context
            ) :
                l.kind
            let prefix = kind == .addition ? "+" : kind == .deletion ? "-" : " "
            out += prefix + l.text + "\n"
        }
        return out
    }
}

public extension Repository {
    private func apply(_ patch: String, location: git_apply_location_t) throws {
        var d: OpaquePointer?
        try patch.withCString { c in
            try check(git_diff_from_buffer(&d, c, strlen(c)), "ler patch")
        }
        defer { git_diff_free(d) }
        var opts = git_apply_options()
        git_apply_options_init(&opts, UInt32(GIT_APPLY_OPTIONS_VERSION))
        try check(git_apply(repo, d, location, &opts), "aplicar hunk")
    }

    /// Manda um hunk do workdir para o índice.
    func stageHunk(_ hunk: Hunk, in file: FileDiff) throws {
        try apply(PatchText.make(file: file, hunk: hunk, reverse: false), location: GIT_APPLY_LOCATION_INDEX)
    }

    /// Tira um hunk do índice (mantém no workdir).
    func unstageHunk(_ hunk: Hunk, in file: FileDiff) throws {
        try apply(PatchText.make(file: file, hunk: hunk, reverse: true), location: GIT_APPLY_LOCATION_INDEX)
    }

    /// Descarta um hunk do workdir.
    func discardHunk(_ hunk: Hunk, in file: FileDiff) throws {
        HistoricoDeArquivos.guardar(workdir.appending(path: file.path), raiz: workdir, origem: .git)
        try apply(PatchText.make(file: file, hunk: hunk, reverse: true), location: GIT_APPLY_LOCATION_WORKDIR)
    }
}
