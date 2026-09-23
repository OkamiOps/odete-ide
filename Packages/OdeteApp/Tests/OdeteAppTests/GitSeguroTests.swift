import Foundation
import OdeteAccounts
@testable import OdeteApp
import OdeteGit
import OdeteI18n
import Testing

/// O painel do git não perde trabalho nem diz que fez o que não fez.
@MainActor
@Suite(.serialized)
struct GitSeguroTests {
    init() {
        Texto.escolher(.ptBR)
    }

    let eu = Signature(name: "T", email: "t@t")

    func espera(_ prazo: Duration = .seconds(5), ate condicao: () -> Bool) async {
        let fim = ContinuousClock.now + prazo
        while ContinuousClock.now < fim, !condicao() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Repositório com `a.txt` commitado e o modelo do painel em cima dele.
    func modelo(contas: AccountStore? = nil) async throws -> (GitModel, Repository, URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "odete-gitseguro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try "a\n".write(to: base.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let repo = try Repository.initialize(at: base)
        try await repo.stageAll()
        try await repo.commit(message: "um", author: eu)
        let store = contas ?? AccountStore(
            url: base.appending(path: ".odete/contas.json"),
            keychain: MemorySecrets()
        )
        let git = GitModel(root: base, accounts: store)
        await espera { git.log.count == 1 }
        return (git, repo, base)
    }

    func escreve(_ base: URL, _ rel: String, _ texto: String) throws {
        try texto.write(to: base.appending(path: rel), atomically: true, encoding: .utf8)
    }

    func le(_ base: URL, _ rel: String) -> String? {
        try? String(contentsOf: base.appending(path: rel), encoding: .utf8)
    }

    // MARK: 7. mensagem do commit

    /// A caixa era esvaziada logo que o commit começava, antes de saber se ia dar certo:
    /// commit recusado levava a mensagem junto.
    @Test func mensagemSoSaiQuandoOCommitDaCerto() async throws {
        let (git, _, base) = try await modelo()
        git.commitMessage = "segundo"
        git.commit()
        await espera { !git.busy && git.error != nil }
        #expect(git.error != nil, "commit sem nada no stage devia falhar")
        #expect(git.commitMessage == "segundo")

        git.error = nil
        try escreve(base, "b.txt", "b\n")
        git.commit(stagingEverything: true)
        await espera { !git.busy && git.log.count == 2 }
        #expect(git.log.first?.summary == "segundo")
        #expect(git.commitMessage == "")
    }

    // MARK: 8. commit não é push

    /// Havendo conta, todo commit virava push — inclusive o do botão que dizia só "Commit".
    @Test func commitSoEnviaQuandoPedido() async throws {
        let bare = FileManager.default.temporaryDirectory.appending(path: "odete-bare-\(UUID().uuidString).git")
        _ = try Repository.initialize(at: bare, bare: true)
        let segredos = MemorySecrets()
        let contas = AccountStore(
            url: FileManager.default.temporaryDirectory.appending(path: "odete-contas-\(UUID().uuidString).json"),
            keychain: segredos
        )
        // `file://localhost/…` tem host, e com conta para ele o painel tem credencial.
        try contas.add(HostAccount(kind: .other, host: "localhost", login: "eu"), token: "t")
        let (git, repo, base) = try await modelo(contas: contas)
        try await repo.addRemote(name: "origin", url: "file://localhost" + bare.path)
        try await repo.push()
        git.scheduleRefresh()
        await espera { git.origin != nil }
        #expect(git.hasCredentials)
        let enviado = try await repo.headSha()

        try escreve(base, "b.txt", "b\n")
        git.commitMessage = "só local"
        git.commit(stagingEverything: true)
        await espera { !git.busy && git.log.count == 2 }
        #expect(git.log.count == 2)
        #expect(try await remoteHead(bare) == enviado, "o commit foi enviado sem pedir")

        try escreve(base, "c.txt", "c\n")
        git.commitMessage = "com push"
        git.commit(stagingEverything: true, push: true)
        await espera { !git.busy && git.log.count == 3 }
        #expect(try await remoteHead(bare) == repo.headSha())
    }

    func remoteHead(_ bare: URL) async throws -> String? {
        try await Repository.open(bare).headSha()
    }

    // MARK: 3. descartar com lixeira e desfazer

    @Test func descartarMandaParaALixeiraEDesfazTraz() async throws {
        let (git, _, base) = try await modelo()
        try escreve(base, "a.txt", "mudei\n")
        try escreve(base, "novo.txt", "trabalho de uma tarde\n")
        git.scheduleRefresh()
        await espera { git.status.count == 2 }
        let conta = git.discardCount(["a.txt", "novo.txt"])
        #expect(conta.tracked == 1 && conta.untracked == 1)

        git.discard(["a.txt", "novo.txt"])
        await espera { !git.busy && git.discarded.count == 2 }
        #expect(le(base, "a.txt") == "a\n")
        #expect(le(base, "novo.txt") == nil)
        let lixeira = base.appending(path: ".odete/lixeira")
        let guardados = (FileManager.default.enumerator(atPath: lixeira.path)?.allObjects as? [String]) ?? []
        #expect(guardados.contains { $0.hasSuffix("novo.txt") }, "o não rastreado sumiu sem passar pela lixeira")

        git.undoDiscard()
        await espera { !git.busy && le(base, "novo.txt") != nil }
        #expect(le(base, "novo.txt") == "trabalho de uma tarde\n")
        #expect(le(base, "a.txt") == "mudei\n")
        #expect(git.discarded.isEmpty)
    }

    // MARK: 6. alteração local no caminho do checkout

    @Test func alteracaoLocalNoCaminhoOfereceStash() async throws {
        let (git, repo, base) = try await modelo()
        try await repo.createBranch("feature", checkout: true)
        try escreve(base, "a.txt", "v2\n")
        try await repo.stageAll()
        try await repo.commit(message: "v2", author: eu)
        try await repo.checkout("main")
        try escreve(base, "a.txt", "mudança local\n")
        git.scheduleRefresh()
        await espera { git.status.count == 1 }

        git.checkout("feature")
        await espera { !git.busy && git.error != nil }
        #expect(git.error?.contains("a.txt") == true)
        #expect(git.error?.contains("conflitos") == false)
        #expect(git.errorExit == .stash)

        git.stashAndRetry()
        await espera { !git.busy && git.current?.name == "feature" }
        #expect(git.current?.name == "feature")
        #expect(git.stashes.count == 1)
    }

    // MARK: 11. lock órfão

    @Test func lockOrfaoOfereceRemover() async throws {
        let (git, _, base) = try await modelo()
        try escreve(base, "b.txt", "b\n")
        let lock = base.appending(path: ".git/index.lock")
        try "".write(to: lock, atomically: true, encoding: .utf8)
        git.stage(["b.txt"])
        await espera { !git.busy && git.error != nil }
        guard case let .removeLock(caminho) = git.errorExit else {
            Issue.record("sem a saída de remover o lock: \(String(describing: git.errorExit))")
            return
        }
        git.removeLock(caminho)
        await espera { !git.busy && !FileManager.default.fileExists(atPath: lock.path) }
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }
}
