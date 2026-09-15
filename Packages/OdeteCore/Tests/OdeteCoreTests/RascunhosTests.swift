import Foundation
@testable import OdeteCore
import Testing

/// O que estava digitado e não salvo sobrevive ao app ser encerrado.
struct RascunhosTests {
    func novo() -> Rascunhos {
        Rascunhos(url: FileManager.default.temporaryDirectory
            .appending(path: "rascunho-\(UUID().uuidString).json"))
    }

    @Test func idaEVolta() {
        let r = novo()
        r.gravar(["src/App.tsx": "const a = 1", "notas.md": "# oi"])
        #expect(r.ler() == ["src/App.tsx": "const a = 1", "notas.md": "# oi"])
        try? FileManager.default.removeItem(at: r.url)
    }

    @Test func semRascunhoLeVazio() {
        #expect(novo().ler().isEmpty)
    }

    @Test func gravarVazioApagaOArquivo() {
        let r = novo()
        r.gravar(["a.txt": "x"])
        #expect(FileManager.default.fileExists(atPath: r.url.path))
        // Salvou tudo: não pode sobrar rascunho para voltar como alteração fantasma.
        r.gravar([:])
        #expect(!FileManager.default.fileExists(atPath: r.url.path))
        #expect(r.ler().isEmpty)
    }

    @Test func arquivoCorrompidoNaoQuebraAAbertura() throws {
        let r = novo()
        try Data("isto não é json".utf8).write(to: r.url)
        #expect(r.ler().isEmpty)
        try? FileManager.default.removeItem(at: r.url)
    }
}
