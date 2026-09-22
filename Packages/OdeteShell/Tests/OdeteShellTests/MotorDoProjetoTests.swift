import Foundation
import OdeteBundler
@testable import OdeteShell
import Testing

/// Um esbuild por projeto, venha de onde vier o pedido.
///
/// Cada motor compila o esbuild.wasm de 14 MB e segura a memória do Go dele, que só
/// cresce. Antes eram um por aba de terminal, mais um por `npm run dev`, mais o do lint.
struct MotorDoProjetoTests {
    func projetoVite() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(
            path: "odete-motor-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: u.appending(path: "src"), withIntermediateDirectories: true)
        try "<!doctype html><html><head></head><body><script type=\"module\" src=\"/src/main.ts\"></script></body></html>"
            .write(to: u.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try #"export const marca: string = "motor-do-projeto"; document.title = marca;"#
            .write(to: u.appending(path: "src/main.ts"), atomically: true, encoding: .utf8)
        return u
    }

    @Test func abasDoMesmoProjetoDividemOMotor() throws {
        let root = try projetoVite()
        let a = Shell(root: root)
        let b = Shell(root: root)
        #expect(a.bundler === b.bundler, "cada aba criou o próprio esbuild")
        #expect(a.bundler === Esbuild.doProjeto(root), "o lint do editor pegaria outro motor")
        let outro = try Shell(root: projetoVite())
        #expect(outro.bundler !== a.bundler, "projetos diferentes não podem dividir motor")
    }

    /// `vite` sobe o servidor no motor da aba — o mesmo das outras — e matar o job não
    /// derruba o motor: o lint e o próximo `npm run dev` continuam nele.
    @Test func viteUsaOMotorDoProjetoEMatarNaoDerruba() async throws {
        let root = try projetoVite()
        let sh = Shell(root: root)
        let o = Out()
        let porta = 20000 + Int.random(in: 0 ..< 20000)
        #expect(await sh.run("vite --port \(porta)", sink: o.sink) == 0, "\(o.err)")
        let dev = try #require(sh.devServer)
        #expect(dev.esbuild === sh.bundler, "o dev server subiu num esbuild próprio")
        #expect(Shell(root: root).bundler === dev.esbuild)
        let (d, _) = try await URLSession.shared.data(from: dev.url.appending(path: "@odete/js/src/main.ts"))
        #expect(String(decoding: d, as: UTF8.self).contains("motor-do-projeto"))

        sh.killAll()
        let diag = try await sh.bundler.lint("const x = ;", file: "x.ts")
        #expect(diag.contains { $0.kind == .error }, "o motor morreu junto com o servidor")
        let o2 = Out()
        #expect(await sh.run("vite --port \(porta + 1)", sink: o2.sink) == 0, "\(o2.err)")
        #expect(sh.devServer?.esbuild === sh.bundler)
        sh.killAll()
    }
}
