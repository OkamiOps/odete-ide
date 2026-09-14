import Compression
import Foundation

/// gzip (RFC 1952) sobre o deflate do Compression.framework.
public enum GzipCodec {
    public static func compress(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])
        out.append(deflated)
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        out.append(Data(bytes: &crc, count: 4))
        out.append(Data(bytes: &size, count: 4))
        return out
    }

    public static func decompress(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else {
            return try? (data as NSData).decompressed(using: .zlib) as Data
        }
        let d = Data(data) // reindexa em 0
        var idx = 10
        let flg = d[3]
        if flg & 4 != 0 { let xlen = Int(d[idx]) | Int(d[idx + 1]) << 8; idx += 2 + xlen }
        if flg & 8 != 0 { while idx < d.count, d[idx] != 0 { idx += 1 }; idx += 1 }
        if flg & 16 != 0 { while idx < d.count, d[idx] != 0 { idx += 1 }; idx += 1 }
        if flg & 2 != 0 { idx += 2 }
        guard d.count - 8 > idx else { return nil }
        let body = d.subdata(in: idx ..< (d.count - 8))
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }

    static let table: [UInt32] = (0 ..< 256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
