import Foundation
import Observation
import OdeteAccounts
import OdeteCore
import OdeteGit

/// Estado git de um projeto aberto. Toda ação passa por `run`, que serializa e recarrega.
@MainActor
@Observable
public final class GitModel {
    public let root: URL
    public private(set) var repo: Repository?
    public private(set) var status: [StatusEntry] = []
    public private(set) var log: [Commit] = []
    public private(set) var branches: [Branch] = []
    public private(set) var stashes: [StashEntry] = []
    public private(set) var remotes: [Remote] = []
    public private(set) var current: Branch?
    public private(set) var headName: String?
    public private(set) var aheadBehind: (ahead: Int, behind: Int)?
    public private(set) var conflicts: [String] = []
    public private(set) var mergeInProgress = false
    public var busy = false
    public var note = ""
    public var error: String?
    public var commitMessage = ""
    public var progress: CloneProgress?
    /// O que o modo Diff mostra.
    public var diffSource: Repository.DiffSource = .headToWorkdir
    public var diffPath: String?
    public private(set) var diff: Diff = .empty
    /// Diff completo do working tree contra o HEAD, só para contar linhas.
    public private(set) var stat: Diff = .empty
    public var compareA: String?
    public var compareB: String?

    private let accounts: AccountStore
    private var refreshTask: Task<Void, Never>?
    /// Chamado depois de cada `refresh()` (o workspace atualiza o gutter).
    public var onRefreshed: (() -> Void)?

    public init(root: URL, accounts: AccountStore) {
        self.root = root
        self.accounts = accounts
        if Repository.isRepository(root) {
            repo = try? Repository.open(root)
        }
        scheduleRefresh()
    }

    public var isRepo: Bool {
        repo != nil
    }

    public var staged: [StatusEntry] {
        status.filter { $0.staged != nil }
    }

    public var unstaged: [StatusEntry] {
        status.filter { $0.unstaged != nil && !$0.isConflicted }
    }

    public var isClean: Bool {
        status.isEmpty
    }

    /// Linhas que entraram e saíram no working tree inteiro.
    public var lineStat: (added: Int, removed: Int) {
        stat.files.reduce(into: (0, 0)) { acc, f in
            acc.0 += f.additions
            acc.1 += f.deletions
        }
    }

    /// Linhas que entraram e saíram num arquivo. Binário devolve `nil`: não tem linha
    /// para contar, e "+0 −0" ao lado do nome se lê como "não mudou nada".
    public func lineStat(for path: String) -> (added: Int, removed: Int)? {
        guard let f = stat.files.first(where: { $0.path == path }), !f.isBinary else { return nil }
        return (f.additions, f.deletions)
    }

    /// Arquivo que o git trata como binário: imagem, banco, PDF.
    public func ehBinario(_ path: String) -> Bool {
        stat.files.first { $0.path == path }?.isBinary ?? false
    }

    public var origin: Remote? {
        remotes.first { $0.name == "origin" } ?? remotes.first
    }

    public var githubSlug: String? {
        origin?.githubSlug
    }

    public var author: Signature {
        let a = accounts.autor
        return Signature(name: a.name, email: a.email)
    }

    public func credentials(for remote: Remote?) -> Credentials? {
        guard let remote, let acc = accounts.account(forRemote: remote.url),
              let token = accounts.token(for: acc) else { return nil }
        return Credentials(username: acc.kind.gitUsername, token: token)
    }

    public var hasCredentials: Bool {
        credentials(for: origin) != nil
    }

    public var githubToken: String? {
        guard let acc = accounts.github else { return nil }
        return accounts.token(for: acc)
    }

    // MARK: refresh

    public func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    public func refresh() async {
        guard let repo else { return }
        do {
            async let st = repo.status()
            async let lg = repo.log(limit: 200)
            async let br = repo.branches()
            async let sh = repo.stashes()
            async let rm = repo.remotes()
            status = try await st
            log = try await lg
            branches = try await br
            stashes = try await sh
            remotes = try await rm
            current = try await repo.currentBranch()
            headName = await repo.headBranchName()
            aheadBehind = try await repo.aheadBehind()
            conflicts = try await repo.conflictedPaths()
            mergeInProgress = await repo.mergeInProgress
            diff = try await repo.diff(diffSource, path: diffPath)
            stat = try await repo.diff(.headToWorkdir, context: 0)
        } catch {
            self.error = error.localizedDescription
        }
        onRefreshed?()
    }

    public func setDiff(_ source: Repository.DiffSource, path: String? = nil) {
        diffSource = source
        diffPath = path
        scheduleRefresh()
    }

    // MARK: ações

    private func run(_ what: String, _ body: @escaping @Sendable (Repository) async throws -> String?) {
        guard let repo, !busy else { return }
        busy = true
        note = what
        Task {
            defer { busy = false }
            do {
                if let n = try await body(repo) {
                    note = n
                } else {
                    note = ""
                }
            } catch let e as GitError {
                error = e.message
                note = ""
                if e.kind == .auth {
                    error = "autenticação recusada. Entre em Ajustes → Contas."
                }
            } catch {
                self.error = error.localizedDescription
                note = ""
            }
            await refresh()
        }
    }

    public func initRepository() {
        do {
            repo = try Repository.initialize(at: root)
            scheduleRefresh()
        } catch { self.error = error.localizedDescription }
    }

    public func stage(_ paths: [String]) {
        run("stage…") { try await $0.stage(paths); return nil }
    }

    public func unstage(_ paths: [String]) {
        run("unstage…") { try await $0.unstage(paths); return nil }
    }

    public func stageAll() {
        run("stage…") { try await $0.stageAll(); return nil }
    }

    public func unstageAll() {
        run("unstage…") { try await $0.unstageAll(); return nil }
    }

    public func discard(_ paths: [String]) {
        run("descartando…") { try await $0.discard(paths); return nil }
    }

    public func stageHunk(_ h: Hunk, in f: FileDiff) {
        run("stage…") { try await $0.stageHunk(h, in: f); return nil }
    }

    public func unstageHunk(_ h: Hunk, in f: FileDiff) {
        run("unstage…") { try await $0.unstageHunk(h, in: f); return nil }
    }

    public func discardHunk(_ h: Hunk, in f: FileDiff) {
        run("descartando…") { try await $0.discardHunk(
            h,
            in: f
        ); return nil }
    }

    /// `stageFirst` manda tudo para o stage antes de commitar, numa operação só: chamar
    /// `stageAll()` e `commit()` em seguida não funciona porque a segunda cai no guarda de
    /// ocupado enquanto a primeira ainda roda.
    /// `stageFirst` manda tudo para o stage antes de commitar. Havendo remoto, o push sai
    /// logo em seguida, no mesmo bloco: são etapas de uma ação só do ponto de vista de quem
    /// usa, e chamadas separadas cairiam no guarda de ocupado.
    public func commit(stagingEverything stageFirst: Bool = false) {
        let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { error = "escreva a mensagem do commit"; return }
        let author = author
        let merging = mergeInProgress
        let cred = credentials(for: origin)
        // Sem conta conectada não dá para enviar; o commit sai e a mensagem diz o porquê.
        let semConta = origin != nil && cred == nil
        run("commit…") { repo in
            if stageFirst {
                try await repo.stageAll()
            }
            if merging {
                try await repo.finishMerge(message: msg, author: author)
            } else {
                try await repo.commit(message: msg, author: author)
            }
            guard let cred else {
                return semConta ? "commit feito; conecte uma conta para enviar" : "commit feito"
            }
            do {
                try await repo.push(credentials: cred)
                return "commit e push feitos"
            } catch {
                // O commit já está no repositório; só o envio falhou, e é isso que se diz.
                throw GitError(
                    kind: .network,
                    code: 0,
                    message: "commit feito, mas o push falhou: \(error.localizedDescription)"
                )
            }
        }
        commitMessage = ""
    }

    public func undoLastCommit() {
        run("desfazendo…") { try await $0.undoLastCommit(); return "último commit desfeito, alterações no stage" }
    }

    public func createBranch(_ name: String) {
        run("criando branch…") { try await $0.createBranch(
            name,
            checkout: true
        ); return nil }
    }

    public func checkout(_ name: String) {
        run("trocando…") { try await $0.checkout(name); return nil }
    }

    public func deleteBranch(_ name: String) {
        run("apagando…") { try await $0.deleteBranch(name); return nil }
    }

    public func merge(_ name: String) {
        let author = author
        run("merge…") { repo in
            switch try await repo.merge(name, author: author) {
            case .upToDate: "já atualizado"
            case .fastForward: "fast-forward"
            case .merged: "merge feito"
            case let .conflicts(p): "conflitos em \(p.count) arquivo(s)"
            }
        }
    }

    public func abortMerge() {
        run("abortando merge…") { try await $0.abortMerge(); return nil }
    }

    public func resolve(path: String, contents: String) {
        run("resolvendo…") { try await $0.resolveConflict(
            path: path,
            contents: contents
        ); return nil }
    }

    public func stashPush(_ message: String) {
        let author = author
        run("guardando…") { try await $0.stashPush(
            message: message.isEmpty ? "stash" : message,
            author: author
        ); return nil }
    }

    public func stashPop(_ i: Int) {
        run("aplicando stash…") { try await $0.stashPop(i); return nil }
    }

    public func stashDrop(_ i: Int) {
        run("apagando stash…") { try await $0.stashDrop(i); return nil }
    }

    public func addRemote(url: String) {
        run("remoto…") { try await $0.addRemote(name: "origin", url: url); return nil }
    }

    public func fetch() {
        let cred = credentials(for: origin)
        run("fetch…") { try await $0.fetch(credentials: cred); return "fetch ok" }
    }

    public func pull() {
        let cred = credentials(for: origin)
        let author = author
        run("pull…") { repo in
            switch try await repo.pull(credentials: cred, author: author) {
            case .upToDate: "já atualizado"
            case .fastForward: "pull: fast-forward"
            case .merged: "pull: merge feito"
            case let .conflicts(p): "pull: conflitos em \(p.count) arquivo(s)"
            }
        }
    }

    public func push() {
        let cred = credentials(for: origin)
        run("push…") { try await $0.push(credentials: cred); return "push ok" }
    }

    /// Cria o `origin` e sobe a branch atual numa tacada só. Em duas chamadas a segunda
    /// esbarraria no `busy` da primeira e o push não sairia.
    public func publish(url: String) {
        let cred = accounts.account(forRemote: url).flatMap { acc in
            accounts.token(for: acc).map { Credentials(username: acc.kind.gitUsername, token: $0) }
        }
        run("publicando…") { repo in
            try await repo.addRemote(name: "origin", url: url)
            try await repo.push(credentials: cred)
            return "publicado no GitHub"
        }
    }
}
