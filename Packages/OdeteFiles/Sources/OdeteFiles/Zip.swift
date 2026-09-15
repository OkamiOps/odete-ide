import Compression
import Foundation
import OdeteI18n

/// ZIP mínimo (store/deflate) para compartilhar e receber projetos. Sem dependências.
public enum Zip {
    public struct Error: LocalizedError {
        public var message: String
        public var errorDescription: String? {
            message
        }
    }

    /// Compacta uma pasta. `skip` são nomes de pastas ignoradas em qualquer nível.
    public static func create(
        directory: URL,
        to output: URL,
        skip: Set<String> = ["node_modules", ".build", "dist"]
    ) throws {
        let fm = FileManager.default
        var files: [(rel: String, url: URL)] = []
        guard let en = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            throw Error(message: tr("não deu para ler %1$@", "\(directory.lastPathComponent)"))
        }
        let base = directory.standardizedFileURL.path
        for case let u as URL in en {
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
            let parts = rel.split(separator: "/")
            if parts.contains(where: { skip.contains(String($0)) }) {
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    en.skipDescendants()
                }
                continue
            }
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                continue
            }
            files.append((rel, u))
        }
        files.sort { $0.rel < $1.rel }
        var out = Data()
        var central = Data()
        let now = dosTime(Date())
        for f in files {
            let data = try Data(contentsOf: f.url)
            let name = Data(f.rel.utf8)
            let crc = crc32(data)
            var method: UInt16 = 0
            var payload = data
            if !data.isEmpty, let d = deflate(data), d.count < data.count {
                method = 8
                payload = d
            }
            let offset = UInt32(out.count)
            var local = Data()
            local.u32(0x0403_4B50); local.u16(20); local.u16(0x0800); local.u16(method)
            local.u16(now.time); local.u16(now.date)
            local.u32(crc); local.u32(UInt32(payload.count)); local.u32(UInt32(data.count))
            local.u16(UInt16(name.count)); local.u16(0)
            out.append(local); out.append(name); out.append(payload)
            var c = Data()
            c.u32(0x0201_4B50); c.u16(20); c.u16(20); c.u16(0x0800); c.u16(method)
            c.u16(now.time); c.u16(now.date)
            c.u32(crc); c.u32(UInt32(payload.count)); c.u32(UInt32(data.count))
            c.u16(UInt16(name.count)); c.u16(0); c.u16(0); c.u16(0); c.u16(0); c.u32(0); c.u32(offset)
            c.append(name)
            central.append(c)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        var eocd = Data()
        eocd.u32(0x0605_4B50); eocd.u16(0); eocd.u16(0); eocd.u16(UInt16(files.count)); eocd.u16(UInt16(files.count))
        eocd.u32(UInt32(central.count)); eocd.u32(cdOffset); eocd.u16(0)
        out.append(eocd)
        try out.write(to: output, options: .atomic)
    }

    /// Extrai para `directory` (criada se preciso). Rejeita caminhos que saem da pasta.
    /// Devolve o nome da pasta raiz comum, se o zip tiver uma (ex.: `meu-app/`).
    @discardableResult
    public static func extract(_ file: URL, to directory: URL) throws -> String? {
        let data = try Data(contentsOf: file)
        guard data.count >= 22 else { throw Error(message: tr("zip vazio")) }
        // EOCD: procura a assinatura de trás para frente (comentário até 64 kB).
        var eocdAt: Int?
        var i = data.count - 22
        let floor = max(0, data.count - 65557)
        while i >= floor {
            if data.u32(at: i) == 0x0605_4B50 {
                eocdAt = i
                break
            }
            i -= 1
        }
        guard let eocdAt else { throw Error(message: tr("não é um zip")) }
        let count = Int(data.u16(at: eocdAt + 10))
        var p = Int(data.u32(at: eocdAt + 16))
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var roots = Set<String>()
        for _ in 0 ..< count {
            guard data.u32(at: p) == 0x0201_4B50 else { throw Error(message: tr("diretório central inválido")) }
            let method = data.u16(at: p + 10)
            let csize = Int(data.u32(at: p + 20))
            let usize = Int(data.u32(at: p + 24))
            let nameLen = Int(data.u16(at: p + 28))
            let extraLen = Int(data.u16(at: p + 30))
            let commentLen = Int(data.u16(at: p + 32))
            let offset = Int(data.u32(at: p + 42))
            let name = String(decoding: data[(p + 46) ..< (p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            let parts = name.split(separator: "/").map(String.init)
            guard !name.hasPrefix("/"), !parts.contains(".."), !parts.isEmpty else { continue }
            if name.hasPrefix("__MACOSX/") || parts.last == ".DS_Store" {
                continue
            }
            if parts.count > 1 {
                roots.insert(parts[0])
            } else if !name.hasSuffix("/") {
                roots.insert("")
            }
            let dest = directory.appending(path: name)
            if name.hasSuffix("/") {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            guard data.u32(at: offset) == 0x0403_4B50 else { throw Error(message: tr(
                "entrada inválida: %1$@",
                "\(name)"
            )) }
            let lname = Int(data.u16(at: offset + 26))
            let lextra = Int(data.u16(at: offset + 28))
            let start = offset + 30 + lname + lextra
            guard start + csize <= data.count else { throw Error(message: tr("zip truncado")) }
            let payload = data[start ..< (start + csize)]
            let content: Data
            switch method {
            case 0: content = Data(payload)
            case 8:
                guard let d = inflate(Data(payload), size: usize)
                else { throw Error(message: tr("deflate falhou: %1$@", "\(name)")) }
                content = d
            default: throw Error(message: tr("método %1$@ não suportado: %2$@", "\(method)", "\(name)"))
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: dest, options: .atomic)
        }
        return roots.count == 1 ? roots.first.flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    // MARK: - deflate

    static func deflate(_ src: Data) -> Data? {
        let cap = src.count + 64
        var dst = Data(count: cap)
        let n = dst.withUnsafeMutableBytes { d in
            src.withUnsafeBytes { s in
                compression_encode_buffer(
                    d.bindMemory(to: UInt8.self).baseAddress!, cap,
                    s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard n > 0 else { return nil }
        dst.count = n
        return dst
    }

    static func inflate(_ src: Data, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        var dst = Data(count: size)
        let n = dst.withUnsafeMutableBytes { d in
            src.withUnsafeBytes { s in
                compression_decode_buffer(
                    d.bindMemory(to: UInt8.self).baseAddress!, size,
                    s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard n == size else { return nil }
        return dst
    }

    // MARK: - crc / tempo

    static let crcTable: [UInt32] = (0 ..< 256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0 ..< 8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data {
            c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    static func dosTime(_ d: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let date = UInt16(max((c.year ?? 1980) - 1980, 0) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, date)
    }
}

private extension Data {
    mutating func u16(_ v: UInt16) {
        append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)])
    }

    mutating func u32(_ v: UInt32) {
        u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16))
    }

    func u16(at i: Int) -> UInt16 {
        UInt16(self[startIndex + i]) | UInt16(self[startIndex + i + 1]) << 8
    }

    func u32(at i: Int) -> UInt32 {
        UInt32(u16(at: i)) | UInt32(u16(at: i + 2)) << 16
    }
}
