import Foundation
@testable import OdeteFiles
import Testing

struct ZipTests {
    @Test func roundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "zip-\(UUID().uuidString)")
        let src = tmp.appending(path: "meu-app")
        try FileManager.default.createDirectory(at: src.appending(path: "src/deep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: src.appending(path: "node_modules/x"),
            withIntermediateDirectories: true
        )
        try "console.log(1)\n".write(to: src.appending(path: "src/main.js"), atomically: true, encoding: .utf8)
        try String(repeating: "abc ", count: 5000).write(
            to: src.appending(path: "src/deep/big.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: src.appending(path: "vazio"))
        try "ignorado".write(to: src.appending(path: "node_modules/x/i.js"), atomically: true, encoding: .utf8)
        let zip = tmp.appending(path: "meu-app.zip")
        try Zip.create(directory: src, to: zip)
        let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int ?? 0
        #expect(size > 0 && size < 20000)

        let out = tmp.appending(path: "out")
        let root = try Zip.extract(zip, to: out)
        #expect(root == nil) // sem pasta raiz comum: entradas relativas à pasta
        #expect(try String(contentsOf: out.appending(path: "src/main.js"), encoding: .utf8) == "console.log(1)\n")
        #expect(try String(contentsOf: out.appending(path: "src/deep/big.txt"), encoding: .utf8).count == 20000)
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "vazio").path))
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "node_modules").path))
    }

    @Test func rejectsTraversal() throws {
        // zip feito à mão com uma entrada "../x" armazenada
        var d = Data()
        let name = Data("../x".utf8), body = Data("y".utf8)
        func u16(_ v: UInt16) {
            d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)])
        }
        func u32(_ v: UInt32) {
            u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16))
        }
        u32(0x0403_4B50); u16(20); u16(0); u16(0); u16(0); u16(0); u32(Zip.crc32(body)); u32(1); u32(1); u16(4); u16(0)
        d.append(name); d.append(body)
        let cd = UInt32(d.count)
        u32(0x0201_4B50); u16(20); u16(20); u16(0); u16(0); u16(0); u16(0); u32(Zip.crc32(body)); u32(1); u32(1); u16(4)
        u16(0); u16(0); u16(0); u16(0); u32(0); u32(0); d.append(name)
        let cdSize = UInt32(d.count) - cd
        u32(0x0605_4B50); u16(0); u16(0); u16(1); u16(1); u32(cdSize); u32(cd); u16(0)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let f = tmp.appending(path: "bad.zip")
        try d.write(to: f)
        let out = tmp.appending(path: "out")
        _ = try Zip.extract(f, to: out)
        #expect(!FileManager.default.fileExists(atPath: tmp.appending(path: "x").path))
    }
}
