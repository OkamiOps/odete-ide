import Foundation
import OdeteBundler
@testable import OdeteShell
import Testing

/// `vite build` e `vite preview` pelo terminal: as opções do Vite (`--mode`, `--base`,
/// `--outDir`) chegam ao build, e o preview serve de onde o build gravou.
struct ViteBuildComandoTests {
    func projeto() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(
            path: "odete-vite-cmd-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: u.appending(path: "src"), withIntermediateDirectories: true)
        try "<!doctype html><html><head><title>%MODE%</title></head><body><script type=\"module\" src=\"/src/main.ts\"></script></body></html>"
            .write(to: u.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try "import './estilo.css';\ndocument.title = import.meta.env.VITE_NOME;\n"
            .write(to: u.appending(path: "src/main.ts"), atomically: true, encoding: .utf8)
        try "body { margin: 0 }\n".write(to: u.appending(path: "src/estilo.css"), atomically: true, encoding: .utf8)
        try "VITE_NOME=homolog-da-marca\n".write(
            to: u.appending(path: ".env.staging"),
            atomically: true,
            encoding: .utf8
        )
        return u
    }

    @Test func viteBuildComOpcoesEPreview() async throws {
        let root = try projeto()
        let sh = Shell(root: root)
        let o = Out()
        #expect(
            await sh.run("npx vite build --mode staging --base=/app/ --outDir saida", sink: o.sink) == 0,
            "\(o.err)"
        )
        #expect(o.out.contains("saida/index.html") && o.out.contains("saida/assets/index-"), "\(o.out)")
        let html = try String(contentsOf: root.appending(path: "saida/index.html"), encoding: .utf8)
        #expect(html.contains("<title>staging</title>"))
        let js = try #require(html.firstMatch(of: /src="\/app\/(assets\/index-[A-Z0-9]{8}\.js)"/)?.1)
        #expect(html.contains("href=\"/app/assets/index-"), "\(html)")
        let bundle = try String(contentsOf: root.appending(path: "saida/" + js), encoding: .utf8)
        #expect(bundle.contains("homolog-da-marca"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "dist").path))

        // O preview, na pasta e no base que o build usou, pela porta pedida.
        let porta = 20000 + Int.random(in: 0 ..< 20000)
        let o2 = Out()
        #expect(
            await sh.run("npx vite preview --outDir saida --base /app/ --port \(porta)", sink: o2.sink) == 0,
            "\(o2.err)"
        )
        defer { sh.killAll() }
        let (d, r) = try await URLSession.shared
            .data(from: #require(URL(string: "http://127.0.0.1:\(porta)/app/\(js)")))
        #expect((r as? HTTPURLResponse)?.statusCode == 200 && String(decoding: d, as: UTF8.self)
            .contains("homolog-da-marca"))
    }

    @Test func viteBuildSemIndex() async throws {
        let root = try projeto()
        try FileManager.default.removeItem(at: root.appending(path: "index.html"))
        let o = Out()
        #expect(await Shell(root: root).run("npx vite build", sink: o.sink) == 1)
        #expect(o.err.contains("index.html"), "\(o.err)")
    }
}
