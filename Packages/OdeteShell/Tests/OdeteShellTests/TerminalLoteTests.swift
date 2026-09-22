import Foundation
@testable import OdeteShell
import Testing

/// A saída do shell chega em pedaços, de qualquer fila, e vai para a tela em lotes. Cada
/// pedaço virava uma entrega no ator principal — e cada entrega refazia a lista inteira do
/// terminal. Aqui se confere que muitos pedaços viram poucas entregas, sem trocar a ordem.
@MainActor
struct TerminalLoteTests {
    func sessao() -> TerminalSession {
        let raiz = FileManager.default.temporaryDirectory.appending(path: "lote-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
        return TerminalSession(shell: Shell(root: raiz), banner: false)
    }

    @Test func milPedacosViramPoucasEntregasNaOrdem() async throws {
        let s = sessao()
        let antes = s.versao
        await Task.detached {
            for i in 0 ..< 1000 {
                s.receber(.out, "\(i)")
            }
        }.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(s.lines.map(\.text) == (0 ..< 1000).map(String.init))
        // Uma entrega por lote de 16 ms; mil pedaços seguidos cabem em muito poucos.
        #expect(s.versao - antes <= 5)
    }

    /// Saída e erro misturados continuam na ordem de chegada, cada um com seu tipo.
    @Test func ordemEntreSaidaEErro() async throws {
        let s = sessao()
        await Task.detached {
            s.receber(.out, "um")
            s.receber(.err, "dois")
            s.receber(.out, "três\nquatro")
        }.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(s.lines.map(\.text) == ["um", "dois", "três", "quatro"])
        #expect(s.lines.map(\.kind) == [.out, .err, .out, .out])
    }

    /// No teto a contagem de linhas para de mudar — era nela que a tela se apoiava para
    /// rolar até o fim, e a rolagem parava. A versão continua subindo.
    @Test func versaoSobeMesmoNoTeto() {
        let s = sessao()
        for i in 0 ..< TerminalSession.teto {
            s.append(.out, "\(i)")
        }
        let versao = s.versao
        #expect(s.lines.count == TerminalSession.teto)
        s.append(.out, "mais uma")
        #expect(s.lines.count == TerminalSession.teto)
        #expect(s.versao > versao)
        #expect(s.lines.last?.text == "mais uma")
        #expect(s.lines.first?.text == "1")
    }

    /// O botão de mandar o último comando depende de haver comando na rolagem, e isso
    /// não pode custar uma varredura da rolagem a cada linha.
    @Test func temEntradaAcompanhaARolagem() {
        let s = sessao()
        #expect(!s.temEntrada)
        s.append(.input, "odete % ls")
        #expect(s.temEntrada)
        for i in 0 ..< TerminalSession.teto {
            s.append(.out, "\(i)")
        }
        #expect(!s.temEntrada, "o comando saiu pelo teto")
        s.append(.input, "odete % pwd")
        #expect(s.temEntrada)
        s.clear()
        #expect(!s.temEntrada)
    }

    /// `clear` no meio de um lote apaga o que veio antes dele, e só.
    @Test func limparNoMeioDoLote() {
        let s = sessao()
        s.append(.out, "velha")
        s.receber(.out, "a")
        s.receber(.out, "\u{1B}[clear]")
        s.receber(.out, "b")
        s.descarregar()
        #expect(s.lines.map(\.text) == ["b"])
    }
}
