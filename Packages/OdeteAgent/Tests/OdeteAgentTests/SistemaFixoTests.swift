import Foundation
@testable import OdeteAgent
import OdeteI18n
import Testing

/// Sistema e ferramentas iguais a conversa inteira: só acréscimo no fim.
///
/// O laço refazia o prompt de sistema a cada rodada — e a lista de arquivos dentro dele
/// muda assim que o agente cria um — e mandava só as ferramentas do modo. Qualquer
/// mudança ali invalida o cache de prompt e, nos modelos da Anthropic com raciocínio
/// preservado, todo bloco de raciocínio já devolvido.
@Suite(.serialized) struct SistemaFixoTests {
    init() {
        Texto.escolher(.ptBR)
    }

    /// Dentro do turno, criar um arquivo não muda o sistema da rodada seguinte.
    @Test func criarArquivoNoMeioDoTurnoNaoMudaOSistema() async throws {
        let root = try tmpProject()
        let p = FakeProvider([
            [.tools([call("write_file", ["path": "novo.txt", "content": "x"])]), .done],
            [.text("criei"), .done],
        ])
        let loop = AgentLoop(provider: p, host: TestHost(root: root), patches: PatchStore(root: root))
        var sistemaNovo: String?
        for await e in loop.run(
            history: [],
            userText: "cria",
            config: LoopConfig(mode: .build, permit: .full, model: "m")
        ) {
            if case let .sistema(s) = e {
                sistemaNovo = s
            }
        }
        let turnos = p.turns.withLock { $0 }
        #expect(turnos.count == 2 && turnos[0].system == turnos[1].system, "o sistema mudou no meio do turno")
        #expect(sistemaNovo == turnos[0].system, "o sistema da conversa não foi devolvido para ser guardado")
        // O pedido de antes continua byte a byte igual no pedido seguinte: só acréscimo.
        #expect(Array(turnos[1].messages.prefix(turnos[0].messages.count)) == turnos[0].messages)
    }

    /// Entre turnos, trocar de modo não muda nem o sistema nem as ferramentas; o modo vai na
    /// mensagem nova. E a ferramenta que o modo não tem é recusada sem pedir licença.
    @Test func trocarDeModoSoAcrescenta() async throws {
        let root = try tmpProject()
        let p = FakeProvider([
            [.text("feito"), .done],
            [.tools([call("write_file", ["path": "a.txt", "content": "zzz"])]), .done],
            [.text("não posso editar no chat"), .done],
        ])
        let host = TestHost(root: root)
        let loop = AgentLoop(provider: p, host: host, patches: PatchStore(root: root))
        // O primeiro turno no Plan: no Build, uma resposta só de texto ganha a cutucada
        // de "anunciar não é fazer", que comeria a rodada seguinte do roteiro.
        var plan = LoopConfig(mode: .plan, permit: .auto, model: "m")
        var sistema: String?
        var historia: [AgentMessage] = []
        for await e in loop.run(history: [], userText: "oi", config: plan) {
            if case let .sistema(s) = e {
                sistema = s
            }
            if case let .history(h) = e {
                historia = h
            }
        }
        plan.sistema = sistema
        var chat = plan
        chat.mode = .chat
        var pediuLicenca = false
        for await e in loop.run(history: historia, userText: "e agora?", config: chat) {
            if case .item(.permit) = e {
                pediuLicenca = true
            }
        }
        let turnos = p.turns.withLock { $0 }
        try #require(turnos.count == 3)
        #expect(turnos[0].system == turnos[1].system && turnos[1].system == turnos[2].system)
        #expect(turnos[0].tools.map(\.name) == turnos[1].tools.map(\.name))
        #expect(turnos[1].messages.last?.content.contains("Modo CHAT") == true)
        #expect(Array(turnos[1].messages.prefix(turnos[0].messages.count)) == turnos[0].messages)
        #expect(!pediuLicenca, "pediu licença para uma ferramenta que o modo não tem")
        #expect(host.read("a.txt") == "a\nb\nc\n", "o chat editou")
        #expect(turnos[2].messages.last?.content.contains("não está disponível no modo") == true)
    }

    /// O modelo do aparelho continua com o sistema do modo e as ferramentas do modo.
    @Test func oModeloDoAparelhoContinuaComOModoNoSistema() async throws {
        let root = try tmpProject()
        let p = FakeProviderApple([[.text("oi"), .done]])
        let loop = AgentLoop(provider: p, host: TestHost(root: root), patches: PatchStore(root: root))
        _ = await runAll(loop, "olá", LoopConfig(mode: .chat, permit: .full, model: "m"))
        let turno = try #require(p.base.turns.withLock { $0.first })
        #expect(turno.system.contains("Modo CHAT"))
        #expect(turno.tools.map(\.name) == Tools.forMode(.chat).map(\.name))
    }

    /// O `<contexto_do_turno>` não volta para o compositor no "Tentar de novo".
    @Test func contextoDoTurnoSaiDoTexto() {
        let texto = "arruma o css" + "\n\n"
            + Prompts.contextoDoTurno(mode: .build, skills: "Skills via /nome no chat: /review")
        #expect(Prompts.semContextoDoTurno(texto) == "arruma o css")
        #expect(Prompts.semContextoDoTurno("sem bloco") == "sem bloco")
    }

    /// Consertar no meio da conversa tira o raciocínio; acrescentar no fim, não.
    @Test func consertarNoFimNaoTiraORaciocinio() {
        let chamada = AgentMessage(role: .assistant, content: "", thinking: "pensei", toolCalls: [
            ToolCall(id: "c", name: "grep", arguments: "{}"),
        ])
        let fim = Transcricao.consertar([.user("oi"), chamada])
        #expect(fim[1].thinking == "pensei" && fim.count == 3)
        let meio = Transcricao.consertar([.tool("órfão", "x"), .user("oi"), chamada, .tool("c", "r")])
        #expect(meio.allSatisfy { $0.thinking == nil })
    }
}

/// A conversa com o que os provedores devolvem além do texto: o raciocínio assinado
/// (`AgentMessage.raciocinio`) e a chamada cortada no limite de saída (`ToolCall.problema`).
@Suite(.serialized) struct ProvedoresNoLacoTests {
    init() {
        Texto.escolher(.ptBR)
    }

    static let bruto = RaciocinioBruto(
        formato: "anthropic",
        origem: "https://api.anthropic.com",
        modelo: "m",
        json: #"[{"signature":"assinado","thinking":"pensei","type":"thinking"}]"#
    )

    /// O raciocínio assinado volta intacto na rodada seguinte, e o pedido seguinte começa
    /// byte a byte igual ao anterior — é o que mantém válidos os blocos com `drop_block`.
    @Test func raciocinioVoltaIntactoESoAcrescenta() async throws {
        let root = try tmpProject()
        let p = FakeProvider([
            [.think("pensei"), .raciocinio(Self.bruto), .tools([call("read_file", ["path": "a.txt"])]), .done],
            [.text("li"), .done],
        ])
        let loop = AgentLoop(provider: p, host: TestHost(root: root), patches: PatchStore(root: root))
        _ = await runAll(loop, "lê", LoopConfig(mode: .chat, permit: .full, model: "m"))
        let turnos = p.turns.withLock { $0 }
        try #require(turnos.count == 2)
        #expect(Array(turnos[1].messages.prefix(turnos[0].messages.count)) == turnos[0].messages)
        #expect(turnos[1].messages.contains { $0.raciocinio == Self.bruto }, "o raciocínio assinado não voltou")
        #expect(turnos[0].system == turnos[1].system && turnos[0].tools.map(\.name) == turnos[1].tools.map(\.name))
    }

    /// Poda, resumo, conserto no meio e corte do histórico tiram o raciocínio assinado.
    @Test func todaEdicaoTiraORaciocinioAssinado() throws {
        let assinada = AgentMessage(role: .assistant, content: "", thinking: "pensei", toolCalls: [
            ToolCall(id: "c", name: "grep", arguments: "{}"),
        ], raciocinio: Self.bruto)
        // Conserto no meio.
        let meio = Transcricao.consertar([.tool("órfão", "x"), .user("oi"), assinada, .tool("c", "r")])
        #expect(meio.allSatisfy { $0.raciocinio == nil })
        // Conserto só no fim não mexe.
        #expect(Transcricao.consertar([.user("oi"), assinada])[1].raciocinio == Self.bruto)
        // Poda.
        var ms: [AgentMessage] = [.user("pedido")]
        for i in 0 ..< 10 {
            var m = assinada
            m.toolCalls = [ToolCall(id: "\(i)", name: "grep", arguments: "{}")]
            ms.append(m)
            ms.append(.tool("\(i)", String(repeating: "r", count: 40000)))
        }
        let podado = try #require(Compactacao.podar(ms))
        #expect(podado.mensagens.allSatisfy { $0.raciocinio == nil })
        // Resumo.
        let plano = try #require(Compactacao.planejar(ms, pedido: 0, janela: 100_000))
        let novo = Compactacao.montar(ms, plano: plano, resumo: "x", pedido: 0, continuar: true)
        #expect(novo.mensagens.allSatisfy { $0.raciocinio == nil })
        // Corte do histórico guardado.
        let cortado = Transcricao.aparar(ms, maximo: 6)
        #expect(cortado.count <= 6 && cortado.allSatisfy { $0.raciocinio == nil })
    }

    /// A estimativa conta o raciocínio que volta ao provedor (o bruto), uma vez só.
    @Test func estimativaContaOBrutoUmaVez() {
        let so = AgentMessage(role: .assistant, content: "", thinking: String(repeating: "p", count: 4000))
        var com = so
        com.raciocinio = RaciocinioBruto(
            formato: "anthropic",
            origem: "o",
            modelo: "m",
            json: String(repeating: "j", count: 8000)
        )
        #expect(Compactacao.estimar(so) < Compactacao.estimar(com))
        #expect(Compactacao.estimar(com) < 2000 + 100, "contou o texto e o bruto juntos")
    }

    /// A chamada cortada no limite de saída não pede licença nem passa pelo modo: vai
    /// direto ao executor, que devolve a explicação — e não conta como escrita.
    @Test func chamadaCortadaNaoPedeLicenca() async throws {
        let root = try tmpProject()
        let cortada = ToolCall(
            id: "w",
            name: "write_file",
            arguments: #"{"path":"a.txt","content":"meio arq"#,
            problema: "A chamada foi cortada no limite de saída: mande o arquivo em partes."
        )
        let p = FakeProvider([[.tools([cortada]), .done], [.text("vou em partes"), .done]])
        let host = TestHost(root: root)
        let loop = AgentLoop(provider: p, host: host, patches: PatchStore(root: root))
        let r = await runAll(loop, "escreve", LoopConfig(mode: .chat, permit: .ask, model: "m"))
        #expect(!r.items.contains {
            if case .permit = $0 {
                true
            } else {
                false
            }
        }, "pediu licença para a cortada")
        #expect(r.history.contains { $0.role == .tool && $0.content.contains("cortada no limite") })
        #expect(host.read("a.txt") == "a\nb\nc\n")
        #expect(!AgentLoop.podeEscrever(cortada))
        // E no resumo ela vai marcada, com o motivo.
        let texto = Compactacao.serializar(
            AgentMessage(role: .assistant, content: "", toolCalls: [cortada]),
            teto: 2000
        )
        #expect(texto.contains("não rodou") && texto.contains("cortada no limite"))
    }
}

/// O `FakeProvider` fingindo ser o modelo do aparelho.
final class FakeProviderApple: Provider, @unchecked Sendable {
    let kind: ProviderKind = .apple
    let base: FakeProvider

    init(_ s: [[StreamEvent]]) {
        base = FakeProvider(s)
    }

    func stream(_ turn: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        base.stream(turn)
    }

    func models() async throws -> [ModelInfo] {
        []
    }
}
