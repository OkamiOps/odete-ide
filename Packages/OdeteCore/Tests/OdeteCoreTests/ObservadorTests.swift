import Foundation
@testable import OdeteCore
import Testing

/// O observador não tem relógio: ou o sistema avisa, ou ninguém acorda.
///
/// O teste que importa é `paradoNaoAcordaNinguem`. Os outros garantem que, sem o relógio,
/// nada deixou de ser percebido — que é o motivo de o relógio existir antes.
struct ObservadorTests {
    /// Uma pasta temporária que se apaga sozinha no fim do teste.
    static func pasta() throws -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "obs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Espera até `condicao` virar verdade, ou desiste. Sem `sleep` fixo: teste que dorme
    /// um segundo por caso vira suíte de um minuto, e teste que dorme pouco vira falha
    /// intermitente em máquina carregada.
    static func ate(_ segundos: Double = 3, _ condicao: @Sendable () -> Bool) async -> Bool {
        let fim = Date().addingTimeInterval(segundos)
        while Date() < fim {
            if condicao() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condicao()
    }

    final class Contador: @unchecked Sendable {
        private var n = 0
        private var arquivos: [String] = []
        private let l = NSLock()
        func mais() {
            l.lock(); n += 1; l.unlock()
        }

        func mais(_ caminho: String) {
            l.lock(); arquivos.append(caminho); l.unlock()
        }

        var total: Int {
            l.lock(); defer { l.unlock() }; return n
        }

        var vistos: [String] {
            l.lock(); defer { l.unlock() }; return arquivos
        }
    }

    /// O motivo de tudo isto existir.
    ///
    /// Antes havia um relógio de dois segundos que varria a árvore inteira do projeto,
    /// mudando algo ou não — e outro, de um segundo, no servidor de desenvolvimento. Num
    /// iPad isso é bateria e calor gastos para descobrir que nada aconteceu.
    @Test func paradoNaoAcordaNinguem() async throws {
        let raiz = try Self.pasta()
        defer { try? FileManager.default.removeItem(at: raiz) }
        try "oi".write(to: raiz.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let c = Contador()
        let obs = ObservadorDeArquivos(raiz: raiz, aoMudar: { c.mais() })
        obs.comecar()
        defer { obs.parar() }
        try? await Task.sleep(for: .milliseconds(1200))
        #expect(c.total == 0, "acordou \(c.total) vez(es) sem nada ter mudado")
    }

    @Test func arquivoNovoAvisa() async throws {
        let raiz = try Self.pasta()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let c = Contador()
        let obs = ObservadorDeArquivos(raiz: raiz, aoMudar: { c.mais() })
        obs.comecar()
        defer { obs.parar() }
        try? await Task.sleep(for: .milliseconds(150))
        try "novo".write(to: raiz.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        #expect(await Self.ate { c.total > 0 }, "criou arquivo e ninguém percebeu")
    }

    /// Pasta criada **depois** que o observador começou também precisa ser observada,
    /// senão o que nasce dentro dela passa despercebido — era isso que a varredura
    /// periódica cobria de graça.
    @Test func pastaCriadaDepoisTambemEhObservada() async throws {
        let raiz = try Self.pasta()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let c = Contador()
        let obs = ObservadorDeArquivos(raiz: raiz, aoMudar: { c.mais() })
        obs.comecar()
        defer { obs.parar() }
        try? await Task.sleep(for: .milliseconds(150))
        let sub = raiz.appending(path: "nova")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(await Self.ate { c.total > 0 })
        let antes = c.total
        try "dentro".write(to: sub.appending(path: "c.txt"), atomically: true, encoding: .utf8)
        #expect(await Self.ate { c.total > antes }, "arquivo na pasta nova passou batido")
    }

    /// Conteúdo reescrito não mexe na data da pasta: quem só olha pasta não vê o agente
    /// nem o terminal reescrevendo um arquivo aberto. Por isso o arquivo aberto ganha
    /// observador próprio.
    @Test func arquivoAcompanhadoAvisaAoSerReescrito() async throws {
        let raiz = try Self.pasta()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let alvo = raiz.appending(path: "aberto.txt")
        try "antes".write(to: alvo, atomically: false, encoding: .utf8)
        let c = Contador()
        let obs = ObservadorDeArquivos(raiz: raiz, aoMudar: {}, aoMudarArquivo: { c.mais($0) })
        obs.comecar()
        obs.acompanhar([alvo.path])
        defer { obs.parar() }
        try? await Task.sleep(for: .milliseconds(150))
        try "depois".write(to: alvo, atomically: false, encoding: .utf8)
        #expect(await Self.ate { c.vistos.contains(alvo.path) }, "reescrita no arquivo aberto passou batida")
    }

    /// Gravar temporário e renomear por cima é como quase toda ferramenta escreve — e
    /// deixa o descritor antigo apontando para um arquivo que não existe mais. Sem
    /// rearmar, o primeiro aviso é também o último.
    @Test func trocaPorRenomeContinuaAvisando() async throws {
        let raiz = try Self.pasta()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let alvo = raiz.appending(path: "trocado.txt")
        try "um".write(to: alvo, atomically: false, encoding: .utf8)
        let c = Contador()
        let obs = ObservadorDeArquivos(raiz: raiz, aoMudar: {}, aoMudarArquivo: { c.mais($0) })
        obs.comecar()
        obs.acompanhar([alvo.path])
        defer { obs.parar() }
        try? await Task.sleep(for: .milliseconds(150))
        // `atomically: true` é exatamente o temporário-e-renomeia.
        try "dois".write(to: alvo, atomically: true, encoding: .utf8)
        #expect(await Self.ate { !c.vistos.isEmpty }, "a troca por renome não avisou")
        let antes = c.vistos.count
        try? await Task.sleep(for: .milliseconds(250))
        try "três".write(to: alvo, atomically: true, encoding: .utf8)
        #expect(
            await Self.ate { c.vistos.count > antes },
            "avisou uma vez e emudeceu: o observador não rearmou depois do renome"
        )
    }

    /// `node_modules` tem dezenas de milhares de pastas. Um descritor para cada é gastar
    /// o limite do processo para vigiar o que ninguém edita à mão.
    @Test func pastasPesadasFicamDeFora() throws {
        let raiz = try Self.pasta()
        defer { try? FileManager.default.removeItem(at: raiz) }
        for nome in ["node_modules", ".git", "dist", "src"] {
            try FileManager.default.createDirectory(
                at: raiz.appending(path: nome),
                withIntermediateDirectories: true
            )
        }
        let achadas = ObservadorDeArquivos.pastasPara(raiz: raiz, teto: 100)
            .map(\.lastPathComponent)
        #expect(achadas.contains("src"))
        #expect(!achadas.contains("node_modules"))
        #expect(!achadas.contains(".git"))
        #expect(!achadas.contains("dist"))
    }

    /// Projeto gigante não pode derrubar o app por falta de descritor: o observador para
    /// de descer quando chega ao teto, e diz que parou.
    @Test func oTetoDePastasEhRespeitado() throws {
        let raiz = try Self.pasta()
        defer { try? FileManager.default.removeItem(at: raiz) }
        for i in 0 ..< 30 {
            try FileManager.default.createDirectory(
                at: raiz.appending(path: "p\(i)"),
                withIntermediateDirectories: true
            )
        }
        #expect(ObservadorDeArquivos.pastasPara(raiz: raiz, teto: 10).count == 10)
    }
}
