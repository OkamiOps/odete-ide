import Foundation
@testable import OdeteNpm

/// Cópia fiel do download e da extração de antes do pipeline, só para os testes.
///
/// Serve de régua em dois sentidos: a extração nova tem que deixar no disco exatamente
/// os mesmos arquivos que esta, e o pico de memória e o tempo são comparados com esta
/// rodando no mesmo processo, na mesma hora — numa máquina carregada, comparar com um
/// número medido em outro momento não diz nada.
enum ReferenciaAntiga {
    /// `GzipCodec.decompress` de antes: reindexa a entrada (cópia), recorta o corpo
    /// (outra cópia) e descomprime tudo de uma vez.
    static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else {
            return try? (data as NSData).decompressed(using: .zlib) as Data
        }
        let d = Data(data)
        var idx = 10
        let flg = d[3]
        if flg & 4 != 0 {
            let xlen = Int(d[idx]) | Int(d[idx + 1]) << 8; idx += 2 + xlen
        }
        if flg & 8 != 0 {
            while idx < d.count, d[idx] != 0 {
                idx += 1
            }; idx += 1
        }
        if flg & 16 != 0 {
            while idx < d.count, d[idx] != 0 {
                idx += 1
            }; idx += 1
        }
        if flg & 2 != 0 {
            idx += 2
        }
        guard d.count - 8 > idx else { return nil }
        let body = d.subdata(in: idx ..< (d.count - 8))
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }

    /// `Tar.read` de antes.
    static func lerTar(_ data: Data) -> [Tar.Entry] {
        let d = Data(data)
        var out: [Tar.Entry] = []
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
            case UInt8(ascii: "5"):
                out.append(Tar.Entry(path: name, data: Data(), isDir: true, mode: oct(100 ..< 108), link: nil))
            case UInt8(ascii: "0"), 0:
                out.append(Tar.Entry(path: name, data: body, isDir: false, mode: oct(100 ..< 108), link: nil))
            case UInt8(ascii: "2"):
                out.append(Tar.Entry(
                    path: name,
                    data: Data(),
                    isDir: false,
                    mode: oct(100 ..< 108),
                    link: str(157 ..< 257)
                ))
            default: continue
            }
        }
        return out
    }

    /// `Tar.extractPackage` de antes.
    static func extrair(_ tgz: Data, to dir: URL) throws {
        guard let tar = gunzip(tgz) else { throw NpmError.tarball("gzip inválido") }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for e in lerTar(tar) {
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
                try? fm.removeItem(at: dest); try? fm.createSymbolicLink(atPath: dest.path, withDestinationPath: link)
                continue
            }
            try e.data.write(to: dest, options: .atomic)
            if e.mode & 0o111 != 0 {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
        }
    }

    /// O `materialize` de antes: baixa tudo em lotes de quatro (cada lote esperando o
    /// mais lento), guarda todos os tarballs e só então extrai, um por um.
    ///
    /// O medidor conta o que o código de antes segurava: todos os tarballs até o fim,
    /// mais, durante cada extração, as duas cópias do comprimido e as três do `.tar`
    /// (a saída do gunzip, a cópia do leitor e os corpos dos arquivos).
    static func materializar(
        _ trabalho: [(key: String, url: String)],
        projeto: URL,
        registro: any RegistryClient,
        medidor: MedidorDeMemoria
    ) async {
        var results: [(String, Result<Data, Error>)] = []
        for inicio in stride(from: 0, to: trabalho.count, by: 4) {
            let lote = Array(trabalho[inicio ..< min(inicio + 4, trabalho.count)])
            let baixados = await withTaskGroup(of: (String, Result<Data, Error>).self) { group in
                for item in lote {
                    group.addTask {
                        do { return try await (item.key, .success(registro.tarball(item.url, integrity: nil))) } catch {
                            return (item.key, .failure(error))
                        }
                    }
                }
                var out: [(String, Result<Data, Error>)] = []
                for await r in group {
                    out.append(r)
                }
                return out
            }
            for case let (_, .success(d)) in baixados {
                medidor.segurar(d.count)
            }
            results += baixados
        }
        results.sort { a, b in
            let da = a.0.split(separator: "/").count, db = b.0.split(separator: "/").count
            return da != db ? da < db : a.0 < b.0
        }
        for (key, r) in results {
            guard case let .success(data) = r else { continue }
            let dir = projeto.appending(path: key)
            try? FileManager.default.removeItem(at: dir)
            let f = data.endIndex
            let isize = Int(data[f - 4]) | Int(data[f - 3]) << 8 | Int(data[f - 2]) << 16 | Int(data[f - 1]) << 24
            let transito = 2 * data.count + 3 * isize
            medidor.segurar(transito)
            try? extrair(data, to: dir)
            medidor.soltar(transito)
        }
        for case let (_, .success(d)) in results {
            medidor.soltar(d.count)
        }
    }
}
