import Foundation
import Testing
@testable import OdeteRuntime

@Suite struct WasmProbeTests {
    @Test func webAssemblyAvailable() async throws {
        let (code, c) = try await run("""
        const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,3,2,1,0,7,7,1,3,97,100,100,0,0,10,9,1,7,0,32,0,32,1,106,11]);
        const mod = new WebAssembly.Module(bytes);
        const inst = new WebAssembly.Instance(mod, {});
        console.log("sync", inst.exports.add(20, 22));
        const keep = setTimeout(() => console.log("timeout sem resolver"), 1500);
        WebAssembly.instantiate(bytes).then(r => { console.log("async", r.instance.exports.add(1, 2)); clearTimeout(keep); }).catch(e => { console.log("ERR", e.message); clearTimeout(keep); });
        """)
        #expect(code == 0)
        #expect(c.stdout.contains("sync 42"), Comment(rawValue: c.stdout + c.stderr))
        #expect(c.stdout.contains("async 3"), Comment(rawValue: c.stdout + c.stderr))
    }
}
