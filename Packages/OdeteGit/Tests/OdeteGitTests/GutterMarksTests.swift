import Foundation
@testable import OdeteGit
import Testing

struct GutterMarksTests {
    @Test func marksFromWorkdir() async throws {
        let (repo, url) = try tempRepo()
        try write(url, "a.txt", (1 ... 10).map(String.init).joined(separator: "\n") + "\n")
        try await repo.stageAll()
        try await repo.commit(message: "base", author: me)
        // linha 3 alterada, linha 6 removida, "novo" inserido depois da 9
        var lines = (1 ... 10).map { String($0) }
        lines[2] = "três"
        lines.remove(at: 5)
        lines.insert("novo", at: 8)
        try write(url, "a.txt", lines.joined(separator: "\n") + "\n")
        let (marks, file) = try await repo.gutterMarks(path: "a.txt")
        #expect(file != nil)
        #expect(marks.map { "\($0.line):\($0.kind.rawValue)" } == ["3:modified", "6:deleted", "9:added"])
    }

    @Test func untrackedIsAllAdded() async throws {
        let (repo, url) = try tempRepo()
        try write(url, "a.txt", "x\n")
        try await repo.stageAll()
        try await repo.commit(message: "base", author: me)
        try write(url, "b.txt", "1\n2\n3\n")
        let (marks, _) = try await repo.gutterMarks(path: "b.txt")
        #expect(marks.count == 3 && marks.allSatisfy { $0.kind == .added })
    }
}
