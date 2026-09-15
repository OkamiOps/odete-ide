import Foundation
@testable import OdeteBundler
import OdeteRuntime
import Synchronization
import Testing

func tmpProject() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appending(
        path: "odete-bundle-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: u.appending(path: "src"), withIntermediateDirectories: true)
    try "export const soma = (a: number, b: number): number => a + b;".write(
        to: u.appending(path: "src/soma.ts"),
        atomically: true,
        encoding: .utf8
    )
    try "import { soma } from './soma'; import './style.css'; export const App = () => <h1>{soma(40, 2)}</h1>; document.body.innerHTML = String(soma(1, 2));"
        .write(
            to: u.appending(path: "src/main.tsx"),
            atomically: true,
            encoding: .utf8
        )
    try "body { color: red }".write(to: u.appending(path: "src/style.css"), atomically: true, encoding: .utf8)
    try "<!doctype html><html><head></head><body><div id=root></div><script type=\"module\" src=\"/src/main.tsx\"></script></body></html>"
        .write(
            to: u.appending(path: "index.html"),
            atomically: true,
            encoding: .utf8
        )
    // react falso só para o runtime JSX resolver
    let react = u.appending(path: "node_modules/react")
    try FileManager.default.createDirectory(at: react, withIntermediateDirectories: true)
    try #"{"name":"react","version":"19.0.0","main":"index.js","exports":{".":"./index.js","./jsx-dev-runtime":"./jsx-dev-runtime.js","./jsx-runtime":"./jsx-runtime.js"}}"#
        .write(
            to: react.appending(path: "package.json"),
            atomically: true,
            encoding: .utf8
        )
    try "module.exports = { createElement: (t, p, ...c) => ({ t, p, c }) };".write(
        to: react.appending(path: "index.js"),
        atomically: true,
        encoding: .utf8
    )
    try "exports.jsxDEV = (t, p) => ({ t, p }); exports.Fragment = 'f';".write(
        to: react.appending(path: "jsx-dev-runtime.js"),
        atomically: true,
        encoding: .utf8
    )
    try "exports.jsx = (t, p) => ({ t, p }); exports.jsxs = exports.jsx; exports.Fragment = 'f';".write(
        to: react.appending(path: "jsx-runtime.js"),
        atomically: true,
        encoding: .utf8
    )
    return u
}

@Suite(.serialized) struct BundlerTests {
    @Test func loadsAndTransforms() async throws {
        let root = try tmpProject()
        let es = Esbuild(root: root) { _, t in print("[js]", t) }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(60)); if !Task
                .isCancelled
            {
                print("[watchdog] estourou"); es.engine.stop()
            }
        }
        defer { watchdog.cancel() }
        let v = try await es.ready()
        #expect(v == Esbuild.version)
        let out = try await es.transform(
            "const x: number = 1; export default x;",
            loader: "ts",
            options: ["format": "cjs"]
        )
        #expect(out.contains("module.exports") && !out.contains(": number"))
        let cjs = try es.transformCJSSync(
            "import a from './a'; export const b = a + 1;",
            file: root.appending(path: "src/x.ts").path
        )
        #expect(cjs.contains("require(\"./a\")"))
    }

    @Test func buildsProjectWithCss() async throws {
        let root = try tmpProject()
        let es = Esbuild(root: root)
        let r = try await es.build(entries: ["src/main.tsx"])
        #expect(r.ok, "\(r.diagnostics)")
        let js = r.files.first { $0.path.hasSuffix(".js") }
        let css = r.files.first { $0.path.hasSuffix(".css") }
        #expect(js?.text.contains("soma") == true && js?.text.contains("jsxDEV") == true)
        #expect(css?.text.contains("color: red") == true)
        let bad = try await es.build(entries: ["src/nao-existe.tsx"])
        #expect(!bad.ok && bad.diagnostics.first?.kind == .error)
    }

    @Test func runtimeRequiresTypeScriptViaEsbuild() async throws {
        let root = try tmpProject()
        let es = Esbuild(root: root)
        _ = try await es.ready()
        let out = Mutex<String>("")
        let p = JSProcess(cwd: root, output: { _, t in out.withLock { $0 += t } })
        p.setTransform(es.cjsTransform)
        try "import { soma } from './src/soma'; console.log('ts ok', soma(2, 3));".write(
            to: root.appending(path: "run.ts"),
            atomically: true,
            encoding: .utf8
        )
        let code = await p.run(file: root.appending(path: "run.ts"))
        #expect(code == 0 && out.withLock { $0 } == "ts ok 5", Comment(rawValue: out.withLock { $0 }))
    }

    @Test func devServerServesHtmlBundleAndCss() async throws {
        let root = try tmpProject()
        let dev = DevServer(root: root)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000)) // porta livre: o app pode estar na 5173
        defer { dev.stop() }
        let (h, _) = try await URLSession.shared.data(from: dev.url)
        let html = String(decoding: h, as: UTF8.self)
        #expect(html.contains("/@odete/js/src/main.tsx") && html.contains("/@odete/css/src/main.tsx") && html
            .contains("WebSocket"))
        let (j, jr) = try await URLSession.shared.data(from: dev.url.appending(path: "@odete/js/src/main.tsx"))
        #expect((jr as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-type")?.contains("javascript") == true)
        #expect(String(decoding: j, as: UTF8.self).contains("soma"))
        let (c, _) = try await URLSession.shared.data(from: dev.url.appending(path: "@odete/css/src/main.tsx"))
        #expect(String(decoding: c, as: UTF8.self).contains("color: red"))
        let (nf, nfr) = try await URLSession.shared.data(from: dev.url.appending(path: "nada.png"))
        #expect((nfr as? HTTPURLResponse)?.statusCode == 404 && !nf.isEmpty)
        // erro de build vira overlay, não 500
        try "import x from './nao'; x();".write(
            to: root.appending(path: "src/main.tsx"),
            atomically: true,
            encoding: .utf8
        )
        await dev.invalidateNow()
        let (e, _) = try await URLSession.shared.data(from: dev.url.appending(path: "@odete/js/src/main.tsx"))
        #expect(String(decoding: e, as: UTF8.self).contains("Não achei"))
        let d = await dev.diagnostics()
        #expect(d.first?.kind == .error)
    }
}
