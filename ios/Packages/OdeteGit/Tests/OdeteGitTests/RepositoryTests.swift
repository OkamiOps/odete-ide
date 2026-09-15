import Foundation
@testable import OdeteGit
import Testing

let me = Signature(name: "Teste", email: "t@odete.app")

func tempRepo() throws -> (Repository, URL) {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "odete-git-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return try (Repository.initialize(at: url), url)
}

func write(_ url: URL, _ rel: String, _ text: String) throws {
    let f = url.appending(path: rel)
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: f, atomically: true, encoding: .utf8)
}

struct RepositoryTests {
    @Test func initStatusStageCommitLog() async throws {
        let (repo, url) = try tempRepo()
        #expect(Repository.isRepository(url))
        #expect(await repo.isUnborn())
        #expect(await repo.headBranchName() == "main")
        try write(url, "a.txt", "olá\n")
        var st = try await repo.status()
        #expect(st == [StatusEntry(path: "a.txt", staged: nil, unstaged: .untracked)])

        try await repo.stage(["a.txt"])
        st = try await repo.status()
        #expect(st == [StatusEntry(path: "a.txt", staged: .added, unstaged: nil)])

        let c = try await repo.commit(message: "primeiro", author: me)
        #expect(c.summary == "primeiro" && c.parents.isEmpty && c.author == me)
        #expect(try await repo.status().isEmpty)
        #expect(try await repo.log().map(\.summary) == ["primeiro"])
        #expect(try await repo.currentBranch()?.name == "main")

        try write(url, "a.txt", "olá mundo\n")
        st = try await repo.status()
        #expect(st == [StatusEntry(path: "a.txt", staged: nil, unstaged: .modified)])
        try await repo.stageAll()
        #expect(try await repo.status().first?.staged == .modified)
        try await repo.unstageAll()
        #expect(try await repo.status().first?.unstaged == .modified)
        try await repo.discard(["a.txt"])
        #expect(try await repo.status().isEmpty)
        #expect(try String(contentsOf: url.appending(path: "a.txt"), encoding: .utf8) == "olá\n")
    }

    @Test func commitVazioNaoEntraNoHistorico() async throws {
        let (repo, url) = try tempRepo()
        try write(url, "a.txt", "olá\n")
        try await repo.stage(["a.txt"])
        _ = try await repo.commit(message: "primeiro", author: me)
        // Sem nada no stage, `git commit` criava um commit sem arquivo nenhum — foi o
        // que o agente deixou no histórico ao tentar corrigir a mensagem.
        await #expect(throws: GitError.self) { try await repo.commit(message: "de novo", author: me) }
        #expect(try await repo.log().count == 1)
        // Quem realmente quiser um commit vazio ainda pode.
        _ = try await repo.commit(message: "marco", author: me, permitirVazio: true)
        #expect(try await repo.log().count == 2)
    }

    @Test func gitignoreAndUndo() async throws {
        let (repo, url) = try tempRepo()
        try write(url, ".gitignore", "node_modules/\n")
        try write(url, "node_modules/x.js", "1")
        try write(url, "b.txt", "b")
        let paths = try await repo.status().map(\.path)
        #expect(paths == [".gitignore", "b.txt"])
        try await repo.stageAll()
        try await repo.commit(message: "um", author: me)
        try write(url, "c.txt", "c")
        try await repo.stageAll()
        try await repo.commit(message: "dois", author: me)
        #expect(try await repo.log().count == 2)
        try await repo.undoLastCommit()
        #expect(try await repo.log().count == 1)
        #expect(try await repo.status() == [StatusEntry(path: "c.txt", staged: .added, unstaged: nil)])
    }
}
