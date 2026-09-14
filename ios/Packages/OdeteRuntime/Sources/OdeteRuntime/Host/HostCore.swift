import Foundation
import JavaScriptCore
import Security

/// Saída, timers, processo, crypto, os e utilidades.
enum HostCore {
    static func install(_ rt: JSRuntime) {
        let h = rt.host
        let write: @convention(block) (Int, String) -> Void = { [unowned rt] fd, text in rt.emit(fd == 2 ? .err : .out, text) }
        h.setObject(write, forKeyedSubscript: "write" as NSString)

        let setTimer: @convention(block) (Double, Bool) -> Int = { [unowned rt] ms, rep in rt.addTimer(ms: ms, repeats: rep) }
        h.setObject(setTimer, forKeyedSubscript: "setTimer" as NSString)
        let clearTimer: @convention(block) (Int) -> Void = { [unowned rt] id in rt.clearTimer(id) }
        h.setObject(clearTimer, forKeyedSubscript: "clearTimer" as NSString)

        let exit: @convention(block) (Int32) -> Void = { [unowned rt] code in rt.exit(code) }
        h.setObject(exit, forKeyedSubscript: "exit" as NSString)

        h.setObject(rt.cwd.path, forKeyedSubscript: "cwd" as NSString)
        h.setObject(rt.env, forKeyedSubscript: "env" as NSString)
        h.setObject(rt.argv, forKeyedSubscript: "argv" as NSString)
        h.setObject(ProcessInfo.processInfo.operatingSystemVersionString, forKeyedSubscript: "osVersion" as NSString)
        h.setObject(FileManager.default.temporaryDirectory.path, forKeyedSubscript: "tmpdir" as NSString)

        let random: @convention(block) (Int) -> [Int] = { n in
            var bytes = [UInt8](repeating: 0, count: max(n, 0))
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return bytes.map(Int.init)
        }
        h.setObject(random, forKeyedSubscript: "randomBytes" as NSString)

        let now: @convention(block) () -> Double = { Date().timeIntervalSince1970 * 1000 }
        h.setObject(now, forKeyedSubscript: "now" as NSString)
        let hr: @convention(block) () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
        h.setObject(hr, forKeyedSubscript: "perfNow" as NSString)

        let b64enc: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let b64dec: @convention(block) (String) -> String = { s in
            guard let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else { return "" }
            return String(decoding: d, as: UTF8.self)
        }
        h.setObject(b64enc, forKeyedSubscript: "b64enc" as NSString)
        h.setObject(b64dec, forKeyedSubscript: "b64dec" as NSString)

        // zlib
        let gzip: @convention(block) (String, Bool) -> String = { b64, compress in
            guard let data = Data(base64Encoded: b64) else { return "" }
            let out = compress ? Gzip.compress(data) : Gzip.decompress(data)
            return out?.base64EncodedString() ?? ""
        }
        h.setObject(gzip, forKeyedSubscript: "gzip" as NSString)

        // hash sha256/sha1/md5 (base64 in → hex out)
        let hash: @convention(block) (String, String) -> String = { algo, b64 in
            guard let data = Data(base64Encoded: b64) else { return "" }
            return Hash.hex(algo: algo, data: data)
        }
        h.setObject(hash, forKeyedSubscript: "hash" as NSString)

        let log: @convention(block) (String) -> Void = { [unowned rt] s in rt.emit(.err, "[odete] \(s)") }
        h.setObject(log, forKeyedSubscript: "debug" as NSString)
    }
}

import Compression
import CryptoKit

enum Gzip {
    static func compress(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        // envelope gzip: header + deflate raw + crc32 + isize
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        out.append(deflated)
        var crc = CRC32.checksum(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        out.append(Data(bytes: &crc, count: 4))
        out.append(Data(bytes: &size, count: 4))
        return out
    }

    static func decompress(_ data: Data) -> Data? {
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b else {
            return try? (data as NSData).decompressed(using: .zlib) as Data
        }
        var idx = 10
        let flg = data[3]
        if flg & 4 != 0 { let xlen = Int(data[idx]) | Int(data[idx + 1]) << 8; idx += 2 + xlen }
        if flg & 8 != 0 { while idx < data.count, data[idx] != 0 { idx += 1 }; idx += 1 }
        if flg & 16 != 0 { while idx < data.count, data[idx] != 0 { idx += 1 }; idx += 1 }
        if flg & 2 != 0 { idx += 2 }
        let body = data.subdata(in: idx ..< (data.count - 8))
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }
}

enum CRC32 {
    static let table: [UInt32] = (0 ..< 256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

enum Hash {
    static func hex(algo: String, data: Data) -> String {
        switch algo.lowercased() {
        case "sha1": Insecure.SHA1.hash(data: data) |> hexString
        case "sha512": SHA512.hash(data: data) |> hexString
        case "md5": Insecure.MD5.hash(data: data) |> hexString
        default: SHA256.hash(data: data) |> hexString
        }
    }
}

infix operator |>: AdditionPrecedence
func |> <A, B>(a: A, f: (A) -> B) -> B { f(a) }
func hexString(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }
