import Foundation
import Testing
@testable import OdeteGit

@Suite struct DiffBranchesTests {
    func seeded() async throws -> (Repository, URL) {
        let (repo, url) = try tempRepo()
        try write(url, "a.txt", (1 ... 20).map(String.init).joined(separator: "\n") + "\n")
        try await repo.stageAll()
        try await repo.commit(message: "base", author: me)
        return (repo, url)
    }

    @Test func diffWorkdirAndHunks() async throws {
        let (repo, url) = try await seeded()
        var lines: [String] = (1 ... 20).map { String($0) }
        lines[2] = "X"
        lines[16] = "Y"
        try write(url, "a.txt", lines.joined(separator: "\n") + "\n")
        let d = try await repo.diff(.workdir)
        #expect(d.files.count == 1 && d.files[0].change == .modified)
        let hunks = d.files[0].hunks
        #expect(hunks.count == 2)
        #expect(d.files[0].additions == 2 && d.files[0].deletions == 2)
        #expect(hunks[0].lines.contains { $0.kind == .addition && $0.text == "X" })

        try await repo.stageHunk(hunks[0], in: d.files[0])
        let staged = try await repo.diff(.index)
        #expect(staged.files[0].hunks.count == 1 && staged.files[0].hunks[0].lines.contains { $0.text == "X" })
        let rest = try await repo.diff(.workdir)
        #expect(rest.files[0].hunks.count == 1 && rest.files[0].hunks[0].lines.contains { $0.text == "Y" })

        try await repo.unstageHunk(staged.files[0].hunks[0], in: staged.files[0])
        #expect(try await repo.diff(.index).files.isEmpty)
        let again = try await repo.diff(.workdir)
        #expect(again.files[0].hunks.count == 2)

        try await repo.discardHunk(again.files[0].hunks[1], in: again.files[0])
        let final = try await repo.diff(.workdir)
        #expect(final.files[0].hunks.count == 1)
        #expect(try String(contentsOf: url.appending(path: "a.txt"), encoding: .utf8).contains("16\n17\n18"))
    }

    @Test func diffCommits() async throws {
        let (repo, url) = try await seeded()
        try write(url, "b.txt", "novo\n")
        try await repo.stageAll()
        let c2 = try await repo.commit(message: "b", author: me)
        let d = try await repo.diff(.commit(c2.id))
        #expect(d.files.map(\.path) == ["b.txt"] && d.files[0].change == .added)
        let log = try await repo.log()
        let ab = try await repo.diff(.commits(log[1].id, log[0].id))
        #expect(ab.files.count == 1)
    }

    @Test func branchesAndFastForward() async throws {
        let (repo, url) = try await seeded()
        try await repo.createBranch("feature")
        #expect(try await repo.currentBranch()?.name == "feature")
        try write(url, "f.txt", "f\n")
        try await repo.stageAll()
        try await repo.commit(message: "feat", author: me)
        try await repo.checkout("main")
        #expect(!FileManager.default.fileExists(atPath: url.appending(path: "f.txt").path))
        let names = try await repo.branches().map(\.name)
        #expect(names == ["feature", "main"])
        let r = try await repo.merge("feature", author: me)
        if case .fastForward = r {} else { Issue.record("esperava fast-forward, veio \(r)") }
        #expect(FileManager.default.fileExists(atPath: url.appending(path: "f.txt").path))
        try await repo.deleteBranch("feature")
        #expect(try await repo.branches().map(\.name) == ["main"])
    }

    @Test func mergeWithConflict() async throws {
        let (repo, url) = try await seeded()
        try await repo.createBranch("outra")
        try write(url, "a.txt", "deles\n")
        try await repo.stageAll()
        try await repo.commit(message: "deles", author: me)
        try await repo.checkout("main")
        try write(url, "a.txt", "meu\n")
        try await repo.stageAll()
        try await repo.commit(message: "meu", author: me)
        let r = try await repo.merge("outra", author: me)
        guard case let .conflicts(paths) = r else { Issue.record("esperava conflito, veio \(r)"); return }
        #expect(paths == ["a.txt"])
        #expect(await repo.mergeInProgress)
        let text = try String(contentsOf: url.appending(path: "a.txt"), encoding: .utf8)
        #expect(text.contains("<<<<<<<") && text.contains(">>>>>>>"))
        #expect(try await repo.status().first?.isConflicted == true)
        try await repo.resolveConflict(path: "a.txt", contents: "meu e deles\n")
        let sha = try await repo.finishMerge(message: "Merge outra", author: me)
        #expect(sha.count == 40)
        #expect(!(await repo.mergeInProgress))
        #expect(try await repo.log().first?.parents.count == 2)
        #expect(try await repo.status().isEmpty)
    }

    @Test func stash() async throws {
        let (repo, url) = try await seeded()
        try write(url, "a.txt", "mudou\n")
        try write(url, "novo.txt", "n\n")
        try await repo.stashPush(message: "wip", author: me)
        #expect(try await repo.status().isEmpty)
        #expect(try await repo.stashes().map(\.message).first?.contains("wip") == true)
        try await repo.stashPop()
        #expect(try await repo.stashes().isEmpty)
        #expect(try await repo.status().count == 2)
        try await repo.stashPush(message: "drop", author: me)
        try await repo.stashDrop()
        #expect(try await repo.stashes().isEmpty)
    }
}
