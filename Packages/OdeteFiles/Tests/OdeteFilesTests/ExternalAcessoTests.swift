import Foundation
@testable import OdeteFiles
import Testing

/// O acesso a pasta externa é contado pelo sistema, e acesso aberto sem fechar se
/// acumula enquanto o app vive. Listar não abre nada; `url(for:)` abre uma vez por
/// projeto; `liberar` e remover fecham.
struct ExternalAcessoTests {
    func registro() throws -> (ExternalProjects, UUID, UUID) {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "ext-acesso-\(UUID().uuidString)")
        let a = tmp.appending(path: "a"), b = tmp.appending(path: "b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let reg = ExternalProjects(file: tmp.appending(path: "external.json"))
        return try (reg, reg.add(a).id, reg.add(b).id)
    }

    @Test func listarNaoAbreAcesso() throws {
        let (reg, _, _) = try registro()
        #expect(reg.list().count == 2)
        #expect(reg.abertos == 0)
    }

    @Test func urlAbreUmaVezPorProjeto() throws {
        let (reg, a, b) = try registro()
        for _ in 0 ..< 5 {
            _ = reg.url(for: a)
        }
        // No simulador o acesso a pasta dentro do app pode não precisar de escopo; o que
        // não pode é passar de um por projeto.
        #expect(reg.abertos <= 1)
        _ = reg.url(for: b)
        #expect(reg.abertos <= 2)
        reg.liberarTodos(exceto: a)
        #expect(reg.abertos <= 1)
        reg.liberar(a)
        #expect(reg.abertos == 0)
    }

    @Test func removerFechaOAcesso() throws {
        let (reg, a, _) = try registro()
        _ = reg.url(for: a)
        reg.remove(a)
        #expect(reg.abertos == 0)
        #expect(reg.url(for: a) == nil)
    }

    @Test func comAcessoDevolveOQueLeu() throws {
        let (reg, a, _) = try registro()
        let nome = reg.comAcesso(a) { $0.lastPathComponent }
        #expect(nome == "a")
        #expect(reg.abertos == 0)
        #expect(reg.comAcesso(UUID()) { $0 } == nil)
    }
}
