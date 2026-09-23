import Foundation
@testable import OdeteAgent
import OdeteI18n
import Testing

/// Compactação da conversa — o desenho do opencode (`session/compaction.ts`).
@Suite(.serialized) struct CompactacaoTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func linhas(_ n: Int, _ marca: String) -> String {
        (0 ..< n).map { "\(marca) linha \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n")
    }

    // MARK: peças

    @Test func estouroDeJanelaEhReconhecido() {
        #expect(Compactacao
            .ehEstouro("HTTP 400: {\"error\":{\"message\":\"prompt is too long: 250000 tokens > 200000 maximum\"}}"))
        #expect(Compactacao.ehEstouro("HTTP 413"))
        #expect(Compactacao.ehEstouro("This model's maximum context length is 128000 tokens"))
        #expect(Compactacao.ehEstouro("Your input exceeds the context window of this model"))
        #expect(!Compactacao.ehEstouro("HTTP 429: rate limit exceeded"))
        #expect(!Compactacao.ehEstouro("HTTP 500: overloaded"))
    }

    /// Na Anthropic o cache soma; na OpenAI ele já está dentro da entrada.
    @Test func usoDaRodadaPorProvedor() {
        let u = TokenUse(input: 1000, output: 200, cache: 5000)
        #expect(Compactacao.tokensDaRodada(u, kind: .claude) == 6200)
        #expect(Compactacao.tokensDaRodada(u, kind: .openaiCompat) == 5200)
        #expect(Compactacao.tokensDaRodada(TokenUse(), kind: .claude) == nil)
        #expect(Compactacao.passou(160_000, janela: 200_000) && !Compactacao.passou(159_999, janela: 200_000))
    }

    /// A poda guarda as saídas mais recentes até `podaProtege` e apaga as de antes — e
    /// tira o raciocínio de toda a conversa, que depois de uma edição não vale mais.
    @Test func podaGuardaAsRecentesEApagaAsAntigas() throws {
        var ms: [AgentMessage] = [.user("pedido")]
        for i in 0 ..< 10 {
            ms.append(AgentMessage(role: .assistant, content: "", thinking: "pensei \(i)", toolCalls: [
                ToolCall(id: "\(i)", name: "read_file", arguments: "{}"),
            ]))
            ms.append(.tool("\(i)", String(repeating: "\(i)", count: 40000))) // 10 mil tokens cada
        }
        let (podado, liberados) = try #require(Compactacao.podar(ms))
        let resultados = podado.filter { $0.role == .tool }
        #expect(resultados.prefix(6).allSatisfy { $0.content == Compactacao.marcaDePoda })
        #expect(resultados.suffix(4).allSatisfy { $0.content != Compactacao.marcaDePoda })
        #expect(liberados > 50000)
        #expect(podado.allSatisfy { $0.thinking == nil }, "o raciocínio ficou depois de mexer no histórico")
        #expect(Transcricao.fecha(podado))
        // Já podado: a próxima para na marca e não acha o que tirar.
        #expect(Compactacao.podar(podado) == nil)
        // Pouca coisa para podar: não mexe.
        #expect(Compactacao.podar(Array(ms.prefix(9))) == nil)
    }

    /// O resumo substitui o começo; o pedido do turno fica, uma vez só, e a cauda começa
    /// numa mensagem que não é resultado órfão.
    @Test func montarGuardaOPedidoEFechaOsPares() throws {
        var ms: [AgentMessage] = [.user("pedido antigo"), AgentMessage(role: .assistant, content: "feito")]
        let pedido = ms.count
        ms.append(.user("pedido de agora"))
        for i in 0 ..< 8 {
            ms.append(AgentMessage(role: .assistant, content: "", thinking: "hm", toolCalls: [
                ToolCall(id: "\(i)", name: "grep", arguments: "{}"),
            ]))
            ms.append(.tool("\(i)", String(repeating: "r", count: 12000)))
        }
        let plano = try #require(Compactacao.planejar(ms, pedido: pedido, janela: 100_000))
        let novo = Compactacao.montar(ms, plano: plano, resumo: "## Objetivo\n- x", pedido: pedido, continuar: true)
        #expect(Compactacao.ehResumo(novo.mensagens[0]))
        #expect(novo.mensagens.filter { $0.content == "pedido de agora" }.count == 1)
        #expect(novo.pedido.map { novo.mensagens[$0].content } == "pedido de agora")
        #expect(!novo.mensagens.contains { $0.content == "pedido antigo" })
        #expect(Transcricao.fecha(novo.mensagens))
        #expect(novo.mensagens.allSatisfy { $0.thinking == nil })
        #expect(novo.mensagens.count < ms.count)
        // Um segundo resumo leva o primeiro junto, como resumo anterior.
        let segundo = try #require(Compactacao.planejar(
            novo.mensagens + (0 ..< 6).flatMap { i in [
                AgentMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [ToolCall(id: "n\(i)", name: "grep", arguments: "{}")]
                ),
                AgentMessage.tool("n\(i)", String(repeating: "s", count: 12000)),
            ] },
            pedido: novo.pedido,
            janela: 100_000
        ))
        #expect(segundo.resumoAnterior == "## Objetivo\n- x")
        #expect(!segundo.cabeca.contains(where: Compactacao.ehResumo))
    }

    /// Conversa inteira na cauda: não há o que resumir.
    @Test func conversaCurtaNaoTemOQueResumir() {
        let ms: [AgentMessage] = [.user("oi"), AgentMessage(role: .assistant, content: "olá")]
        #expect(Compactacao.planejar(ms, pedido: 0, janela: 200_000) == nil)
    }

    // MARK: no laço

    /// Passou de 80% da janela: o laço resume o começo, guarda o pedido deste turno e
    /// segue sozinho, sem ninguém mandar "continua".
    @Test func aOitentaPorCentoResumeESegue() async throws {
        let root = try tmpProject()
        try linhas(700, "grande").write(to: root.appending(path: "grande.txt"), atomically: true, encoding: .utf8)
        let p = FakeProvider([
            [.tools([call("read_file", ["path": "grande.txt"])]), .usage(TokenUse(input: 11000, output: 50)), .done],
            [.text("## Objetivo\n- terminar o segundo pedido"), .done],
            [.text("pronto"), .done],
        ])
        let loop = AgentLoop(provider: p, host: TestHost(root: root), patches: PatchStore(root: root))
        var cfg = LoopConfig(mode: .chat, permit: .full, model: "m")
        cfg.janelaDeContexto = 20000
        let antes: [AgentMessage] = [
            .user("primeiro pedido"),
            AgentMessage(role: .assistant, content: "", thinking: "pensando no primeiro", toolCalls: [
                ToolCall(id: "r0", name: "read_file", arguments: #"{"path":"velho.txt"}"#),
            ]),
            .tool("r0", String(repeating: "v", count: 30000)),
            AgentMessage(role: .assistant, content: "resposta antiga", thinking: "hm"),
        ]
        var usos: [Int] = []
        var itens: [ChatItem] = []
        var historia: [AgentMessage] = []
        for await e in loop.run(history: antes, userText: "segundo pedido", config: cfg) {
            switch e {
            case let .contexto(usados, janela):
                #expect(janela == 20000)
                usos.append(usados)
            case let .item(i): itens.append(i)
            case let .history(h): historia = h
            default: break
            }
        }
        let turnos = p.turns.withLock { $0 }
        try #require(turnos.count == 3, "esperava rodada, resumo e rodada; vieram \(turnos.count)")
        // O pedido de resumo: sem ferramentas, com o sistema do resumo e a conversa em texto.
        #expect(turnos[1].tools.isEmpty && turnos[1].system == Compactacao.sistema)
        #expect(turnos[1].messages.count == 1 && turnos[1].messages[0].content.contains("<conversa>")
            && turnos[1].messages[0].content.contains("[Pessoa]: primeiro pedido"))
        // Depois: o resumo, o pedido deste turno, e nada do primeiro.
        let depois = turnos[2].messages
        #expect(Compactacao.ehResumo(depois[0]) && depois[0].content.contains("terminar o segundo pedido"))
        #expect(depois.contains { $0.role == .user && Prompts.semContextoDoTurno($0.content) == "segundo pedido" })
        #expect(!depois.contains { $0.content == "primeiro pedido" })
        #expect(Transcricao.fecha(depois))
        #expect(depois.allSatisfy { $0.thinking == nil })
        // O cartão e o medidor.
        let cartao = itens.compactMap { i -> (String, Int, Int)? in
            if case let .compactado(_, resumo, antes, depois) = i, !resumo.isEmpty {
                return (resumo, antes, depois)
            }
            return nil
        }.last
        #expect(cartao != nil && cartao!.2 < cartao!.1, "sem cartão de compactação, ou não diminuiu")
        #expect(usos.contains { $0 >= 16000 } && usos.last! < 16000)
        #expect(Compactacao.ehResumo(historia[0]) && historia.last?.content == "pronto")
        #expect(!itens.contains {
            if case .error = $0 {
                true
            } else {
                false
            }
        })
    }

    /// Primeiro a poda: se ela basta, nada de pedido de resumo.
    @Test func quandoAPodaBastaNaoResume() async throws {
        let root = try tmpProject()
        var roteiro: [[StreamEvent]] = []
        for i in 0 ..< 5 {
            try linhas(1100, "b\(i)").write(to: root.appending(path: "b\(i).txt"), atomically: true, encoding: .utf8)
            var r: [StreamEvent] = [.tools([call("read_file", ["path": "b\(i).txt"])])]
            if i == 4 {
                r.append(.usage(TokenUse(input: 70000, output: 100)))
            }
            roteiro.append(r + [.done])
        }
        roteiro.append([.text("pronto"), .done])
        let p = FakeProvider(roteiro)
        let loop = AgentLoop(provider: p, host: TestHost(root: root), patches: PatchStore(root: root))
        var cfg = LoopConfig(mode: .chat, permit: .full, model: "m")
        cfg.janelaDeContexto = 100_000
        let r = await runAll(loop, "lê tudo", cfg)
        let turnos = p.turns.withLock { $0 }
        #expect(turnos.count == 6, "pediu resumo quando a poda bastava (\(turnos.count) pedidos)")
        #expect(turnos.allSatisfy { !$0.tools.isEmpty }, "houve pedido de resumo")
        let resultados = turnos[5].messages.filter { $0.role == .tool }.map(\.content)
        #expect(resultados.prefix(2).allSatisfy { $0 == Compactacao.marcaDePoda })
        #expect(resultados.suffix(3).allSatisfy { $0 != Compactacao.marcaDePoda })
        #expect(r.items
            .contains {
                if case let .compactado(_, resumo, _, depois) = $0 {
                    resumo.isEmpty && depois > 0
                } else {
                    false
                }
            })
    }

    /// O provedor recusou por tamanho: resume e tenta a mesma rodada de novo, uma vez.
    @Test func promptLongoDemaisResumeETentaDeNovo() async throws {
        let root = try tmpProject()
        let p = FakeProvider([
            [.error("HTTP 400: prompt is too long: 250000 tokens > 200000 maximum"), .done],
            [.text("## Objetivo\n- seguir"), .done],
            [.text("feito"), .done],
        ])
        let loop = AgentLoop(provider: p, host: TestHost(root: root), patches: PatchStore(root: root))
        let antes: [AgentMessage] = [
            .user("antigo"),
            AgentMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "t", name: "grep", arguments: "{}")]),
            .tool("t", String(repeating: "g", count: 70000)),
            AgentMessage(role: .assistant, content: "ok"),
        ]
        let r = await runAll(loop, "novo", LoopConfig(mode: .chat, permit: .full, model: "m"), history: antes)
        let turnos = p.turns.withLock { $0 }
        #expect(turnos.count == 3)
        #expect(turnos[1].tools.isEmpty)
        #expect(Compactacao.ehResumo(turnos[2].messages[0])
            && turnos[2].messages.last.map { Prompts.semContextoDoTurno($0.content) } == "novo")
        #expect(r.history.last?.content == "feito")
        #expect(!r.items.contains {
            if case .error = $0 {
                true
            } else {
                false
            }
        }, "o estouro virou erro na tela")
    }

    /// E se estourar de novo depois de resumir, aí é erro — sem laço de resumos.
    @Test func estouroDepoisDoResumoViraErro() async throws {
        let root = try tmpProject()
        let estouro: [StreamEvent] = [.error("prompt is too long"), .done]
        let p = FakeProvider([estouro, [.text("## Objetivo\n- x"), .done], estouro, estouro])
        let loop = AgentLoop(provider: p, host: TestHost(root: root), patches: PatchStore(root: root))
        let antes: [AgentMessage] = [
            .user("antigo"),
            AgentMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "t", name: "grep", arguments: "{}")]),
            .tool("t", String(repeating: "g", count: 70000)),
            AgentMessage(role: .assistant, content: "ok"),
        ]
        let r = await runAll(loop, "novo", LoopConfig(mode: .chat, permit: .full, model: "m"), history: antes)
        #expect(p.turns.withLock { $0.count } == 3)
        #expect(r.items.contains {
            if case let .error(_, t) = $0 {
                t.contains("too long")
            } else {
                false
            }
        })
    }

    /// O `/compact`: resume na hora, sem turno, e a próxima mensagem segue do resumo.
    @Test func compactarNaHora() async throws {
        let root = try tmpProject()
        let p = FakeProvider([[.text("## Objetivo\n- manual"), .done]])
        let loop = AgentLoop(provider: p, host: TestHost(root: root), patches: PatchStore(root: root))
        var ms: [AgentMessage] = []
        for i in 0 ..< 6 {
            ms.append(.user("pedido \(i)"))
            ms.append(AgentMessage(role: .assistant, content: String(repeating: "resposta \(i) ", count: 1500)))
        }
        var historia: [AgentMessage] = []
        var cartao = false
        for await e in loop.compactar(history: ms, config: LoopConfig(mode: .build, permit: .full, model: "m")) {
            if case let .history(h) = e {
                historia = h
            }
            if case let .item(.compactado(_, resumo, _, _)) = e, !resumo.isEmpty {
                cartao = true
            }
        }
        #expect(cartao)
        #expect(Compactacao.ehResumo(historia[0]) && historia.count < ms.count)
        #expect(!historia[0].content.contains("Continue se houver"), "o convite a continuar é só da automática")
        let pedido = try #require(p.turns.withLock { $0.first })
        #expect(pedido.tools.isEmpty)

        // Conversa curta: aviso neutro, nada muda.
        let curto = AgentLoop(provider: FakeProvider([]), host: TestHost(root: root), patches: PatchStore(root: root))
        var aviso = false
        var mudou = false
        for await e in curto.compactar(
            history: [.user("oi")],
            config: LoopConfig(mode: .build, permit: .full, model: "m")
        ) {
            if case let .item(.error(id, _)) = e, id.hasPrefix(AgentLoop.prefixoDeAviso) {
                aviso = true
            }
            if case .history = e {
                mudou = true
            }
        }
        #expect(aviso && !mudou)
    }
}
