import Foundation
@testable import OdeteFiles
import Testing

struct ExternalProjectsTests {
    @Test func addListRemove() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "ext-\(UUID().uuidString)")
        let folder = tmp.appending(path: "minha-pasta")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reg = ExternalProjects(file: tmp.appending(path: "external.json"))
        let p = try reg.add(folder)
        #expect(p.external && p.name == "minha-pasta")
        #expect(try reg.add(folder).id == p.id) // mesma pasta não duplica
        #expect(reg.list().map(\.id) == [p.id])
        #expect(reg.url(for: p.id)?.standardizedFileURL.path == folder.standardizedFileURL.path)
        // persistência
        let again = ExternalProjects(file: tmp.appending(path: "external.json"))
        #expect(again.list().count == 1)
        reg.remove(p.id)
        #expect(reg.list().isEmpty)
        // pasta apagada some da lista
        let gone = tmp.appending(path: "some")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        let q = try reg.add(gone)
        try FileManager.default.removeItem(at: gone)
        let fresh = ExternalProjects(file: tmp.appending(path: "external.json"))
        #expect(!fresh.list().contains { $0.id == q.id })
    }

    /// Pasta que sumiu não some do hub calada: fica como indisponível, e dá para apontar
    /// o projeto para a pasta nova sem perder o id.
    @Test func pastaQueSumiuFicaIndisponivelEDaParaReapontar() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "ext-\(UUID().uuidString)")
        let antes = tmp.appending(path: "antes")
        try FileManager.default.createDirectory(at: antes, withIntermediateDirectories: true)
        let reg = ExternalProjects(file: tmp.appending(path: "external.json"))
        let p = try reg.add(antes)
        try FileManager.default.removeItem(at: antes)

        let reaberto = ExternalProjects(file: tmp.appending(path: "external.json"))
        #expect(reaberto.list().isEmpty)
        #expect(reaberto.indisponiveis().map(\.id) == [p.id])

        let depois = tmp.appending(path: "depois")
        try FileManager.default.createDirectory(at: depois, withIntermediateDirectories: true)
        let q = try #require(try reaberto.reapontar(p.id, para: depois))
        #expect(q.id == p.id && q.name == "depois")
        #expect(reaberto.indisponiveis().isEmpty)
        #expect(reaberto.list().map(\.id) == [p.id])
        #expect(reaberto.url(for: p.id)?.standardizedFileURL.path == depois.standardizedFileURL.path)
        // e fica gravado
        #expect(ExternalProjects(file: tmp.appending(path: "external.json")).list().map(\.id) == [p.id])
    }
}
