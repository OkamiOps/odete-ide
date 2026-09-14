import Foundation
import OdeteCore

/// Leitor e escritor tar (ustar + GNU longname) em memória.
public enum Tar {
    public struct Entry: Sendable {
        public var path: String; public var data: Data; public var isDir: Bool; public var mode: Int; public var link: String?
    }

    public static func read(_ data: Data) throws -> [Entry] {
        let d = Data(data)
        var out: [Entry] = []
        var off = 0
        var pendingLong: String?
        while off + 512 <= d.count {
            let h = d.subdata(in: off ..< off + 512)
            if h.allSatisfy({ $0 == 0 }) {
                break
            }
            func str(_ r: Range<Int>) -> String {
                String(decoding: h[r].prefix { $0 != 0 }, as: UTF8.self)
            }
            func oct(_ r: Range<Int>) -> Int {
                Int(str(r).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            }
            var name = str(0 ..< 100)
            let size = oct(124 ..< 136)
            let type = h[156]
            let prefix = str(345 ..< 500)
            if !prefix.isEmpty {
                name = prefix + "/" + name
            }
            if let l = pendingLong {
                name = l; pendingLong = nil
            }
            let body = d.subdata(in: (off + 512) ..< min(off + 512 + size, d.count))
            off += 512 + ((size + 511) / 512) * 512
            switch type {
            case UInt8(ascii: "L"): pendingLong = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self); continue
            case UInt8(ascii: "5"): out.append(Entry(
                    path: name,
                    data: Data(),
                    isDir: true,
                    mode: oct(100 ..< 108),
                    link: nil
                ))
            case UInt8(ascii: "0"), 0: out.append(Entry(
                    path: name,
                    data: body,
                    isDir: false,
                    mode: oct(100 ..< 108),
                    link: nil
                ))
            case UInt8(ascii: "2"): out.append(Entry(
                    path: name,
                    data: Data(),
                    isDir: false,
                    mode: oct(100 ..< 108),
                    link: str(157 ..< 257)
                ))
            default: continue // pax headers etc.
            }
        }
        return out
    }

    public static func write(_ entries: [Entry]) -> Data {
        var out = Data()
        for e in entries {
            var name = e.path
            if name.utf8.count > 99 {
                let l = Data(name.utf8) + [0]
                out.append(header(name: "././@LongLink", size: l.count, type: UInt8(ascii: "L"), mode: 0o644))
                out.append(padded(l))
            }
            name = String(name.utf8.prefix(99))!
            out.append(header(
                name: name,
                size: e.isDir ? 0 : e.data.count,
                type: e.isDir ? UInt8(ascii: "5") : UInt8(ascii: "0"),
                mode: e.mode
            ))
            if !e.isDir {
                out.append(padded(e.data))
            }
        }
        out.append(Data(count: 1024))
        return out
    }

    static func padded(_ d: Data) -> Data {
        d + Data(count: (512 - d.count % 512) % 512)
    }

    static func header(name: String, size: Int, type: UInt8, mode: Int) -> Data {
        var h = Data(count: 512)
        func put(_ s: String, at: Int, len: Int) {
            let b = Array(s.utf8.prefix(len)); h.replaceSubrange(
                at ..< at + b.count,
                with: b
            )
        }
        put(name, at: 0, len: 100)
        put(String(format: "%07o", mode), at: 100, len: 8)
        put("0000000", at: 108, len: 8); put("0000000", at: 116, len: 8)
        put(String(format: "%011o", size), at: 124, len: 12)
        put(String(format: "%011o", Int(Date().timeIntervalSince1970)), at: 136, len: 12)
        put("        ", at: 148, len: 8)
        h[156] = type
        put("ustar", at: 257, len: 6); put("00", at: 263, len: 2)
        let sum = h.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum) + "\0 ", at: 148, len: 8)
        return h
    }

    /// Extrai um `.tgz` de pacote npm (prefixo `package/` removido) em `dir`.
    public static func extractPackage(_ tgz: Data, to dir: URL) throws {
        guard let tar = GzipCodec.decompress(tgz) else { throw NpmError.tarball("gzip inválido") }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for e in try read(tar) {
            var rel = e.path
            if let i = rel.firstIndex(of: "/") {
                rel = String(rel[rel.index(after: i)...])
            } else {
                continue
            }
            guard !rel.isEmpty, !rel.contains("..") else { continue }
            let dest = dir.appending(path: rel)
            if e.isDir {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true); continue
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let link = e.link {
                try? fm.removeItem(at: dest); try? fm.createSymbolicLink(
                    atPath: dest.path,
                    withDestinationPath: link
                ); continue
            }
            try e.data.write(to: dest, options: .atomic)
            if e.mode & 0o111 != 0 {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
        }
    }
}
