import Foundation
@testable import OdeteCore
import Testing

struct StateStoreTests {
    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "odete-\(UUID().uuidString)/state.json")
    }

    @Test func roundTrip() throws {
        let store = StateStore(url: temp())
        var snap = ChromeSnapshot()
        snap.theme = .latte
        snap.sideWidth = 300
        let pid = UUID()
        snap.tabsByProject[pid] = [EditorTab(path: "src/a.ts", isDirty: true)]
        try store.saveNow(snap)
        let back = store.load()
        #expect(back == snap)
    }

    @Test func missingFileYieldsDefault() {
        let store = StateStore(url: temp())
        #expect(store.load() == ChromeSnapshot())
    }

    @Test func debounceCoalesces() async {
        let store = StateStore(url: temp(), debounce: .milliseconds(50))
        var a = ChromeSnapshot()
        a.sideWidth = 100
        var b = ChromeSnapshot()
        b.sideWidth = 200
        store.scheduleSave(a)
        store.scheduleSave(b)
        await store.flush()
        #expect(store.load().sideWidth == 200)
    }

    @MainActor
    @Test func chromeStateNotifies() {
        let state = ChromeState()
        var seen: [Double] = []
        state.onChange = { seen.append($0.sideWidth) }
        state.snapshot.sideWidth = 320
        state.select(side: .files) // fecha porque já estava em files+aberto
        #expect(seen.first == 320)
        #expect(state.snapshot.sideOpen == false)
        state.select(side: .git)
        #expect(state.snapshot.side == .git && state.snapshot.sideOpen)
    }

    /// Um state.json que não dá para ler de jeito nenhum não é jogado fora: fica ao lado,
    /// com a data, e o app volta sem repetir o onboarding de quem já passou por ele.
    @Test func arquivoIlegivelFicaGuardadoAoLado() throws {
        let url = temp()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("isto não é json {".utf8).write(to: url)
        let store = StateStore(url: url)
        let snap = store.load()
        #expect(snap.welcomeDone, "quem já tinha state.json não é pessoa nova")
        let irmaos = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let guardado = try #require(irmaos.first { $0.hasPrefix("state.json.falhou-") })
        let conteudo = try String(
            contentsOf: url.deletingLastPathComponent().appending(path: guardado),
            encoding: .utf8
        )
        #expect(conteudo == "isto não é json {")
    }
}
