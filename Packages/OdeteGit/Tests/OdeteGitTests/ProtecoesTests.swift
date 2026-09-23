import Clibgit2
import Foundation
@testable import OdeteGit
import OdeteI18n
import Testing

/// Repositório bare num diretório temporário, para servir de remoto `file://`.
func bareRemote() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "odete-bare-\(UUID().uuidString).git",
        directoryHint: .isDirectory
    )
    var r: OpaquePointer?
    Libgit2.start()
    try check(git_repository_init(&r, url.path, 1))
    git_repository_free(r)
    return url
}

/// Repositório com um commit em `main` já enviado para um remoto bare novo.
func publishedRepo() async throws -> (Repository, URL, URL) {
    let remote = try bareRemote()
    let (repo, url) = try tempRepo()
    try write(url, "a.txt", "a\n")
    try await repo.stageAll()
    try await repo.commit(message: "um", author: me)
    try await repo.addRemote(name: "origin", url: remote.absoluteString)
    try await repo.push()
    return (repo, url, remote)
}

func remoteHead(_ remote: URL, _ branch: String = "main") throws -> String? {
    var r: OpaquePointer?
    try check(git_repository_open(&r, remote.path))
    defer { git_repository_free(r) }
    var oid = git_oid()
    guard git_reference_name_to_id(&oid, r, "refs/heads/\(branch)") == 0 else { return nil }
    return Repository.hex(oid)
}

/// O git parou de mentir e de perder trabalho: um teste por bug, cada um falhava antes.
struct ProtecoesTests {
    init() {
        Texto.escolher(.ptBR)
    }

    // MARK: 1. push recusado pelo servidor

    /// O remoto aceita o pacote e recusa a ref (aqui, um lock na ref do bare; no GitHub,
    /// branch protegida ou hook). A recusa só chega por `push_update_reference`: sem ele
    /// o push "dava certo" e ainda marcava o upstream.
    @Test func pushRecusadoPeloRemotoNaoViraPushOk() async throws {
        let (repo, url, remote) = try await publishedRepo()
        let antes = try remoteHead(remote)
        try write(url, "b.txt", "b\n")
        try await repo.stageAll()
        try await repo.commit(message: "dois", author: me)
        try "".write(to: remote.appending(path: "refs/heads/main.lock"), atomically: true, encoding: .utf8)
        await #expect {
            try await repo.push()
        } throws: { e in
            (e as? GitError)?.kind == .rejected && (e as? GitError)?.message.contains("main") == true
        }
        #expect(try remoteHead(remote) == antes)
        #expect(try await ab(repo) == [1, 0])
    }

    @Test func recusaDoGitHubViraFraseQueDizOQueFazer() {
        let protegida = GitError.pushRejected(
            ref: "refs/heads/main",
            reason: "protected branch hook declined",
            remoteText: "remote: error: GH006: Protected branch update failed for refs/heads/main.\n"
        )
        #expect(protegida.kind == .rejected)
        #expect(protegida.message.contains("protegida") && protegida.message.contains("pull request"))
        let hook = GitError.pushRejected(
            ref: "refs/heads/dev",
            reason: "pre-receive hook declined",
            remoteText: "remote: error: arquivo grande demais\n"
        )
        #expect(hook.kind == .rejected)
        #expect(hook.message.contains("pre-receive") && hook.message.contains("arquivo grande demais"))
        let atrasado = GitError.pushRejected(ref: "refs/heads/main", reason: "fetch first", remoteText: "")
        #expect(atrasado.kind == .nonFastForward)
    }

    /// Duas cópias divergentes: o libgit2 recusa do lado de cá, em inglês cru.
    @Test func pushSemFastForwardPedePullEmPortugues() async throws {
        let (a, urlA, remote) = try await publishedRepo()
        let dirB = FileManager.default.temporaryDirectory.appending(path: "odete-clone-\(UUID().uuidString)")
        let b = try await Repository.clone(remote.absoluteString, to: dirB)
        try write(urlA, "a.txt", "de A\n")
        try await a.stageAll()
        try await a.commit(message: "A", author: me)
        try await a.push()
        try write(dirB, "a.txt", "de B\n")
        try await b.stageAll()
        try await b.commit(message: "B", author: me)
        await #expect {
            try await b.push()
        } throws: { e in
            let g = e as? GitError
            return g?.kind == .nonFastForward && g?
                .message == tr("o remoto tem commits que você ainda não tem: faça pull antes do push")
        }
    }

    // MARK: 2. branch remota e HEAD solto

    @Test func tocarNaBranchRemotaCriaLocalQueAcompanha() async throws {
        let (repo, _, _) = try await publishedRepo()
        try await repo.createBranch("feature", checkout: true)
        try await repo.push(branch: "feature")
        try await repo.checkout("main")
        try await repo.deleteBranch("feature")
        #expect(try await repo.branches().contains { $0.isRemote && $0.name == "origin/feature" })

        try await repo.checkout("origin/feature")
        let atual = try await repo.currentBranch()
        #expect(atual?.name == "feature", "HEAD solto na ref remota: \(String(describing: atual))")
        #expect(atual?.upstream == "origin/feature")
        #expect(git_repository_head_detached(repo.repo) == 0)
    }

    @Test func switchSemLocalUsaARemotaDeMesmoNome() async throws {
        let (repo, _, _) = try await publishedRepo()
        try await repo.createBranch("dev", checkout: true)
        try await repo.push(branch: "dev")
        try await repo.checkout("main")
        try await repo.deleteBranch("dev")
        try await repo.checkout("dev")
        #expect(try await repo.currentBranch()?.upstream == "origin/dev")
    }

    /// Com HEAD solto o push mandava a `main` local, que não era o que estava na tela.
    @Test func pushComHeadSoltoRecusaSemMandarAMain() async throws {
        let (repo, url, remote) = try await publishedRepo()
        let enviado = try remoteHead(remote)
        try write(url, "b.txt", "b\n")
        try await repo.stageAll()
        try await repo.commit(message: "só local", author: me)
        var oid = git_oid()
        try check(git_oid_fromstr(&oid, #require(enviado)))
        try check(git_repository_set_head_detached(repo.repo, &oid))
        await #expect {
            try await repo.push()
        } throws: { e in
            (e as? GitError)?.kind == .detachedHead
        }
        #expect(try remoteHead(remote) == enviado)
    }

    // MARK: 3. descartar

    @Test func descartarNaoApagaNaoRastreado() async throws {
        let (repo, url) = try tempRepo()
        try write(url, "a.txt", "a\n")
        try await repo.stageAll()
        try await repo.commit(message: "um", author: me)
        try write(url, "novo.txt", "trabalho de uma tarde\n")
        try write(url, "a.txt", "mudado\n")
        let sobraram = try await repo.discard(["novo.txt", "a.txt"])
        #expect(sobraram == ["novo.txt"])
        #expect(FileManager.default.fileExists(atPath: url.appending(path: "novo.txt").path))
        #expect(try String(contentsOf: url.appending(path: "a.txt"), encoding: .utf8) == "a\n")
    }

    // MARK: 4. abortar merge

    /// main e feature mexem em `a.txt` (conflito); feature ainda traz `c.txt`. A edição em
    /// `b.txt`, de antes do merge, não tem nada com ele — e o `reset --hard` a apagava.
    func mergeComConflito() async throws -> (Repository, URL) {
        let (repo, url) = try tempRepo()
        try write(url, "a.txt", "base\n")
        try write(url, "b.txt", "b\n")
        try await repo.stageAll()
        try await repo.commit(message: "base", author: me)
        try await repo.createBranch("feature", checkout: true)
        try write(url, "a.txt", "deles\n")
        try write(url, "c.txt", "novo deles\n")
        try await repo.stageAll()
        try await repo.commit(message: "feature", author: me)
        try await repo.checkout("main")
        try write(url, "a.txt", "meu\n")
        try await repo.stageAll()
        try await repo.commit(message: "main", author: me)
        try write(url, "b.txt", "edição que não é do merge\n")
        let r = try await repo.merge("feature", author: me)
        #expect(r == .conflicts(["a.txt"]))
        return (repo, url)
    }

    @Test func abortarMergeNaoApagaEdicaoForaDele() async throws {
        let (repo, url) = try await mergeComConflito()
        try await repo.abortMerge()
        #expect(await repo.mergeInProgress == false)
        #expect(try await repo.conflictedPaths().isEmpty)
        #expect(try String(contentsOf: url.appending(path: "a.txt"), encoding: .utf8) == "meu\n")
        #expect(!FileManager.default.fileExists(atPath: url.appending(path: "c.txt").path))
        #expect(try String(contentsOf: url.appending(path: "b.txt"), encoding: .utf8) == "edição que não é do merge\n")
        #expect(try await repo.status() == [StatusEntry(path: "b.txt", staged: nil, unstaged: .modified)])
    }

    @Test func abortarMergeRecusaSeArquivoDoMergeMudouDepois() async throws {
        let (repo, url) = try await mergeComConflito()
        try write(url, "c.txt", "mexi depois do merge\n")
        await #expect {
            try await repo.abortMerge()
        } throws: { e in
            (e as? GitError)?.kind == .localChanges && (e as? GitError)?.paths == ["c.txt"]
        }
        #expect(await repo.mergeInProgress)
        #expect(try String(contentsOf: url.appending(path: "c.txt"), encoding: .utf8) == "mexi depois do merge\n")
    }

    // MARK: 5. conflito sem marcadores

    @Test func apagadoContraModificadoResolveComUmLado() async throws {
        let (repo, url) = try tempRepo()
        try write(url, "a.txt", "base\n")
        try await repo.stageAll()
        try await repo.commit(message: "base", author: me)
        try await repo.createBranch("feature", checkout: true)
        try write(url, "a.txt", "deles\n")
        try await repo.stageAll()
        try await repo.commit(message: "muda", author: me)
        try await repo.checkout("main")
        try FileManager.default.removeItem(at: url.appending(path: "a.txt"))
        try await repo.stageAll()
        try await repo.commit(message: "apaga", author: me)
        #expect(try await repo.merge("feature", author: me) == .conflicts(["a.txt"]))
        let info = try await repo.conflictInfo("a.txt")
        #expect(!info.ours && info.theirs && !info.hasMarkers)

        try await repo.resolveConflict(path: "a.txt", using: .theirs)
        #expect(try await repo.conflictedPaths().isEmpty)
        #expect(try String(contentsOf: url.appending(path: "a.txt"), encoding: .utf8) == "deles\n")
        try await repo.finishMerge(message: "merge", author: me)
        #expect(try await repo.log().first?.parents.count == 2)
    }

    @Test func binarioEmConflitoFicaComAMinhaOuApaga() async throws {
        let (repo, url) = try tempRepo()
        let base = Data([0, 1, 2, 3]), deles = Data([0, 9, 9, 9]), meu = Data([0, 7, 7, 7])
        try base.write(to: url.appending(path: "img.bin"))
        try write(url, "x.txt", "x\n")
        try await repo.stageAll()
        try await repo.commit(message: "base", author: me)
        try await repo.createBranch("feature", checkout: true)
        try deles.write(to: url.appending(path: "img.bin"))
        try write(url, "x.txt", "deles\n")
        try await repo.stageAll()
        try await repo.commit(message: "deles", author: me)
        try await repo.checkout("main")
        try meu.write(to: url.appending(path: "img.bin"))
        try write(url, "x.txt", "meu\n")
        try await repo.stageAll()
        try await repo.commit(message: "meu", author: me)
        #expect(try await repo.merge("feature", author: me) == .conflicts(["img.bin", "x.txt"]))
        #expect(try await repo.conflictInfo("img.bin").binary)

        try await repo.resolveConflict(path: "img.bin", using: .ours)
        #expect(try Data(contentsOf: url.appending(path: "img.bin")) == meu)
        try await repo.resolveConflictByDeleting(path: "x.txt")
        #expect(!FileManager.default.fileExists(atPath: url.appending(path: "x.txt").path))
        #expect(try await repo.conflictedPaths().isEmpty)
    }

    // MARK: 6. alteração local no caminho do checkout

    @Test func checkoutBloqueadoDizQualArquivoENaoFalaEmConflito() async throws {
        let (repo, url) = try tempRepo()
        try write(url, "a.txt", "v1\n")
        try await repo.stageAll()
        try await repo.commit(message: "v1", author: me)
        try await repo.createBranch("feature", checkout: true)
        try write(url, "a.txt", "v2\n")
        try await repo.stageAll()
        try await repo.commit(message: "v2", author: me)
        try await repo.checkout("main")
        try write(url, "a.txt", "mudança local\n")
        await #expect {
            try await repo.checkout("feature")
        } throws: { e in
            let g = e as? GitError
            return g?.kind == .localChanges && g?.paths == ["a.txt"] && g?.message.contains("a.txt") == true
                && g?.message.contains("conflitos") == false
        }
        #expect(try await repo.currentBranch()?.name == "main")
    }

    // MARK: 9. desfazer commit já enviado

    @Test func sabeSeOUltimoCommitJaEstaNoRemoto() async throws {
        let (repo, url) = try tempRepo()
        try write(url, "a.txt", "a\n")
        try await repo.stageAll()
        try await repo.commit(message: "um", author: me)
        #expect(await repo.headIsOnRemote() == false)
        let remote = try bareRemote()
        try await repo.addRemote(name: "origin", url: remote.absoluteString)
        try await repo.push()
        #expect(await repo.headIsOnRemote())
        try write(url, "b.txt", "b\n")
        try await repo.stageAll()
        try await repo.commit(message: "dois", author: me)
        #expect(await repo.headIsOnRemote() == false)
    }

    // MARK: 10. apagar branch

    @Test func apagarBranchAtualRecusaEmPortugues() async throws {
        let (repo, url) = try tempRepo()
        try write(url, "a.txt", "a\n")
        try await repo.stageAll()
        try await repo.commit(message: "um", author: me)
        await #expect {
            try await repo.deleteBranch("main")
        } throws: { e in
            (e as? GitError)?.message == tr("não dá para apagar a branch atual (%1$@): troque de branch antes", "main")
        }
        try await repo.createBranch("solta", checkout: true)
        for i in 1 ... 2 {
            try write(url, "s\(i).txt", "\(i)\n")
            try await repo.stageAll()
            try await repo.commit(message: "s\(i)", author: me)
        }
        try await repo.checkout("main")
        #expect(try await repo.commitsOnlyIn(branch: "solta") == 2)
    }

    // MARK: 11. erros do libgit2 em português

    @Test func lockOrfaoViraFraseClaraEDaParaRemover() async throws {
        let (repo, url) = try tempRepo()
        try write(url, "a.txt", "a\n")
        let lock = url.appending(path: ".git/index.lock")
        try "".write(to: lock, atomically: true, encoding: .utf8)
        var erro: GitError?
        do { try await repo.stage(["a.txt"]) } catch { erro = error as? GitError }
        #expect(erro?.kind == .locked)
        #expect(erro?.message.contains("index.lock") == true)
        #expect(erro?.message.contains("the index is locked") == false)
        try await repo.removeStaleLock(erro?.paths.first ?? "")
        #expect(!FileManager.default.fileExists(atPath: lock.path))
        try await repo.stage(["a.txt"])
        await #expect(throws: GitError.self) { try await repo.removeStaleLock("a.txt") }
    }

    @Test func mensagensDoLibgit2ViramPortugues() {
        let c = GitError.classify
        #expect(c(-1, Int32(GIT_ERROR_HTTP.rawValue), "unexpected http status code: 404").kind == .notFound)
        #expect(c(-1, Int32(GIT_ERROR_HTTP.rawValue), "unexpected http status code: 403").message.contains("403"))
        #expect(c(GIT_EAUTH.rawValue, Int32(GIT_ERROR_HTTP.rawValue), "too many redirects or authentication replays")
            .message == tr("autenticação recusada pelo remoto"))
        #expect(c(-1, Int32(GIT_ERROR_NET.rawValue), "failed to resolve address for github.com: nodename nor servname")
            .kind == .network)
        #expect(c(GIT_ENOTFOUND.rawValue, Int32(GIT_ERROR_REFERENCE.rawValue), "reference 'refs/heads/xyz' not found")
            .message == tr("não encontrei %1$@", "xyz"))
        #expect(c(GIT_ECONFLICT.rawValue, Int32(GIT_ERROR_CHECKOUT.rawValue), "1 conflict prevents checkout")
            .kind == .localChanges)
        #expect(c(
            GIT_ECONFLICT.rawValue,
            Int32(GIT_ERROR_MERGE.rawValue),
            "2 uncommitted changes would be overwritten by merge"
        )
        .kind == .localChanges)
    }

    // MARK: 12. remoto SSH

    @Test func remotoSSHSemContaDizOQueFazer() async throws {
        let (repo, url) = try tempRepo()
        try write(url, "a.txt", "a\n")
        try await repo.stageAll()
        try await repo.commit(message: "um", author: me)
        try await repo.addRemote(name: "origin", url: "git@example.com:dono/repo.git")
        for op in ["push", "fetch"] {
            await #expect {
                if op == "push" {
                    try await repo.push()
                } else {
                    try await repo.fetch()
                }
            } throws: { e in
                let g = e as? GitError
                return g?.kind == .ssh && g?.message.contains("https://example.com/dono/repo.git") == true
            }
        }
    }

    @Test func enderecoSSHViraHTTPS() {
        #expect(Remote
            .httpsEquivalent("git@github.com:OkamiOps/odete-ide.git") == "https://github.com/OkamiOps/odete-ide.git")
        #expect(Remote
            .httpsEquivalent("ssh://git@gitlab.com:2222/grupo/sub/repo.git") == "https://gitlab.com/grupo/sub/repo.git")
        #expect(Remote.httpsEquivalent("https://github.com/a/b.git") == nil)
        #expect(Remote.httpsEquivalent("file:///tmp/x.git") == nil)
        #expect(!Remote.isSSH("/tmp/repo:estranho"))
        #expect(Remote.host(of: "git@codeberg.org:a/b.git") == "codeberg.org")
    }
}
