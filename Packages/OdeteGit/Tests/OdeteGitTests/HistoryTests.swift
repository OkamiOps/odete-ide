import Foundation
@testable import OdeteGit
import OdeteI18n
import Testing

struct HistoryTests {
    @Test func logByPathAndBlame() async throws {
        let (repo, url) = try tempRepo()
        try write(url, "a.txt", "um\ndois\n")
        try write(url, "b.txt", "x\n")
        try await repo.stageAll()
        let c1 = try await repo.commit(message: "primeiro", author: me)
        try write(url, "b.txt", "y\n")
        try await repo.stageAll()
        _ = try await repo.commit(message: "só b", author: me)
        try write(url, "a.txt", "um\ndois\ntrês\n")
        try await repo.stageAll()
        let c3 = try await repo.commit(message: "a de novo", author: me)

        let hist = try await repo.log(path: "a.txt")
        #expect(hist.map(\.summary) == ["a de novo", "primeiro"])
        #expect(hist.map(\.id) == [c3.id, c1.id])

        try write(url, "a.txt", "um\ndois\ntrês\nquatro\n")
        let blame = try await repo.blame(path: "a.txt")
        #expect(blame.map { "\($0.startLine):\($0.lines)" } == ["1:2", "3:1", "4:1"])
        #expect(blame[0].summary == "primeiro" && blame[1].summary == "a de novo")
        #expect(blame[1].author == "Teste")
        #expect(blame[2].isUncommitted && blame[2].author == tr("não commitado"))
    }
}
