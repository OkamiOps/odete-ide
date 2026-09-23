import Compression
import Foundation
import OdeteCore
import OdeteI18n

/// ZIP mínimo (store/deflate) para compartilhar e receber projetos. Sem dependências.
///
/// Lê e escreve ZIP64 quando precisa: mais de 65.535 arquivos, ou um zip que passa de
/// 4 GB. Antes a contagem ia para um `UInt16` sem conferência — com um projeto grande o
/// app caía —, e ler um zip do Finder com muitos arquivos seguia `0xFFFFFFFF` como
/// posição. Toda leitura de posição agora é conferida contra o tamanho do arquivo: zip
/// truncado ou estranho vira erro com frase, nunca queda.
public enum Zip {
    public struct Error: LocalizedError {
        public var message: String
        public var errorDescription: String? {
            message
        }
    }

    /// Pastas que nunca entram num zip de compartilhar, em qualquer nível.
    ///
    /// `node_modules.nosync` é onde ficam os pacotes num projeto do iCloud (ver
    /// `PastaDeModulos`); fica de fora pelo mesmo motivo que `node_modules`. `.odete` é o
    /// que o app guarda do projeto — conversas do agente, checkpoints, a lixeira —, e não
    /// é para ir junto com o código para quem recebe o zip.
    public static let pastasDeFora: Set<String> = [
        "node_modules",
        Ignore.modulosForaDaNuvem,
        ".build",
        "dist",
        ".odete",
    ]

    /// Compacta uma pasta. `skip` são nomes de pastas ignoradas em qualquer nível.
    public static func create(directory: URL, to output: URL, skip: Set<String> = pastasDeFora) throws {
        try create(directory: directory, to: output, skip: skip, limiteDeEntradas: 0xFFFF)
    }

    /// `limiteDeEntradas` acima do qual sai ZIP64; só os testes mexem nele, para não
    /// precisar de 65.536 arquivos para ver o ZIP64 de ida e volta.
    static func create(directory: URL, to output: URL, skip: Set<String>, limiteDeEntradas: Int) throws {
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

        // Grava direto no disco, um arquivo por vez: o zip inteiro montado num `Data`
        // era o projeto todo na memória de uma vez, `.git` incluído.
        let temp = output.deletingLastPathComponent()
            .appending(path: ".\(output.lastPathComponent).\(UUID().uuidString)")
        fm.createFile(atPath: temp.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: temp) else {
            throw Error(message: tr("não deu para ler %1$@", "\(output.lastPathComponent)"))
        }
        var escritor = Escritor(fh: fh)
        do {
            defer { try? fh.close() }
            var central = Data()
            let now = dosTime(Date())
            for f in files {
                let data: Data
                do { data = try Data(contentsOf: f.url, options: .mappedIfSafe) } catch {
                    throw Error(message: tr("não deu para ler %1$@", "\(f.rel)"))
                }
                // Um arquivo sozinho de 4 GB pediria ZIP64 no cabeçalho local também; num
                // iPad isso não cabe na memória de qualquer jeito.
                guard data.count < 0xFFFF_FFFF else {
                    throw Error(message: tr("%1$@ é grande demais para o zip", "\(f.rel)"))
                }
                let name = Data(f.rel.utf8)
                let crc = crc32(data)
                var method: UInt16 = 0
                var payload = data
                if !data.isEmpty, let d = deflate(data), d.count < data.count {
                    method = 8
                    payload = d
                }
                let offset = escritor.posicao
                var local = Data()
                local.u32(0x0403_4B50); local.u16(20); local.u16(0x0800); local.u16(method)
                local.u16(now.time); local.u16(now.date)
                local.u32(crc); local.u32(UInt32(payload.count)); local.u32(UInt32(data.count))
                local.u16(UInt16(name.count)); local.u16(0)
                try escritor.escrever(local)
                try escritor.escrever(name)
                try escritor.escrever(payload)

                // Posição além de 4 GB vai no campo extra ZIP64 do diretório central.
                let longe = offset >= 0xFFFF_FFFF
                var c = Data()
                c.u32(0x0201_4B50); c.u16(longe ? 45 : 20); c.u16(longe ? 45 : 20); c.u16(0x0800); c.u16(method)
                c.u16(now.time); c.u16(now.date)
                c.u32(crc); c.u32(UInt32(payload.count)); c.u32(UInt32(data.count))
                c.u16(UInt16(name.count)); c.u16(longe ? 12 : 0); c.u16(0); c.u16(0); c.u16(0); c.u32(0)
                c.u32(longe ? 0xFFFF_FFFF : UInt32(offset))
                c.append(name)
                if longe {
                    c.u16(0x0001); c.u16(8); c.u64(offset)
                }
                central.append(c)
            }
            let cdOffset = escritor.posicao
            try escritor.escrever(central)
            let cdSize = UInt64(central.count)
            let zip64 = files.count > limiteDeEntradas || cdOffset >= 0xFFFF_FFFF || cdSize >= 0xFFFF_FFFF
            var fim = Data()
            if zip64 {
                let registro = escritor.posicao
                fim.u32(0x0606_4B50); fim.u64(44); fim.u16(45); fim.u16(45); fim.u32(0); fim.u32(0)
                fim.u64(UInt64(files.count)); fim.u64(UInt64(files.count)); fim.u64(cdSize); fim.u64(cdOffset)
                fim.u32(0x0706_4B50); fim.u32(0); fim.u64(registro); fim.u32(1)
                fim.u32(0x0605_4B50); fim.u16(0); fim.u16(0); fim.u16(0xFFFF); fim.u16(0xFFFF)
                fim.u32(0xFFFF_FFFF); fim.u32(0xFFFF_FFFF); fim.u16(0)
            } else {
                fim.u32(0x0605_4B50); fim.u16(0); fim.u16(0); fim.u16(UInt16(files.count)); fim.u16(UInt16(files.count))
                fim.u32(UInt32(cdSize)); fim.u32(UInt32(cdOffset)); fim.u16(0)
            }
            try escritor.escrever(fim)
            try escritor.descarregar()
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        // Só troca o zip antigo pelo novo quando o novo está inteiro.
        if fm.fileExists(atPath: output.path) {
            _ = try fm.replaceItemAt(output, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: output)
        }
    }

    /// Escreve em blocos: um `write` por pedaço de cabeçalho seria uma chamada ao sistema
    /// para cada 30 bytes.
    struct Escritor {
        let fh: FileHandle
        var buffer = Data()
        private(set) var posicao: UInt64 = 0

        init(fh: FileHandle) {
            self.fh = fh
        }

        mutating func escrever(_ d: Data) throws {
            buffer.append(d)
            posicao += UInt64(d.count)
            if buffer.count >= 1 << 20 {
                try descarregar()
            }
        }

        mutating func descarregar() throws {
            guard !buffer.isEmpty else { return }
            try fh.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    /// Extrai para `directory` (criada se preciso). Rejeita caminhos que saem da pasta.
    /// Devolve o nome da pasta raiz comum, se o zip tiver uma (ex.: `meu-app/`).
    @discardableResult
    public static func extract(_ file: URL, to directory: URL) throws -> String? {
        // Mapeado: o zip não é lido inteiro para a memória, só as páginas que se usam.
        let z = try Leitor(Data(contentsOf: file, options: .mappedIfSafe))
        guard z.tamanho >= 22 else { throw Error(message: tr("zip vazio")) }
        // EOCD: procura a assinatura de trás para frente (comentário até 64 kB).
        var eocdAt: Int?
        var i = z.tamanho - 22
        let floor = max(0, z.tamanho - 65557)
        while i >= floor {
            if try z.u32(i) == 0x0605_4B50 {
                eocdAt = i
                break
            }
            i -= 1
        }
        guard let eocdAt else { throw Error(message: tr("não é um zip")) }
        var count = try Int(z.u16(eocdAt + 10))
        var p = try Int(z.u32(eocdAt + 16))
        // ZIP64: os campos do EOCD vêm cheios de 0xFF e os números de verdade estão no
        // registro ZIP64, apontado pelo localizador logo antes do EOCD.
        if try count == 0xFFFF || z.u32(eocdAt + 12) == 0xFFFF_FFFF || z.u32(eocdAt + 16) == 0xFFFF_FFFF {
            let loc = eocdAt - 20
            if loc >= 0, try z.u32(loc) == 0x0706_4B50 {
                let registro = try z.posicao(z.u64(loc + 8))
                guard try z.u32(registro) == 0x0606_4B50 else {
                    throw Error(message: tr("diretório central inválido"))
                }
                count = try z.posicao(z.u64(registro + 32))
                p = try z.posicao(z.u64(registro + 48))
            }
        }
        // Cada entrada do diretório central tem pelo menos 46 bytes: uma contagem maior
        // que isso cabe no arquivo é mentira, e não vale a pena ir até o fim para ver.
        guard p <= z.tamanho, count <= (z.tamanho - p) / 46 else { throw Error(message: tr("zip truncado")) }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var roots = Set<String>()
        for _ in 0 ..< count {
            guard try z.u32(p) == 0x0201_4B50 else { throw Error(message: tr("diretório central inválido")) }
            let method = try z.u16(p + 10)
            let csize32 = try z.u32(p + 20)
            let usize32 = try z.u32(p + 24)
            let nameLen = try Int(z.u16(p + 28))
            let extraLen = try Int(z.u16(p + 30))
            let commentLen = try Int(z.u16(p + 32))
            let offset32 = try z.u32(p + 42)
            let name = try String(decoding: z.fatia(p + 46, nameLen), as: UTF8.self)
            let extra = try z.fatia(p + 46 + nameLen, extraLen)
            p += 46 + nameLen + extraLen + commentLen
            // Os três números que passaram de 32 bits moram no extra 0x0001, nessa ordem.
            var usize = UInt64(usize32), csize = UInt64(csize32), offsetLocal = UInt64(offset32)
            if usize32 == 0xFFFF_FFFF || csize32 == 0xFFFF_FFFF || offset32 == 0xFFFF_FFFF {
                var campos = try Leitor(extra).zip64(
                    usize: usize32 == 0xFFFF_FFFF,
                    csize: csize32 == 0xFFFF_FFFF,
                    offset: offset32 == 0xFFFF_FFFF
                ).makeIterator()
                if usize32 == 0xFFFF_FFFF {
                    usize = campos.next() ?? usize
                }
                if csize32 == 0xFFFF_FFFF {
                    csize = campos.next() ?? csize
                }
                if offset32 == 0xFFFF_FFFF {
                    offsetLocal = campos.next() ?? offsetLocal
                }
            }
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
            let offset = try z.posicao(offsetLocal)
            guard try z.u32(offset) == 0x0403_4B50 else { throw Error(message: tr(
                "entrada inválida: %1$@",
                "\(name)"
            )) }
            let lname = try Int(z.u16(offset + 26))
            let lextra = try Int(z.u16(offset + 28))
            let start = offset + 30 + lname + lextra
            let tamanho = try z.posicao(csize)
            let payload = try z.fatia(start, tamanho)
            // O tamanho vem do próprio zip e vira alocação: um número absurdo pedia
            // gigabytes de uma vez. 2 GB por arquivo, e nada que o deflate não consiga
            // produzir a partir do que está comprimido (a razão máxima dele é ~1032:1).
            guard usize < 1 << 31, method != 8 || usize <= csize * 1032 + 1024 else {
                throw Error(message: tr("%1$@ é grande demais para o zip", "\(name)"))
            }
            let content: Data
            switch method {
            case 0: content = payload
            case 8:
                guard let d = inflate(payload, size: Int(usize))
                else { throw Error(message: tr("deflate falhou: %1$@", "\(name)")) }
                content = d
            default: throw Error(message: tr("método %1$@ não suportado: %2$@", "\(method)", "\(name)"))
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: dest, options: .atomic)
        }
        return roots.count == 1 ? roots.first.flatMap { $0.isEmpty ? nil : $0 } : nil
    }

    /// Leitura de inteiros do zip com a conferência que faltava: posição fora do arquivo
    /// é "zip truncado", nunca índice fora do `Data`.
    struct Leitor {
        let dados: Data
        var tamanho: Int {
            dados.count
        }

        init(_ dados: Data) {
            self.dados = dados
        }

        func fatia(_ i: Int, _ n: Int) throws -> Data {
            guard i >= 0, n >= 0, i <= tamanho - n else { throw Error(message: tr("zip truncado")) }
            let a = dados.startIndex + i
            return dados.subdata(in: a ..< (a + n))
        }

        func u16(_ i: Int) throws -> UInt16 {
            guard i >= 0, i <= tamanho - 2 else { throw Error(message: tr("zip truncado")) }
            let a = dados.startIndex + i
            return UInt16(dados[a]) | UInt16(dados[a + 1]) << 8
        }

        func u32(_ i: Int) throws -> UInt32 {
            try UInt32(u16(i)) | UInt32(u16(i + 2)) << 16
        }

        func u64(_ i: Int) throws -> UInt64 {
            try UInt64(u32(i)) | UInt64(u32(i + 4)) << 32
        }

        /// Um número do zip usado como posição ou tamanho: tem de caber no arquivo.
        func posicao(_ v: UInt64) throws -> Int {
            guard v <= UInt64(tamanho) else { throw Error(message: tr("zip truncado")) }
            return Int(v)
        }

        /// Os valores de 64 bits do campo extra ZIP64 (id 0x0001), na ordem do formato.
        func zip64(usize: Bool, csize: Bool, offset: Bool) throws -> [UInt64] {
            var i = 0
            while i + 4 <= tamanho {
                let id = try u16(i), n = try Int(u16(i + 2))
                if id == 0x0001 {
                    var out: [UInt64] = []
                    var j = i + 4
                    for pedido in [usize, csize, offset] where pedido {
                        guard j + 8 <= i + 4 + n else { break }
                        try out.append(u64(j))
                        j += 8
                    }
                    return out
                }
                i += 4 + n
            }
            throw Error(message: tr("diretório central inválido"))
        }
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
        guard !src.isEmpty else { return nil }
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
        // Em partes com tipo explícito: numa expressão só, o Xcode do CI desiste de inferir
        // os tipos ("unable to type-check this expression in reasonable time").
        let hora: Int = c.hour ?? 0, minuto: Int = c.minute ?? 0, segundo: Int = c.second ?? 0
        let ano: Int = max((c.year ?? 1980) - 1980, 0), mes: Int = c.month ?? 1, dia: Int = c.day ?? 1
        let time: Int = (hora << 11) | (minuto << 5) | (segundo / 2)
        let date: Int = (ano << 9) | (mes << 5) | dia
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: date))
    }
}

private extension Data {
    mutating func u16(_ v: UInt16) {
        append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)])
    }

    mutating func u32(_ v: UInt32) {
        u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16))
    }

    mutating func u64(_ v: UInt64) {
        u32(UInt32(v & 0xFFFF_FFFF)); u32(UInt32(v >> 32))
    }
}
