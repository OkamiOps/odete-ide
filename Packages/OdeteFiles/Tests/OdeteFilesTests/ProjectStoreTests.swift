import Foundation
import OdeteCore
@testable import OdeteFiles
import OdeteI18n
import Testing

struct ProjectStoreTests {
    /// Os testes conferem a frase exata que está no código, que é o português. Sem
    /// travar o idioma, o mesmo teste passa no Mac e falha no simulador em inglês.
    init() {
        Texto.escolher(.ptBR)
    }

    @Test func createListRenameDuplicateDelete() throws {
        let store = try ProjectStore(root: tempDir())
        #expect(try store.list().isEmpty)
        let a = try store.create(name: "Alpha")
        _ = try store.create(name: "Beta", template: .viteReact)
        var list = try store.list()
        #expect(list.map(\.name).sorted() == ["Alpha", "Beta"])
        #expect(FileManager.default.fileExists(atPath: store.root.appending(path: "Beta/src/App.tsx").path))

        let renamed = try store.rename(a, to: "Alfa")
        #expect(renamed.id == a.id)
        list = try store.list()
        #expect(list.map(\.name).sorted() == ["Alfa", "Beta"])

        let dup = try store.duplicate(renamed)
        #expect(dup.name == "Alfa cópia")
        #expect(dup.id != renamed.id)

        try store.delete(dup)
        #expect(try store.list().count == 2)
    }

    @Test func rejectsBadNames() throws {
        let store = try ProjectStore(root: tempDir())
        #expect(throws: FileError.invalidName("a/b")) { try store.create(name: "a/b") }
        #expect(throws: FileError.invalidName("..")) { try store.create(name: "..") }
        _ = try store.create(name: "X")
        #expect(throws: FileError.alreadyExists("X")) { try store.create(name: "X") }
    }

    @Test func touchOrdersByLastOpened() throws {
        let store = try ProjectStore(root: tempDir())
        let a = try store.create(name: "A")
        _ = try store.create(name: "B")
        _ = try store.touch(a)
        #expect(try store.list().first?.name == "A")
    }
}
