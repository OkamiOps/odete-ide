import Clibgit2
import Foundation
import OdeteI18n

/// Arquivos que o checkout se recusou a sobrescrever, contados pelo `notify_cb`.
final class BlockedPaths {
    var paths: [String] = []
}

private let notifyCB: git_checkout_notify_cb = { _, path, _, _, _, payload in
    guard let payload, let path else { return 0 }
    Unmanaged<BlockedPaths>.fromOpaque(payload).takeUnretainedValue().paths.append(String(cString: path))
    return 0
}

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
                if !(bb.isRemote && bb.name.hasSuffix("/HEAD")) {
                    out.append(bb)
                }
            }
            git_reference_free(ref)
        }
        return out.sorted { a, b in
            if a.isRemote != b.isRemote {
                return !a.isRemote
            }
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
        if checkout {
            try self.checkout(name)
        }
    }

    /// Troca de branch. Branch remota vira branch local que a acompanha, como
    /// `git switch x` faz com `origin/x`.
    ///
    /// Antes, tocar em `origin/x` punha o HEAD direto na ref remota: HEAD solto, commit
    /// feito ali ficava sem branch, e o push seguinte caía na `main`.
    func checkout(_ name: String) throws {
        let todas = try branches()
        if !todas.contains(where: { !$0.isRemote && $0.name == name }) {
            if let remota = todas.first(where: { $0.isRemote && $0.name == name }) {
                try switchToRemote(remota)
                return
            }
            // `git switch x` sem `x` local e com uma só `<remoto>/x`.
            let nomes = try remotes().map(\.name)
            let candidatas = todas.filter { $0.isRemote && Self.localName(ofRemote: $0.name, remotes: nomes) == name }
            if candidatas.count == 1 {
                try switchToRemote(candidatas[0])
                return
            }
        }
        try switchTo(refName: "refs/heads/\(name)", label: name)
    }

    /// "origin/feature/x" → "feature/x", olhando os nomes dos remotos que existem.
    internal static func localName(ofRemote name: String, remotes: [String]) -> String {
        let nomes = remotes.sorted { $0.count > $1.count }
        if let r = nomes.first(where: { name.hasPrefix($0 + "/") }) {
            return String(name.dropFirst(r.count + 1))
        }
        return name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? name
    }

    internal func switchToRemote(_ remota: Branch) throws {
        let local = try Self.localName(ofRemote: remota.name, remotes: remotes().map(\.name))
        if try branches(includeRemote: false).contains(where: { $0.name == local }) {
            try switchTo(refName: "refs/heads/\(local)", label: local)
            return
        }
        try createBranch(local, at: remota.target, checkout: false)
        do {
            try switchTo(refName: "refs/heads/\(local)", label: local)
        } catch {
            // O checkout não saiu (alteração local no caminho): a branch nova não fica
            // para trás como se a troca tivesse acontecido.
            try? deleteBranch(local)
            throw error
        }
        try setUpstream(branch: local, to: remota.name)
    }

    internal func switchTo(refName: String, label: String) throws {
        var obj: OpaquePointer?
        try check(git_revparse_single(&obj, repo, refName), "branch \(label)")
        defer { git_object_free(obj) }
        try safeCheckout(obj, what: tr("trocar branch"))
        try check(git_repository_set_head(repo, refName), "HEAD")
    }

    /// `git_checkout_tree` que não pisa em alteração local. Quando alguma bloqueia, o
    /// erro diz quais arquivos, em vez do "1 conflict prevents checkout" que se lia
    /// como conflito de merge sem haver conflito nenhum para resolver.
    internal func safeCheckout(_ tree: OpaquePointer?, what: String) throws {
        let bloqueados = BlockedPaths()
        let payload = Unmanaged.passRetained(bloqueados)
        defer { payload.release() }
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        opts.notify_flags = GIT_CHECKOUT_NOTIFY_CONFLICT.rawValue
        opts.notify_cb = notifyCB
        opts.notify_payload = payload.toOpaque()
        let code = git_checkout_tree(repo, tree, &opts)
        if code < 0 {
            let erro = GitError.last(code, what)
            if erro.kind == .localChanges || code == GIT_ECONFLICT.rawValue {
                throw GitError.localChanges(bloqueados.paths.sorted(), code: code)
            }
            throw erro
        }
    }

    /// Apaga uma branch local. A atual não: o libgit2 recusaria em inglês, e o painel
    /// nem deveria chegar a pedir.
    func deleteBranch(_ name: String) throws {
        if try currentBranch()?.name == name {
            throw GitError(
                kind: .invalid,
                code: -1,
                message: tr("não dá para apagar a branch atual (%1$@): troque de branch antes", name)
            )
        }
        var ref: OpaquePointer?
        try check(git_branch_lookup(&ref, repo, name, GIT_BRANCH_LOCAL), "branch \(name)")
        defer { git_reference_free(ref) }
        try check(git_branch_delete(ref), "apagar branch")
    }

    /// Quantos commits da branch não estão na atual nem no upstream dela: o que some
    /// com ela se for apagada.
    func commitsOnlyIn(branch name: String) throws -> Int {
        var alvo = git_oid()
        try check(git_reference_name_to_id(&alvo, repo, "refs/heads/\(name)"), "branch \(name)")
        var walk: OpaquePointer?
        try check(git_revwalk_new(&walk, repo), "log")
        defer { git_revwalk_free(walk) }
        try check(git_revwalk_push(walk, &alvo), "log")
        if !isUnborn() {
            git_revwalk_hide_head(walk)
        }
        var up: OpaquePointer?, local: OpaquePointer?
        if git_branch_lookup(&local, repo, name, GIT_BRANCH_LOCAL) == 0 {
            if git_branch_upstream(&up, local) == 0, let nomeUp = git_reference_name(up) {
                git_revwalk_hide_ref(walk, nomeUp)
            }
            git_reference_free(up)
            git_reference_free(local)
        }
        var n = 0
        var oid = git_oid()
        while git_revwalk_next(&oid, walk) == 0 {
            n += 1
        }
        return n
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
