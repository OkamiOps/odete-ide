import Foundation
@testable import OdeteFiles
import Testing

/// Relógio que o teste empurra: agrupar por minuto e podar por idade dependem de tempo.
final class Relogio: @unchecked Sendable {
    private let trava = NSLock()
    private var agora = Date(timeIntervalSince1970: 1_800_000_000)
    func ler() -> Date {
        trava.withLock { agora }
    }

    func andar(_ segundos: TimeInterval) {
        trava.withLock { agora = agora.addingTimeInterval(segundos) }
    }
}

struct HistoricoLocalTests {
    let relogio = Relogio()

    /// Um histórico e um projeto novos, cada um na sua pasta temporária.
    func montar(_ ajuste: (inout HistoricoLocal.Politica) -> Void = { _ in }) throws -> (HistoricoLocal, FileOps) {
        var p = HistoricoLocal.Politica()
        ajuste(&p)
        let relogio = relogio
        let h = try HistoricoLocal(pasta: tempDir(), politica: p, agora: { relogio.ler() })
        return try (h, FileOps(root: tempDir(), historico: h))
    }

    func conteudo(_ h: HistoricoLocal, _ ops: FileOps, _ caminho: String) -> [String] {
        h.versoes(de: caminho, raiz: ops.root).map {
            String(decoding: h.dados($0, de: caminho, raiz: ops.root) ?? Data(), as: UTF8.self)
        }
    }

    /// Quantos conteúdos distintos estão no disco para um arquivo.
    func blobs(_ h: HistoricoLocal, _ ops: FileOps, _ caminho: String) throws -> Int {
        let fm = FileManager.default
        let projetos = try fm.contentsOfDirectory(at: h.pasta, includingPropertiesForKeys: nil)
        var n = 0
        for proj in projetos {
            for dir in (try? fm.contentsOfDirectory(at: proj, includingPropertiesForKeys: nil)) ?? [] {
                let indice = try JSONDecoder().decode(
                    HistoricoLocal.Indice.self,
                    from: Data(contentsOf: dir.appending(path: "indice.json"))
                )
                guard indice.caminho == caminho else { continue }
                n += try fm.contentsOfDirectory(atPath: dir.path).count(where: { $0 != "indice.json" })
            }
        }
        return n
    }

    @Test func guardaOConteudoDeAntes() throws {
        let (h, ops) = try montar()
        try ops.write("src/a.ts", "um", origem: .agente)
        #expect(h.versoes(de: "src/a.ts", raiz: ops.root).isEmpty, "arquivo novo não tem antes")
        try ops.write("src/a.ts", "dois", origem: .agente)
        let v = h.versoes(de: "src/a.ts", raiz: ops.root)
        #expect(v.count == 1)
        #expect(v.first?.origem == .agente)
        #expect(v.first?.tamanho == 2)
        #expect(conteudo(h, ops, "src/a.ts") == ["um"])
        #expect(try ops.read("src/a.ts") == "dois")
    }

    @Test func mesmoConteudoNaoDuplica() throws {
        let (h, ops) = try montar()
        try ops.write("a.txt", String(repeating: "A", count: 400), origem: .agente)
        try ops.write("a.txt", String(repeating: "B", count: 400), origem: .agente)
        // Guardar de novo o que já é a última versão não cria outra.
        h.guardar([ops.root.appending(path: "a.txt")], raiz: ops.root, origem: .git)
        h.guardar([ops.root.appending(path: "a.txt")], raiz: ops.root, origem: .git)
        try ops.write("a.txt", String(repeating: "A", count: 400), origem: .agente)
        try ops.write("a.txt", "fim", origem: .agente)
        // A, B, A: três versões, dois conteúdos no disco.
        #expect(conteudo(h, ops, "a.txt").map { String($0.prefix(1)) } == ["A", "B", "A"])
        #expect(try blobs(h, ops, "a.txt") == 2)
    }

    @Test func podaPorContaEPorIdade() throws {
        let (h, ops) = try montar { $0.versoesPorArquivo = 3 }
        for i in 0 ..< 6 {
            try ops.write("a.txt", "versão \(i)", origem: .agente)
        }
        #expect(conteudo(h, ops, "a.txt") == ["versão 4", "versão 3", "versão 2"])
        #expect(try blobs(h, ops, "a.txt") == 3)

        relogio.andar(31 * 86400)
        try ops.write("a.txt", "depois do mês", origem: .agente)
        #expect(conteudo(h, ops, "a.txt") == ["versão 5"], "o que passou de 30 dias sai")
        #expect(try blobs(h, ops, "a.txt") == 1)
    }

    /// Salvamento automático: uma versão por minuto de edição, e nunca pular o que não
    /// foi o próprio editor que escreveu.
    @Test func agrupaOSalvamentoAutomatico() throws {
        let (h, ops) = try montar()
        try ops.write("a.txt", "original")
        relogio.andar(600)
        try ops.write("a.txt", "digitando 1")
        #expect(conteudo(h, ops, "a.txt") == ["original"])
        for i in 2 ... 5 {
            relogio.andar(5)
            try ops.write("a.txt", "digitando \(i)")
        }
        #expect(conteudo(h, ops, "a.txt") == ["original"], "pausas do mesmo minuto não viram versão")

        relogio.andar(61)
        try ops.write("a.txt", "digitando 6")
        #expect(conteudo(h, ops, "a.txt") == ["digitando 5", "original"])

        // Alguém mexeu no disco no meio do minuto: o que ele escreveu é guardado.
        relogio.andar(5)
        try "de fora".write(to: ops.root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try ops.write("a.txt", "digitando 7")
        #expect(conteudo(h, ops, "a.txt").first == "de fora")

        // Escrita que não é digitação guarda sempre.
        relogio.andar(5)
        try ops.write("a.txt", "do agente", origem: .agente)
        #expect(conteudo(h, ops, "a.txt").first == "digitando 7")
        #expect(h.versoes(de: "a.txt", raiz: ops.root).first?.origem == .agente)
    }

    @Test func restaurarGuardaOAtualAntes() throws {
        let (h, ops) = try montar()
        try ops.write("a.txt", "bom", origem: .agente)
        try ops.write("a.txt", "estragado", origem: .agente)
        let boa = try #require(h.versoes(de: "a.txt", raiz: ops.root).first)
        try h.restaurar(boa, caminho: "a.txt", raiz: ops.root)
        #expect(try ops.read("a.txt") == "bom")
        let v = h.versoes(de: "a.txt", raiz: ops.root)
        #expect(v.first?.origem == .restauracao)
        #expect(conteudo(h, ops, "a.txt").first == "estragado", "restaurar também se desfaz")
    }

    @Test func apagadoApareceParaRestaurar() throws {
        let (h, ops) = try montar()
        try ops.write("src/velho/a.ts", "a")
        try ops.write("src/velho/b.ts", "b")
        try ops.write("src/fica.ts", "fica")
        try ops.delete("src/velho")
        let lista = h.apagados(raiz: ops.root)
        #expect(Set(lista.map(\.caminho)) == ["src/velho/a.ts", "src/velho/b.ts"])
        #expect(lista.allSatisfy { $0.ultima.origem == .apagar })
        #expect(h.apagados(raiz: ops.root, em: "src/velho").count == 2)
        #expect(h.apagados(raiz: ops.root, em: "outra").isEmpty)

        let a = try #require(lista.first { $0.caminho == "src/velho/a.ts" })
        try h.restaurar(a.ultima, caminho: a.caminho, raiz: ops.root)
        #expect(try ops.read("src/velho/a.ts") == "a")
        #expect(h.apagados(raiz: ops.root).map(\.caminho) == ["src/velho/b.ts"])
    }

    @Test func pastasDeRuidoEArquivoGrandeNaoEntram() throws {
        let (h, ops) = try montar { $0.maiorArquivo = 100 }
        for caminho in ["node_modules/x/index.js", "node_modules.nosync/y.js", "dist/app.js", "build/out.js",
                        ".git/config", ".odete/project.json", ".next/cache.json", ".astro/types.d.ts"]
        {
            try ops.write(caminho, "1", origem: .agente)
            try ops.write(caminho, "2", origem: .agente)
            #expect(h.versoes(de: caminho, raiz: ops.root).isEmpty, "\(caminho) é ruído")
        }
        try ops.write("grande.txt", String(repeating: "x", count: 200), origem: .agente)
        try ops.write("grande.txt", "pequeno", origem: .agente)
        #expect(h.versoes(de: "grande.txt", raiz: ops.root).isEmpty, "maior que o teto por arquivo")
        // Apagar a pasta de módulos não percorre milhares de arquivos à toa.
        try ops.delete("node_modules")
        #expect(h.apagados(raiz: ops.root).isEmpty)
    }

    @Test func gravarNumLinkSimbolicoMantemOLink() throws {
        let (h, ops) = try montar()
        try ops.write("real.txt", "antes", origem: .agente)
        try FileManager.default.createSymbolicLink(
            atPath: ops.root.appending(path: "atalho.txt").path,
            withDestinationPath: "real.txt"
        )
        try ops.write("atalho.txt", "depois")
        let destino = try FileManager.default.destinationOfSymbolicLink(
            atPath: ops.root.appending(path: "atalho.txt").path
        )
        #expect(destino == "real.txt", "o link continua link")
        #expect(try ops.read("real.txt") == "depois")
        #expect(conteudo(h, ops, "atalho.txt") == ["antes"])
    }

    @Test func linkQuebradoGravaODestino() throws {
        let (_, ops) = try montar()
        try FileManager.default.createDirectory(
            at: ops.root.appending(path: "docs"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: ops.root.appending(path: "leia.md").path,
            withDestinationPath: "docs/README.md"
        )
        try ops.write("leia.md", "# oi")
        #expect(try ops.read("docs/README.md") == "# oi")
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: ops.root.appending(path: "leia.md").path
        ) == "docs/README.md")
    }

    @Test func renomearLevaOHistorico() throws {
        let (h, ops) = try montar()
        try ops.write("src/a.ts", "1", origem: .agente)
        try ops.write("src/a.ts", "2", origem: .agente)
        _ = try ops.rename("src", to: "lib")
        h.esperar()
        #expect(conteudo(h, ops, "lib/a.ts") == ["1"])
        #expect(h.versoes(de: "src/a.ts", raiz: ops.root).isEmpty)
        #expect(h.apagados(raiz: ops.root).isEmpty, "renomeado não é apagado")
    }

    @Test func textoDoBufferEPortaDeEntradaSemRaiz() throws {
        let (h, ops) = try montar()
        try ops.write("a.txt", "no disco", origem: .agente)
        h.guardar(texto: "só na aba", de: ops.root.appending(path: "a.txt"), raiz: nil, origem: .recarregar)
        let v = h.versoes(de: "a.txt", raiz: ops.root)
        #expect(v.first?.origem == .recarregar)
        #expect(conteudo(h, ops, "a.txt") == ["só na aba"])
    }

    @Test func tetoTiraAsMaisVelhas() throws {
        let (h, ops) = try montar { $0.tetoTotal = 6000 }
        // Conteúdo que não comprime, para o tamanho no disco ser o que se escreveu.
        for i in 0 ..< 12 {
            let bytes = (0 ..< 1000).map { _ in UInt8.random(in: 0 ... 255) }
            try Data(bytes).write(to: ops.root.appending(path: "f\(i).bin"))
            h.guardar([ops.root.appending(path: "f\(i).bin")], raiz: ops.root, origem: .git)
            relogio.andar(1)
        }
        #expect(h.tamanhoUsado() > 6000)
        h.podarPeloTetoAgora()
        #expect(h.tamanhoUsado() <= 6000)
        #expect(h.versoes(de: "f0.bin", raiz: ops.root).isEmpty, "a mais velha sai primeiro")
        #expect(!h.versoes(de: "f11.bin", raiz: ops.root).isEmpty, "a mais nova fica")
        h.limpar()
        #expect(h.tamanhoUsado() == 0)
    }

    @Test func manutencaoTiraOQuePassouDoMes() throws {
        let (h, ops) = try montar()
        try ops.write("a.txt", "1", origem: .agente)
        try ops.write("a.txt", "2", origem: .agente)
        relogio.andar(40 * 86400)
        h.manutencaoSePreciso()
        h.esperar()
        #expect(h.versoes(de: "a.txt", raiz: ops.root).isEmpty)
        #expect(h.tamanhoUsado() < 100)
    }
}
