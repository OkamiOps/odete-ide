import Foundation
@testable import OdeteRuntime
import Testing

/// Projeto no iCloud tem os pacotes em `node_modules.nosync` e `node_modules` é um link
/// relativo para lá (ver `PastaDeModulos`, em OdeteFiles). O `require` e o `fs` do
/// runtime têm que enxergar os pacotes através do link como se fosse a pasta.
struct ModulosPeloLinkTests {
    @Test func requireAtravessaOLinkDeNodeModules() async throws {
        let dir = try tmp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let real = dir.appending(path: "node_modules.nosync")
        let pkg = real.appending(path: "@acme/util")
        try fm.createDirectory(at: pkg.appending(path: "dist"), withIntermediateDirectories: true)
        try #"{"name":"@acme/util","exports":{".":{"require":"./dist/index.cjs"}}}"#
            .write(to: pkg.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try "module.exports = { v: 'pelo-link' };"
            .write(to: pkg.appending(path: "dist/index.cjs"), atomically: true, encoding: .utf8)
        let simples = real.appending(path: "simples")
        try fm.createDirectory(at: simples, withIntermediateDirectories: true)
        try #"{"name":"simples","main":"lib.js"}"#
            .write(to: simples.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try "module.exports = require('@acme/util').v + '!';"
            .write(to: simples.appending(path: "lib.js"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(
            atPath: dir.appending(path: "node_modules").path,
            withDestinationPath: "node_modules.nosync"
        )
        try fm.createDirectory(at: dir.appending(path: "src"), withIntermediateDirectories: true)
        try """
        const fs = require("fs");
        const s = fs.statSync("node_modules");
        console.log(require("simples"), require("@acme/util").v);
        console.log(s.isDirectory(), fs.existsSync("node_modules/simples/package.json"));
        console.log(fs.readdirSync("node_modules").sort().join(","));
        console.log(fs.readdirSync("node_modules", { withFileTypes: true }).filter(d => d.isDirectory()).length);
        console.log(require.resolve("simples").endsWith("/node_modules/simples/lib.js"));
        """.write(to: dir.appending(path: "src/main.js"), atomically: true, encoding: .utf8)
        let cap = Capture()
        let p = JSProcess(cwd: dir, argv: ["src/main.js"], output: cap.handler)
        let watchdog = Task { try? await Task.sleep(for: .seconds(8)); p.kill() }
        let code = await p.run(file: dir.appending(path: "src/main.js"))
        watchdog.cancel()
        #expect(code == 0, Comment(rawValue: cap.stderr))
        #expect(cap.stdout == "pelo-link! pelo-link\ntrue true\n@acme,simples\n2\ntrue")
    }
}
