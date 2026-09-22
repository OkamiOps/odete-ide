import CryptoKit
import Foundation
import OdeteCore
@testable import OdeteNpm
import Testing

/// A extração aos pedaços tem que deixar no disco o mesmo que a de antes.
struct TarStreamingTests {
    /// Um tar com tudo o que aparece em pacote de verdade — e umas esquisitices.
    static func tarVariado() -> Data {
        var out = Data()
        func arquivo(_ nome: String, _ corpo: Data, modo: Int = 0o644) {
            out.append(Tar.header(name: nome, size: corpo.count, type: UInt8(ascii: "0"), mode: modo))
            out.append(Tar.padded(corpo))
        }
        out.append(Tar.header(name: "package/", size: 0, type: UInt8(ascii: "5"), mode: 0o755))
        arquivo("package/package.json", Data(#"{"name":"x","version":"1.0.0"}"#.utf8))
        arquivo("package/vazio.txt", Data())
        arquivo("package/exato.txt", Data(repeating: 65, count: 512))
        arquivo("package/bin/cli.js", Data("#!/usr/bin/env node\n".utf8), modo: 0o755)
        arquivo("package/lib/fundo/muito/fundo.js", Data(conteudo(300_000, semente: 7).utf8))
        out.append(Tar.header(name: "package/dist", size: 0, type: UInt8(ascii: "5"), mode: 0o755))
        // Nome longo no formato GNU.
        let longo = "package/" + String(repeating: "pasta-comprida/", count: 9) + "arquivo.js"
        let nomeLongo = Data(longo.utf8) + [0]
        out.append(Tar.header(name: "././@LongLink", size: nomeLongo.count, type: UInt8(ascii: "L"), mode: 0o644))
        out.append(Tar.padded(nomeLongo))
        arquivo(String(longo.prefix(99)), Data("longo".utf8))
        // Link simbólico, link físico (ignorado), caminho com `..` (ignorado), sem pasta (ignorado).
        out.append(Tar.header(
            name: "package/atalho.js",
            size: 0,
            type: UInt8(ascii: "2"),
            mode: 0o777,
            link: "bin/cli.js"
        ))
        out.append(Tar.header(name: "package/fisico.js", size: 0, type: UInt8(ascii: "1"), mode: 0o644, link: "a"))
        arquivo("package/../fora.txt", Data("não".utf8))
        arquivo("solto.txt", Data("não".utf8))
        // Um pax global no meio, com corpo, que tem que ser pulado.
        let global = Data("20 comment=qualquer\n".utf8)
        out.append(Tar.header(name: "pax_global_header", size: global.count, type: UInt8(ascii: "g"), mode: 0o644))
        out.append(Tar.padded(global))
        arquivo("package/depois-do-pax.txt", Data("ok".utf8))
        out.append(Data(count: 1024))
        return out
    }

    /// Caminho, tipo, tamanho, permissão, conteúdo e destino de link de tudo que está
    /// debaixo de `raiz`.
    static func retrato(_ raiz: URL) -> [String] {
        let fm = FileManager.default
        var linhas: [String] = []
        let e = fm.enumerator(atPath: raiz.path)
        while let rel = e?.nextObject() as? String {
            let p = raiz.path + "/" + rel
            let attrs = (try? fm.attributesOfItem(atPath: p)) ?? [:]
            let tipo = (attrs[.type] as? FileAttributeType) ?? .typeUnknown
            let perm = String((attrs[.posixPermissions] as? Int) ?? 0, radix: 8)
            switch tipo {
            case .typeSymbolicLink:
                linhas.append("\(rel) link \((try? fm.destinationOfSymbolicLink(atPath: p)) ?? "?")")
            case .typeDirectory:
                linhas.append("\(rel) pasta")
            default:
                let d = fm.contents(atPath: p) ?? Data()
                linhas.append("\(rel) \(d.count) \(perm) \(SHA256.hash(data: d).description)")
            }
        }
        return linhas.sorted()
    }

    func pasta() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "odete-tar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func extracaoNovaDeixaOMesmoQueAAntiga() throws {
        let tgz = try #require(GzipCodec.compress(Self.tarVariado()))
        let antiga = try pasta(), nova = try pasta()
        defer {
            try? FileManager.default.removeItem(at: antiga); try? FileManager.default.removeItem(at: nova)
        }
        try ReferenciaAntiga.extrair(tgz, to: antiga)
        try Tar.extractPackage(tgz, to: nova)
        let a = Self.retrato(antiga), n = Self.retrato(nova)
        #expect(a == n)
        #expect(n.contains { $0.hasPrefix("bin/cli.js ") && $0.contains(" 755 ") })
        #expect(n.contains("atalho.js link bin/cli.js"))
        #expect(n.contains { $0.hasPrefix("depois-do-pax.txt") })
        #expect(!n.contains { $0.hasPrefix("fisico.js") || $0.hasPrefix("fora.txt") || $0.hasPrefix("solto.txt") })
    }

    /// O mesmo pacote, cortado em pedaços de todos os tamanhos: cabeçalho partido no
    /// meio, corpo que acaba na borda do pedaço, enchimento dividido.
    @Test(arguments: [1, 7, 511, 512, 513, 4096, 100_000])
    func pedacosDeQualquerTamanhoDaoOMesmoResultado(pedaco: Int) throws {
        let tar = Self.tarVariado()
        let inteiro = ReferenciaAntiga.lerTar(tar)
        var leitor = Tar.Leitor()
        var achados: [(String, Int)] = []
        var tamanho = 0
        var aberto: String?
        var inicio = 0
        try tar.withUnsafeBytes { bytes in
            while inicio < bytes.count {
                let fim = min(inicio + pedaco, bytes.count)
                try leitor.consumir(UnsafeRawBufferPointer(rebasing: bytes[inicio ..< fim])) { evento in
                    switch evento {
                    case let .inicioDeArquivo(caminho, _, _): aberto = caminho; tamanho = 0
                    case let .dados(d): tamanho += d.count
                    case .fimDeArquivo: achados.append((aberto ?? "?", tamanho))
                    default: break
                    }
                }
                inicio = fim
            }
        }
        let esperado = inteiro.filter { !$0.isDir && $0.link == nil }.map { ($0.path, $0.data.count) }
        #expect(achados.map(\.0) == esperado.map(\.0))
        #expect(achados.map(\.1) == esperado.map(\.1))
        #expect(leitor.terminouInteiro)
    }

    /// Nome comprido no formato pax, que o leitor de antes ignorava (e gravava o arquivo
    /// com o nome cortado).
    @Test func caminhoDoPaxValeParaOProximoArquivo() throws {
        let caminho = "package/" + String(repeating: "abcdefghij/", count: 14) + "fim.js"
        let registro = " path=\(caminho)\n"
        let tamanho = registro.utf8.count + String(registro.utf8.count + 3).count
        let pax = Data("\(tamanho)\(registro)".utf8)
        var tar = Tar.header(name: "PaxHeader/x", size: pax.count, type: UInt8(ascii: "x"), mode: 0o644)
        tar.append(Tar.padded(pax))
        let corpo = Data("conteúdo".utf8)
        tar.append(Tar.header(
            name: String(caminho.suffix(99)),
            size: corpo.count,
            type: UInt8(ascii: "0"),
            mode: 0o644
        ))
        tar.append(Tar.padded(corpo))
        tar.append(Data(count: 1024))
        let dir = try pasta()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Tar.extractPackage(#require(GzipCodec.compress(tar)), to: dir)
        let rel = String(caminho.dropFirst("package/".count))
        #expect(FileManager.default.contents(atPath: dir.appending(path: rel).path) == corpo)
    }

    @Test func pacoteTruncadoFalhaEmVezDeGravarPelaMetade() throws {
        let tgz = try #require(GzipCodec.compress(Self.tarVariado()))
        let dir = try pasta()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: NpmError.self) {
            try Tar.extractPackage(tgz.prefix(tgz.count / 2), to: dir)
        }
    }

    @Test func gzipAosPedacosBateComODeUmaVez() throws {
        let original = Data(conteudo(1_500_000, semente: 3).utf8)
        let gz = try #require(GzipCodec.compress(original))
        #expect(GzipCodec.decompress(gz) == original)
        var juntos = Data()
        var pedacos = 0
        let ok = try GzipCodec.descomprimir(gz, pedaco: 4096) { juntos.append(contentsOf: $0); pedacos += 1 }
        #expect(ok)
        #expect(juntos == original)
        #expect(pedacos > 100)
        // Truncado não passa por inteiro.
        #expect(GzipCodec.decompress(gz.prefix(gz.count / 2)) == nil)
        // Fatia de um Data maior (índice não começa em zero).
        let fatia = (Data([9, 9, 9]) + gz).dropFirst(3)
        #expect(GzipCodec.decompress(fatia) == original)
    }
}
