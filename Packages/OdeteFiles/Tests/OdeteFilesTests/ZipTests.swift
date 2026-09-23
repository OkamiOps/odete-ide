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

    /// "Compartilhar (.zip)" levava `.odete/`: conversas do agente, checkpoints e a
    /// lixeira iam junto para quem recebesse o projeto.
    @Test func naoLevaAPastaOdete() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "zip-\(UUID().uuidString)")
        let src = tmp.appending(path: "app")
        try FileManager.default.createDirectory(
            at: src.appending(path: ".odete/lixeira"),
            withIntermediateDirectories: true
        )
        try "segredo".write(to: src.appending(path: ".odete/conversa.json"), atomically: true, encoding: .utf8)
        try "x".write(to: src.appending(path: ".odete/lixeira/1-a.txt"), atomically: true, encoding: .utf8)
        try "oi".write(to: src.appending(path: "index.html"), atomically: true, encoding: .utf8)
        let zip = tmp.appending(path: "app.zip")
        try Zip.create(directory: src, to: zip)
        let out = tmp.appending(path: "out")
        try Zip.extract(zip, to: out)
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "index.html").path))
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: ".odete").path))
    }

    /// Diretório central apontando para fora do arquivo: antes, índice fora do `Data` e
    /// o app caía. Agora é erro.
    @Test func zipTruncadoDaErroEmVezDeDerrubar() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "zip-\(UUID().uuidString)")
        let src = tmp.appending(path: "app")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0 ..< 5 {
            try String(repeating: "linha \(i)\n", count: 200).write(
                to: src.appending(path: "f\(i).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        let zip = tmp.appending(path: "app.zip")
        try Zip.create(directory: src, to: zip)
        let inteiro = try Data(contentsOf: zip)
        // Tira o meio: sobra o começo e o fim (com o EOCD), e os deslocamentos mentem.
        let cortado = inteiro.prefix(40) + inteiro.suffix(22)
        let ruim = tmp.appending(path: "cortado.zip")
        try cortado.write(to: ruim)
        #expect(throws: Zip.Error.self) { try Zip.extract(ruim, to: tmp.appending(path: "out")) }
        // Cortado no fim de uma entrada.
        let curto = tmp.appending(path: "curto.zip")
        var semFim = inteiro
        semFim.removeSubrange(60 ..< 90)
        try semFim.write(to: curto)
        #expect(throws: Zip.Error.self) { try Zip.extract(curto, to: tmp.appending(path: "out2")) }
    }

    /// Um zip ZIP64 (o que o Finder e o `zip` fazem com muitos arquivos ou arquivos
    /// grandes): contagem 0xFFFF e deslocamento 0xFFFFFFFF no EOCD, com os números de
    /// verdade no registro ZIP64. Antes, lia 0xFFFFFFFF como posição e caía.
    @Test func zip64EhLido() throws {
        let zip = ZipAMao.zip64(nome: "a.txt", conteudo: Data("oi".utf8))
        let tmp = FileManager.default.temporaryDirectory.appending(path: "zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let f = tmp.appending(path: "z64.zip")
        try zip.write(to: f)
        let out = tmp.appending(path: "out")
        try Zip.extract(f, to: out)
        #expect(try String(contentsOf: out.appending(path: "a.txt"), encoding: .utf8) == "oi")
    }

    /// Mais de 65.535 arquivos: `UInt16(files.count)` derrubava o app. Agora sai um
    /// ZIP64, que o próprio `extract` lê de volta.
    @Test func maisDe65535ArquivosNaoDerruba() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "zip-\(UUID().uuidString)")
        let src = tmp.appending(path: "muitos")
        let fm = FileManager.default
        for pasta in 0 ..< 66 {
            let dir = src.appending(path: "p\(pasta)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0 ..< 1000 {
                fm.createFile(atPath: dir.appending(path: "f\(i)").path, contents: nil)
            }
        }
        let zip = tmp.appending(path: "muitos.zip")
        try Zip.create(directory: src, to: zip)
        let out = tmp.appending(path: "out")
        try Zip.extract(zip, to: out)
        #expect(fm.fileExists(atPath: out.appending(path: "p65/f999").path))
        #expect(try fm.contentsOfDirectory(atPath: out.appending(path: "p0").path).count == 1000)
        try? fm.removeItem(at: tmp)
    }

    /// O ZIP64 que o `create` escreve volta inteiro pelo `extract`.
    @Test func zip64DeIdaEVolta() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "zip-\(UUID().uuidString)")
        let src = tmp.appending(path: "cinco")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0 ..< 5 {
            try "arquivo \(i)".write(to: src.appending(path: "f\(i).txt"), atomically: true, encoding: .utf8)
        }
        let zip = tmp.appending(path: "cinco.zip")
        try Zip.create(directory: src, to: zip, skip: Zip.pastasDeFora, limiteDeEntradas: 3)
        let bytes = try Data(contentsOf: zip)
        #expect(bytes.suffix(22).prefix(4) == Data([0x50, 0x4B, 0x05, 0x06]))
        #expect(bytes.suffix(22).dropFirst(8).prefix(2) == Data([0xFF, 0xFF]), "não saiu ZIP64")
        let out = tmp.appending(path: "out")
        try Zip.extract(zip, to: out)
        for i in 0 ..< 5 {
            #expect(try String(contentsOf: out.appending(path: "f\(i).txt"), encoding: .utf8) == "arquivo \(i)")
        }
        // Zipar de novo por cima do anterior troca o arquivo inteiro.
        try Zip.create(directory: src, to: zip)
        try Zip.extract(zip, to: tmp.appending(path: "out2"))
        #expect(FileManager.default.fileExists(atPath: tmp.appending(path: "out2/f4.txt").path))
    }

    /// Lixo com a assinatura do EOCD no fim: não pode derrubar.
    @Test func lixoComCaraDeZipDaErro() throws {
        var d = Data(repeating: 0xAB, count: 100)
        d.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        d.append(Data(repeating: 0xFF, count: 18))
        let tmp = FileManager.default.temporaryDirectory.appending(path: "zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let f = tmp.appending(path: "lixo.zip")
        try d.write(to: f)
        #expect(throws: Zip.Error.self) { try Zip.extract(f, to: tmp.appending(path: "out")) }
    }
}

/// Zips montados byte a byte, para os casos que o `Zip.create` não produz sozinho.
enum ZipAMao {
    static func zip64(nome: String, conteudo: Data) -> Data {
        var d = Data()
        func u16(_ v: UInt16) {
            d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)])
        }
        func u32(_ v: UInt32) {
            u16(UInt16(v & 0xFFFF)); u16(UInt16(v >> 16))
        }
        func u64(_ v: UInt64) {
            u32(UInt32(v & 0xFFFF_FFFF)); u32(UInt32(v >> 32))
        }
        let n = Data(nome.utf8)
        let crc = Zip.crc32(conteudo)
        // local
        u32(0x0403_4B50); u16(45); u16(0); u16(0); u16(0); u16(0); u32(crc)
        u32(UInt32(conteudo.count)); u32(UInt32(conteudo.count)); u16(UInt16(n.count)); u16(0)
        d.append(n); d.append(conteudo)
        // central, com tamanhos e posição no extra ZIP64
        let cd = UInt64(d.count)
        u32(0x0201_4B50); u16(45); u16(45); u16(0); u16(0); u16(0); u16(0); u32(crc)
        u32(0xFFFF_FFFF); u32(0xFFFF_FFFF); u16(UInt16(n.count)); u16(28); u16(0); u16(0); u16(0); u32(0)
        u32(0xFFFF_FFFF)
        d.append(n)
        u16(0x0001); u16(24); u64(UInt64(conteudo.count)); u64(UInt64(conteudo.count)); u64(0)
        let cdSize = UInt64(d.count) - cd
        // registro ZIP64 do fim, localizador e EOCD com os marcadores
        let z64 = UInt64(d.count)
        u32(0x0606_4B50); u64(44); u16(45); u16(45); u32(0); u32(0); u64(1); u64(1); u64(cdSize); u64(cd)
        u32(0x0706_4B50); u32(0); u64(z64); u32(1)
        u32(0x0605_4B50); u16(0); u16(0); u16(0xFFFF); u16(0xFFFF); u32(0xFFFF_FFFF); u32(0xFFFF_FFFF); u16(0)
        return d
    }
}
