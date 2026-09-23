import Clibgit2
import Foundation
import OdeteCore
import OdeteI18n

/// Qual versão fica num conflito resolvido por inteiro, sem marcadores.
public enum ConflictSide: Sendable, Hashable {
    case ours, theirs
}

/// O que existe de cada lado de um conflito. Um lado ausente é arquivo apagado ali
/// (apagado × modificado); binário não tem marcador `<<<<<<<` para escolher bloco.
public struct ConflictInfo: Sendable, Hashable {
    public var path: String
    public var ours: Bool
    public var theirs: Bool
    public var binary: Bool

    /// Dá para resolver bloco a bloco no editor? Só texto com os dois lados.
    public var hasMarkers: Bool {
        ours && theirs && !binary
    }
}

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
            try safeCheckout(obj, what: "fast-forward")
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
        let code = heads.withUnsafeMutableBufferPointer { buf in
            git_merge(repo, buf.baseAddress, 1, &mopts, &copts)
        }
        if code < 0 {
            let erro = GitError.last(code, "merge")
            // "1 uncommitted change would be overwritten by merge" não diz qual. Os
            // arquivos são os alterados aqui que o merge também mexe.
            if erro.kind == .localChanges {
                throw GitError.localChanges(blockingPaths(theirs: Self.hex(theirOid)), code: code)
            }
            throw erro
        }
        let conflicts = try conflictedPaths()
        if !conflicts.isEmpty {
            return .conflicts(conflicts)
        }
        let sha = try finishMerge(message: tr("Merge %1$@", "\(label)"), author: author, theirs: theirOid)
        return .merged(sha)
    }

    /// Arquivos alterados no working tree que o commit `theirs` também muda.
    internal func blockingPaths(theirs: String) -> [String] {
        guard let head = try? headSha(),
              let mudados = try? diff(.commits(head, theirs), context: 0).files,
              let alterados = try? status().filter({ $0.staged != nil || $0.unstaged != nil })
        else { return [] }
        let tocados = Set(mudados.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) })
        return alterados.map(\.path).filter { tocados.contains($0) }.sorted()
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

    /// Quem tem o arquivo em cada lado do conflito, e se é binário.
    func conflictInfo(_ path: String) throws -> ConflictInfo {
        try withIndex { idx in
            var a: UnsafePointer<git_index_entry>?, o: UnsafePointer<git_index_entry>?,
                t: UnsafePointer<git_index_entry>?
            try check(git_index_conflict_get(&a, &o, &t, idx, path), tr("conflito em %1$@", path))
            var binario = false
            for e in [o, t] {
                guard let e else { continue }
                var oid = e.pointee.id
                var blob: OpaquePointer?
                if git_blob_lookup(&blob, repo, &oid) == 0 {
                    binario = binario || git_blob_is_binary(blob) == 1
                    git_blob_free(blob)
                }
            }
            return ConflictInfo(path: path, ours: o != nil, theirs: t != nil, binary: binario)
        }
    }

    /// Resolve um conflito ficando com uma versão inteira: a minha ou a deles.
    ///
    /// Binário e apagado × modificado não têm marcadores; o "Marcar resolvido" do
    /// editor ficava apagado e o arquivo nem aparecia para stage — o merge não tinha
    /// como terminar sem o terminal. O lado que apagou o arquivo resolve apagando.
    func resolveConflict(path: String, using side: ConflictSide) throws {
        let url = workdir.appending(path: path)
        HistoricoDeArquivos.guardar(url, raiz: workdir, origem: .git)
        try withIndex { idx in
            var a: UnsafePointer<git_index_entry>?, o: UnsafePointer<git_index_entry>?,
                t: UnsafePointer<git_index_entry>?
            try check(git_index_conflict_get(&a, &o, &t, idx, path), tr("conflito em %1$@", path))
            if let e = side == .ours ? o : t {
                // Lê tudo antes de mexer no índice: os ponteiros moram nele.
                var oid = e.pointee.id
                let executavel = e.pointee.mode == 0o100755
                var blob: OpaquePointer?
                try check(git_blob_lookup(&blob, repo, &oid), "blob")
                let tamanho = Int(git_blob_rawsize(blob))
                let dados = tamanho > 0 ? Data(bytes: git_blob_rawcontent(blob), count: tamanho) : Data()
                git_blob_free(blob)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try dados.write(to: url, options: .atomic)
                if executavel {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                }
                git_index_conflict_remove(idx, path)
                try check(git_index_add_bypath(idx, path), tr("resolver %1$@", path))
            } else {
                try? FileManager.default.removeItem(at: url)
                git_index_conflict_remove(idx, path)
                _ = git_index_remove_bypath(idx, path)
            }
            try check(git_index_write(idx), tr("índice"))
        }
    }

    /// Resolve um conflito apagando o arquivo dos dois lados.
    func resolveConflictByDeleting(path: String) throws {
        HistoricoDeArquivos.guardar(workdir.appending(path: path), raiz: workdir, origem: .git)
        try? FileManager.default.removeItem(at: workdir.appending(path: path))
        try withIndex { idx in
            git_index_conflict_remove(idx, path)
            _ = git_index_remove_bypath(idx, path)
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

    /// Os caminhos que um abort de merge devolveria ao HEAD: o que o merge pôs no
    /// índice e os conflitos. A tela usa para dizer quantos arquivos voltam.
    func mergePaths() throws -> [String] {
        let noIndice = try diff(.index, context: 0).files.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }
        return try Set(noIndice).union(conflictedPaths()).sorted()
    }

    /// `git merge --abort`: volta ao HEAD só o que o merge mexeu.
    ///
    /// Era um `reset --hard`: apagava também a edição que já estava em outro arquivo
    /// antes do merge — que o merge tinha deixado em paz —, e sem perguntar. Agora os
    /// arquivos fora do merge ficam como estão, e se algum arquivo do merge foi mexido
    /// depois dele (fora os conflitos, que são para mexer), o abort recusa em vez de
    /// perder a mudança.
    func abortMerge() throws {
        let conflitos = try Set(conflictedPaths())
        let caminhos = try mergePaths()
        let mexidos = try status().filter { e in
            !conflitos.contains(e.path) && caminhos.contains(e.path)
                && e.unstaged != nil && e.unstaged != .conflicted
        }.map(\.path)
        if !mexidos.isEmpty {
            let lista = mexidos.prefix(3).joined(separator: ", ") + (mexidos.count > 3 ? "…" : "")
            throw GitError(
                kind: .localChanges,
                code: -1,
                message: tr(
                    "você mexeu em %1$@ depois do merge: abortar agora perderia isso. Faça commit, guarde em stash ou descarte antes.",
                    lista
                ),
                paths: mexidos
            )
        }
        HistoricoDeArquivos.guardar(caminhos.map { workdir.appending(path: $0) }, raiz: workdir, origem: .git)
        var head: OpaquePointer?
        try check(git_revparse_single(&head, repo, "HEAD"), "HEAD")
        defer { git_object_free(head) }
        var headTree: OpaquePointer?
        try check(git_commit_tree(&headTree, head), tr("árvore do HEAD"))
        defer { git_tree_free(headTree) }
        let noHead = caminhos.filter { p in
            var e: OpaquePointer?
            guard git_tree_entry_bypath(&e, headTree, p) == 0 else { return false }
            git_tree_entry_free(e)
            return true
        }
        if !caminhos.isEmpty {
            // 1. Os conflitos saem do índice; 2. o índice volta ao HEAD nesses caminhos;
            // 3. o working tree segue o índice; 4. o que o merge trouxe e o HEAD não tem sai.
            try withIndex { idx in
                for p in conflitos {
                    git_index_conflict_remove(idx, p)
                }
                try check(git_index_write(idx), tr("índice"))
            }
            var todos = Self.strarray(caminhos)
            defer { Self.free(&todos) }
            try check(git_reset_default(repo, head, &todos.array), tr("abortar merge"))
            if !noHead.isEmpty {
                var opts = git_checkout_options()
                git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
                opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
                var arr = Self.strarray(noHead)
                defer { Self.free(&arr) }
                opts.paths = arr.array
                try check(git_checkout_index(repo, nil, &opts), tr("abortar merge"))
            }
            for p in caminhos where !noHead.contains(p) {
                try? FileManager.default.removeItem(at: workdir.appending(path: p))
            }
        }
        git_repository_state_cleanup(repo)
    }
}
