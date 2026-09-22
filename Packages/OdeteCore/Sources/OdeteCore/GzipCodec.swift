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

    /// Descomprime tudo de uma vez.
    ///
    /// O rodapé do gzip diz o tamanho descomprimido; a saída já nasce desse tamanho e não
    /// cresce aos pedaços. Antes, a entrada era copiada duas vezes (para reindexar e para
    /// tirar o cabeçalho) antes de a descompressão começar — num tarball grande de npm,
    /// era o dobro do pacote na memória à toa.
    public static func decompress(_ data: Data) -> Data? {
        var out = Data()
        if let previsto = tamanhoPrevisto(data) {
            out.reserveCapacity(previsto)
        }
        let ok = (try? descomprimir(data) { out.append($0.assumingMemoryBound(to: UInt8.self)) }) ?? false
        return ok ? out : nil
    }

    /// Descomprime aos pedaços, entregando cada um a `receber` sem juntar o resultado.
    ///
    /// É o que deixa extrair um tarball de npm sem montar o `.tar` inteiro na memória:
    /// quem recebe escreve no disco e esquece. A entrada é lida no lugar, sem cópia.
    /// Aceita gzip ou deflate cru (sem cabeçalho). Devolve `false` se o fluxo estiver
    /// corrompido ou truncado; o que `receber` lançar sobe como está.
    @discardableResult
    public static func descomprimir(
        _ data: Data,
        pedaco: Int = 256 * 1024,
        _ receber: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> Bool {
        try data.withUnsafeBytes { (entrada: UnsafeRawBufferPointer) throws -> Bool in
            guard let base = entrada.baseAddress else { return false }
            var inicio = 0
            var fim = entrada.count
            if let corpo = inicioDoDeflate(entrada) {
                inicio = corpo
                fim = entrada.count - 8
            }
            guard fim > inicio else { return false }
            let fluxo = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { fluxo.deallocate() }
            guard compression_stream_init(fluxo, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                != COMPRESSION_STATUS_ERROR else { return false }
            defer { compression_stream_destroy(fluxo) }
            let saida = UnsafeMutablePointer<UInt8>.allocate(capacity: pedaco)
            defer { saida.deallocate() }
            fluxo.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self) + inicio
            fluxo.pointee.src_size = fim - inicio
            var status: compression_status
            repeat {
                fluxo.pointee.dst_ptr = saida
                fluxo.pointee.dst_size = pedaco
                status = compression_stream_process(fluxo, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { return false }
                let produzidos = pedaco - fluxo.pointee.dst_size
                if produzidos > 0 {
                    try receber(UnsafeRawBufferPointer(start: saida, count: produzidos))
                }
                // Sem saída e sem fim: a entrada acabou antes do fluxo. Truncado.
                if status == COMPRESSION_STATUS_OK, produzidos == 0, fluxo.pointee.src_size == 0 {
                    return false
                }
            } while status == COMPRESSION_STATUS_OK
            return status == COMPRESSION_STATUS_END
        }
    }

    /// Onde começa o deflate dentro de um gzip, pulando o cabeçalho e os campos
    /// opcionais (extra, nome, comentário, crc do cabeçalho). `nil` se não for gzip.
    static func inicioDoDeflate(_ d: UnsafeRawBufferPointer) -> Int? {
        guard d.count > 18, d[0] == 0x1F, d[1] == 0x8B else { return nil }
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
        return d.count - 8 > idx ? idx : nil
    }

    /// O tamanho descomprimido que o rodapé do gzip declara (módulo 2³²). Serve só de
    /// palpite para reservar memória: um valor absurdo é ignorado.
    static func tamanhoPrevisto(_ data: Data) -> Int? {
        guard data.count > 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else { return nil }
        let f = data.endIndex
        let n = Int(data[f - 4]) | Int(data[f - 3]) << 8 | Int(data[f - 2]) << 16 | Int(data[f - 1]) << 24
        return n > 0 && n < 1 << 30 ? n : nil
    }

    static let table: [UInt32] = (0 ..< 256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0 ..< 8 {
            c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data {
            c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }
}
