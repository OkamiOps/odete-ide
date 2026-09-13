import Clibgit2
import Foundation
@testable import OdeteGit
import Testing

func ab(_ r: Repository) async throws -> [Int] {
    guard let v = try await r.aheadBehind() else { return [] }
    return [v.ahead, v.behind]
}

struct RemotesTests {
    func bare() throws -> URL {
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

    @Test func pushCloneFetchPull() async throws {
        let remote = try bare()
        let (a, urlA) = try tempRepo()
        try write(urlA, "a.txt", "a\n")
        try await a.stageAll()
        try await a.commit(message: "um", author: me)
        try await a.addRemote(name: "origin", url: remote.absoluteString)
        #expect(try await a.remotes().map(\.url) == [remote.absoluteString])
        try await a.push()
        #expect(try await a.currentBranch()?.upstream == "origin/main")
        #expect(try await ab(a) == [0, 0])

        let dirB = FileManager.default.temporaryDirectory.appending(path: "odete-clone-\(UUID().uuidString)")
        let b = try await Repository.clone(remote.absoluteString, to: dirB) { _ in }
        #expect(try await b.log().map(\.summary) == ["um"])
        #expect(try String(contentsOf: dirB.appending(path: "a.txt"), encoding: .utf8) == "a\n")

        try write(urlA, "b.txt", "b\n")
        try await a.stageAll()
        try await a.commit(message: "dois", author: me)
        #expect(try await ab(a) == [1, 0])
        try await a.push()

        try await b.fetch()
        #expect(try await ab(b) == [0, 1])
        let r = try await b.pull(author: me)
        if case .fastForward = r {} else {
            Issue.record("esperava ff, veio \(r)")
        }
        #expect(try await b.log().count == 2)
        #expect(try await ab(b) == [0, 0])
    }

    @Test func githubSlug() {
        #expect(Remote(name: "o", url: "https://github.com/OkamiOps/odete-ide.git").githubSlug == "OkamiOps/odete-ide")
        #expect(Remote(name: "o", url: "git@github.com:OkamiOps/odete-ide.git").githubSlug == "OkamiOps/odete-ide")
        #expect(Remote(name: "o", url: "https://gitlab.com/a/b.git").githubSlug == nil)
    }
}
