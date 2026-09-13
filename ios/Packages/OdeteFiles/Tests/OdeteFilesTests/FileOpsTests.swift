import Foundation
import Testing
@testable import OdeteFiles

@Suite struct FileOpsTests {
    @Test func crud() throws {
        let ops = FileOps(root: try tempDir())
        try ops.createFile("a.txt", contents: "olá")
        #expect(try ops.read("a.txt") == "olá")
        #expect(throws: FileError.alreadyExists("a.txt")) { try ops.createFile("a.txt") }
        let renamed = try ops.rename("a.txt", to: "b.txt")
        #expect(renamed == "b.txt")
        #expect(!ops.exists("a.txt") && ops.exists("b.txt"))
        try ops.createDirectory("dir")
        try ops.move("b.txt", to: "dir/c.txt")
        #expect(try ops.read("dir/c.txt") == "olá")
        #expect(ops.isDirectory("dir"))
        try ops.delete("dir")
        #expect(!ops.exists("dir"))
        #expect(throws: FileError.notFound("nada")) { try ops.delete("nada") }
    }

    @Test func refusesEscapingRoot() throws {
        let ops = FileOps(root: try tempDir())
        #expect(throws: FileError.outsideRoot("../x")) { try ops.write("../x", "") }
        #expect(throws: FileError.outsideRoot("/etc/passwd")) { try ops.read("/etc/passwd") }
        try ops.createDirectory("d")
        #expect(throws: FileError.outsideRoot("d/inner")) { try ops.move("d", to: "d/inner") }
    }

    @Test func freeNames() throws {
        let ops = FileOps(root: try tempDir())
        #expect(ops.freeName(in: "", base: "sem-titulo", ext: "txt") == "sem-titulo.txt")
        try ops.createFile("sem-titulo.txt")
        #expect(ops.freeName(in: "", base: "sem-titulo", ext: "txt") == "sem-titulo-2.txt")
    }
}
