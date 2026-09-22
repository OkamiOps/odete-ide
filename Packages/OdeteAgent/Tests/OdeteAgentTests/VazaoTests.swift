import Foundation
@testable import OdeteAgent
import OdeteI18n
import Testing

/// O texto chega ficha a ficha, mas vai para a tela em lotes.
@Suite(.serialized) struct VazaoTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func entregas(_ roteiro: [StreamEvent], atraso: Duration = .zero) async throws -> [ChatItem] {
        let root = try tmpProject()
        let host = TestHost(root: root)
        let p = FakeProvider([roteiro])
        p.delay = atraso
        let loop = AgentLoop(provider: p, host: host, patches: PatchStore(root: root))
        var itens: [ChatItem] = []
        for await e in loop.run(
            history: [],
            userText: "oi",
            config: LoopConfig(mode: .chat, permit: .full, model: "f")
        ) {
            if case let .item(i) = e {
                itens.append(i)
            }
        }
        return itens
    }

    /// Quatrocentas fichas de uma vez: antes eram quatrocentas cópias da resposta inteira
    /// atravessando o laço até a tela.
    @Test func muitasFichasPoucasEntregas() async throws {
        let fichas: [StreamEvent] = (0 ..< 400).map { .text("p\($0) ") } + [.done]
        let itens = try await entregas(fichas)
        let textos = itens.compactMap { i -> String? in
            if case let .assistant(_, t) = i {
                return t
            }
            return nil
        }
        #expect(textos.last == (0 ..< 400).map { "p\($0) " }.joined(), "a resposta chegou incompleta")
        #expect(textos.count < 40, "foram \(textos.count) entregas para 400 fichas")
    }

    /// Com o provedor escrevendo aos poucos, a tela acompanha — em lotes, não ficha a ficha.
    @Test func fichasEspacadasSaemEmLotes() async throws {
        let fichas: [StreamEvent] = (0 ..< 150).map { .text("\($0),") } + [.done]
        let itens = try await entregas(fichas, atraso: .milliseconds(2))
        let textos = itens.compactMap { i -> String? in
            if case let .assistant(_, t) = i {
                return t
            }
            return nil
        }
        #expect(textos.last == (0 ..< 150).map { "\($0)," }.joined())
        #expect(textos.count >= 1 && textos.count < 150)
        // Cada lote é o acumulado inteiro: nunca volta atrás.
        for (a, b) in zip(textos, textos.dropFirst()) {
            #expect(b.hasPrefix(a))
        }
    }

    /// O raciocínio fecha quando a resposta começa, e nada atrasado o reabre depois.
    @Test func oRaciocinioFechaEFicaFechado() async throws {
        let itens = try await entregas([.think("pen"), .think("sando"), .text("oi"), .text("!"), .done])
        let pensamentos = itens.compactMap { i -> (String, Bool)? in
            if case let .think(_, t, vivo) = i {
                return (t, vivo)
            }
            return nil
        }
        #expect(pensamentos.last?.0 == "pensando")
        #expect(pensamentos.last?.1 == false, "o raciocínio terminou aberto")
        if let fechou = pensamentos.firstIndex(where: { !$0.1 }) {
            #expect(pensamentos[fechou...].allSatisfy { !$0.1 }, "reabriu depois de fechar")
        }
    }

    /// O retrato cumulativo do modelo da Apple, em pedaços, sem andar pelo texto inteiro.
    @Test func trechoNovoDoRetratoDaApple() {
        var enviados = 0
        var montado = ""
        for retrato in ["Ol", "Olá", "Olá, mu", "Olá, mundo 🌍", "Olá, mundo 🌍!", "Olá, mundo 🌍!"] {
            if let t = AppleProvider.trechoNovo(retrato, enviados: &enviados) {
                montado += t
            }
        }
        #expect(montado == "Olá, mundo 🌍!")
        // Acento que chega depois da letra não muda o número de caracteres — e sumia.
        enviados = 0
        montado = ""
        for retrato in ["cafe", "cafe\u{301}"] {
            if let t = AppleProvider.trechoNovo(retrato, enviados: &enviados) {
                montado += t
            }
        }
        #expect(montado.unicodeScalars.count == 5 && montado == "café")
    }
}
