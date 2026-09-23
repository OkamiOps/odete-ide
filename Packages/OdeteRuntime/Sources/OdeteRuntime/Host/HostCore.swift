import Foundation
import JavaScriptCore
import Security

/// Saída, timers, processo, crypto, os e utilidades.
enum HostCore {
    static func install(_ rt: JSRuntime) {
        let h = rt.host
        let write: @convention(block) (Int, String) -> Void = { [unowned rt] fd, text in
            if rt.lancarSeInterrompido() {
                return
            }
            rt.emit(fd == 2 ? .err : .out, text)
        }
        h.setObject(write, forKeyedSubscript: "write" as NSString)

        let setTimer: @convention(block) (Double, Bool) -> Int = { [unowned rt] ms, rep in rt.addTimer(
            ms: ms,
            repeats: rep
        ) }
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

        let asyncDone: @convention(block) (Int, Bool, String) -> Void = { [unowned rt] id, ok, payload in
            guard let cont = rt.asyncCalls.removeValue(forKey: id) else { return }
            rt.endWork()
            if ok {
                cont.resume(returning: payload)
            } else {
                cont.resume(throwing: RuntimeError(message: payload))
            }
        }
        h.setObject(asyncDone, forKeyedSubscript: "asyncDone" as NSString)

        let log: @convention(block) (String) -> Void = { [unowned rt] s in rt.emit(.err, "[odete] \(s)") }
        h.setObject(log, forKeyedSubscript: "debug" as NSString)

        let refTimer: @convention(block) (Int, Bool) -> Void = { [unowned rt] id, ref in rt.refTimer(id, ref) }
        h.setObject(refTimer, forKeyedSubscript: "refTimer" as NSString)

        // O stdin inteiro (o que veio pelo pipe), ou null quando não há nada ligado.
        let stdin: @convention(block) () -> Any = { [unowned rt] in
            guard let d = rt.entrada else { return NSNull() }
            return rt.bytes(d)
        }
        h.setObject(stdin, forKeyedSubscript: "stdin" as NSString)

        // `import(` fora do esbuild (CJS carregado cru, `new Function`): ver ReescritaDeImport.
        let reescreverImport: @convention(block) (String) -> Any = { src in
            ReescritaDeImport.reescrever(src) ?? NSNull()
        }
        h.setObject(reescreverImport, forKeyedSubscript: "reescreverImport" as NSString)
    }
}

import CommonCrypto
import Compression
import CryptoKit

enum Gzip {
    static func compress(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        // envelope gzip: header + deflate raw + crc32 + isize
        var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])
        out.append(deflated)
        var crc = CRC32.checksum(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        out.append(Data(bytes: &crc, count: 4))
        out.append(Data(bytes: &size, count: 4))
        return out
    }

    static func decompress(_ data: Data) -> Data? {
        guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B else {
            return try? (data as NSData).decompressed(using: .zlib) as Data
        }
        var idx = 10
        let flg = data[3]
        if flg & 4 != 0 {
            let xlen = Int(data[idx]) | Int(data[idx + 1]) << 8; idx += 2 + xlen
        }
        if flg & 8 != 0 {
            while idx < data.count, data[idx] != 0 {
                idx += 1
            }; idx += 1
        }
        if flg & 16 != 0 {
            while idx < data.count, data[idx] != 0 {
                idx += 1
            }; idx += 1
        }
        if flg & 2 != 0 {
            idx += 2
        }
        let body = data.subdata(in: idx ..< (data.count - 8))
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }
}

enum CRC32 {
    static let table: [UInt32] = (0 ..< 256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0 ..< 8 {
            c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data {
            c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }
}

enum Hash {
    static func hex(algo: String, data: Data) -> String {
        hexString(digest(algo: algo, data: data) ?? [])
    }

    /// O nome como o Node aceita: `SHA256`, `sha-256`, `RSA-SHA256` viram `sha256`.
    static func normalizar(_ algo: String) -> String {
        var a = algo.lowercased()
        if a.hasPrefix("rsa-") {
            a.removeFirst(4)
        }
        if a.hasPrefix("sha3-") {
            return a
        }
        return a.replacingOccurrences(of: "-", with: "")
    }

    /// O digest cru; nil para algoritmo que não existe aqui (antes caía no SHA-256 calado,
    /// e um `createHash("sha3-256")` devolvia outro hash sem aviso).
    static func digest(algo: String, data: some DataProtocol) -> [UInt8]? {
        switch normalizar(algo) {
        case "sha1": Array(Insecure.SHA1.hash(data: data))
        case "sha256": Array(SHA256.hash(data: data))
        case "sha384": Array(SHA384.hash(data: data))
        case "sha512": Array(SHA512.hash(data: data))
        case "md5": Array(Insecure.MD5.hash(data: data))
        case "sha3-256": sha3(SHA3_256(), data)
        case "sha3-384": sha3(SHA3_384(), data)
        case "sha3-512": sha3(SHA3_512(), data)
        default: nil
        }
    }

    private static func sha3(_ h: SHA3_256, _ data: some DataProtocol) -> [UInt8] {
        var h = h
        for r in data.regions {
            r.withUnsafeBytes { h.update(bufferPointer: $0) }
        }
        return Array(h.finalize())
    }

    private static func sha3(_ h: SHA3_384, _ data: some DataProtocol) -> [UInt8] {
        var h = h
        for r in data.regions {
            r.withUnsafeBytes { h.update(bufferPointer: $0) }
        }
        return Array(h.finalize())
    }

    private static func sha3(_ h: SHA3_512, _ data: some DataProtocol) -> [UInt8] {
        var h = h
        for r in data.regions {
            r.withUnsafeBytes { h.update(bufferPointer: $0) }
        }
        return Array(h.finalize())
    }

    static func hmac(algo: String, chave: Data, data: some DataProtocol) -> [UInt8]? {
        let k = SymmetricKey(data: chave)
        switch normalizar(algo) {
        case "sha1": return Array(HMAC<Insecure.SHA1>.authenticationCode(for: Array(data), using: k))
        case "sha256": return Array(HMAC<SHA256>.authenticationCode(for: Array(data), using: k))
        case "sha384": return Array(HMAC<SHA384>.authenticationCode(for: Array(data), using: k))
        case "sha512": return Array(HMAC<SHA512>.authenticationCode(for: Array(data), using: k))
        case "md5": return Array(HMAC<Insecure.MD5>.authenticationCode(for: Array(data), using: k))
        default: return nil
        }
    }

    static func pbkdf2(senha: Data, sal: Data, iteracoes: Int, tamanho: Int, algo: String) -> [UInt8]? {
        let prf: CCPseudoRandomAlgorithm
        switch normalizar(algo) {
        case "sha1": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        case "sha256": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        case "sha384": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
        case "sha512": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
        default: return nil
        }
        var saida = [UInt8](repeating: 0, count: max(tamanho, 0))
        let r = senha.withUnsafeBytes { s in
            sal.withUnsafeBytes { sl in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    s.baseAddress?.assumingMemoryBound(to: CChar.self), s.count,
                    sl.baseAddress?.assumingMemoryBound(to: UInt8.self), sl.count,
                    prf, UInt32(max(iteracoes, 1)), &saida, saida.count
                )
            }
        }
        return r == kCCSuccess ? saida : nil
    }
}

func hexString(_ d: some Sequence<UInt8>) -> String {
    d.map { String(format: "%02x", $0) }.joined()
}
