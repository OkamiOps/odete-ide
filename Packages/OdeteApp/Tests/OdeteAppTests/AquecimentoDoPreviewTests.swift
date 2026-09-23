import Foundation
import OdeteAccounts
@testable import OdeteApp
import OdeteBundler
import OdeteGit
import Testing

/// O Preview de um projeto JS aparecendo sem servidor carrega o esbuild antes do toque em
/// "npm run dev" — e só depois da janela de abertura, para não pesar na abertura do app.
@MainActor
struct AquecimentoDoPreviewTests {
    @Test func previewDeProjetoJSCarregaOMotorDepoisDaJanela() async throws {
        let raiz = FileManager.default.temporaryDirectory.appending(path: "odete-aquece-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raiz) }
        try #"{"name":"app","scripts":{"dev":"vite"}}"#
            .write(to: raiz.appending(path: "package.json"), atomically: true, encoding: .utf8)
        let contas = FileManager.default.temporaryDirectory.appending(path: "odete-contas-\(UUID().uuidString).json")
        let run = RunModel(root: raiz, git: GitModel(root: raiz, accounts: AccountStore(
            url: contas,
            keychain: MemorySecrets()
        )))
        run.aquecerParaOPreview()
        // Dentro da janela de abertura: nada de motor ainda.
        try await Task.sleep(for: .milliseconds(500))
        #expect(Esbuild.existente(raiz) == nil, "o esbuild subiu na abertura do projeto")
        let fim = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < fim, Esbuild.existente(raiz) == nil || Aquecimento.emAndamento(raiz: raiz) {
            try await Task.sleep(for: .milliseconds(100))
        }
        let motor = try #require(Esbuild.existente(raiz), "o Preview apareceu e o esbuild não foi carregado")
        // Carregado de verdade: o bundler.js já está no motor.
        #expect(try await motor.engine.call("__contextosVivos") == "0")
    }
}
