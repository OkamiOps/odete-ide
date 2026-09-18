import Foundation
import FoundationModels
@testable import OdeteAgent
import OdeteI18n
import Testing

/// O modelo da Apple editando arquivo.
///
/// Este é o modelo que sobra num voo sem internet, então recusar-se a editar não é uma
/// limitação aceitável — era o que acontecia: as instruções diziam ao modelo que ele não
/// tinha ferramentas, e ele obedecia.
///
/// Depois disso a primeira versão com ferramentas errou do outro lado: por medo da janela
/// eu escrevi um resumo à mão no lugar do prompt de verdade e tirei uma ferramenta da
/// lista. O resultado foi um modelo que perguntava para a pessoa qual ferramenta deveria
/// usar. Por isso vários testes daqui cobram *ausência de poda*: o modelo local recebe o
/// mesmo que os provedores por assinatura, e o corte só existe quando o texto não cabe
/// mesmo.
///
/// Nada aqui liga o modelo. O simulador não tem Apple Intelligence, e um teste que
/// dependesse disso não rodaria em lugar nenhum.
struct AppleFerramentasTests {
    func pedido(_ modelo: String = AppleProvider.idLocal, tools: [ToolSpec] = Tools.all) -> TurnRequest {
        TurnRequest(system: "", messages: [], tools: tools, model: modelo)
    }

    var sistema: String {
        Prompts.build(mode: .build, fileList: ["index.html", "src/main.js"], extras: ["Regras do projeto: nenhuma."])
    }

    // MARK: o schema

    /// Se uma ferramenta não vira schema, ela some da lista em silêncio — o modelo nunca
    /// saberia que ela existe, e ninguém veria erro nenhum.
    @Test func todaFerramentaViraEsquema() throws {
        for spec in Tools.all {
            #expect(throws: Never.self, "\(spec.name) não virou schema") {
                try EsquemaApple.esquema(de: spec)
            }
        }
    }

    @Test func oCampoDeOpcoesFixasNaoViraTextoLivre() throws {
        // `github` é a única com `enum`; se ela virasse texto livre o modelo poderia
        // inventar uma ação que não existe.
        let github = try #require(Tools.all.first { $0.name == "github" })
        let acao = try #require(github.parameters["properties"] as? [String: Any])["action"] as? [String: Any]
        #expect(acao?["enum"] as? [String] != nil, "o schema de origem mudou e o teste parou de medir o que dizia")
        #expect(throws: Never.self) { try EsquemaApple.esquema(de: github) }
    }

    // MARK: a ferramenta

    /// A ferramenta anota e para. Se um dia ela executar de verdade aqui dentro, o laço
    /// do agente deixa de ver a chamada — e com ele somem a confirmação e a revisão do
    /// patch.
    @Test func aFerramentaAnotaEParaEmVezDeExecutar() async throws {
        let vistos = Caixa<[(String, String)]>([])
        let read = try #require(Tools.all.first { $0.name == "read_file" })
        let ferramenta = try FerramentaDaOdete(
            name: "read_file",
            description: "lê",
            parameters: EsquemaApple.esquema(de: read),
            anotar: { nome, args in vistos.mexer { $0.append((nome, args)) } }
        )
        await #expect(throws: PedidoDeFerramenta.self) {
            try await ferramenta.call(arguments: GeneratedContent(json: #"{"path":"src/index.ts"}"#))
        }
        let anotados = vistos.ler()
        #expect(anotados.count == 1)
        #expect(anotados.first?.0 == "read_file")
        #expect(anotados.first?.1.contains("src/index.ts") == true, "os argumentos não chegaram inteiros")
    }

    /// O modelo local não é um modelo de segunda classe: ele recebe as mesmas ferramentas
    /// do modo, sem peneira minha no meio.
    @Test func oModeloLocalRecebeTodasAsFerramentasDoModo() {
        let local = AppleProvider.ferramentas(pedido()) { _, _ in }
        #expect(local.count == Tools.all.count, "alguma ferramenta foi podada antes de chegar ao modelo local")
        for spec in Tools.all {
            #expect(local.contains { $0.name == spec.name }, "\(spec.name) não chegou ao modelo local")
        }
    }

    // MARK: as instruções

    /// O prompt de verdade, e não um resumo: é dele que vêm o modo escolhido na tela, as
    /// regras da pilha e as regras do projeto.
    @Test func oModeloLocalRecebeOPromptDeVerdade() {
        let texto = AppleProvider.instrucoes(sistema, comFerramentas: true)
        #expect(texto.contains("Modo BUILD"), "o modo escolhido não chegou")
        #expect(texto.contains("Regras do projeto"), "os acréscimos do projeto não chegaram")
        #expect(texto.contains("index.html"), "a lista de arquivos não chegou")
    }

    /// Foi o que apareceu nas duas primeiras builds com ferramentas: rodadas terminando
    /// em "posso seguir?" e, pior, em "qual ferramenta devo usar?".
    @Test func asInstrucoesProibemPerguntarAntesDeAgir() {
        let texto = AppleProvider.instrucoes(sistema, comFerramentas: true)
        #expect(texto.contains("posso seguir"), "falta proibir a pergunta que ele fazia")
        #expect(texto.contains("qual ferramenta devo usar"), "falta proibir perguntar qual ferramenta usar")
        #expect(texto.contains("a escolha da ferramenta é sua"))
    }

    /// O outro erro da mesma tela: `str_replace` com um `old` que não existia no arquivo,
    /// escrito de memória em vez de copiado do que ele acabara de ler.
    @Test func asInstrucoesExigemCopiarOTrechoLido() {
        // Numa linha só: a frase atravessa a quebra do literal, e o teste é sobre o que
        // está escrito, não sobre onde a linha termina.
        let texto = AppleProvider.instrucoes(sistema, comFerramentas: true)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        #expect(texto.contains("caractere por caractere"))
        #expect(texto.contains("read_file"))
    }

    /// Um pedido de novo visual gravou `{"body": {"margin": "0"}}` dentro de um
    /// `style.css`: com geração guiada o modelo está emitindo JSON, e sem ninguém dizer o
    /// contrário ele continua o padrão para dentro do valor do campo.
    @Test func oConteudoDeArquivoEhTextoPuro() throws {
        let write = try #require(Tools.all.first { $0.name == "write_file" })
        let props = try #require(write.parameters["properties"] as? [String: Any])
        let content = try #require(props["content"] as? [String: Any])
        let explicacao = try #require(content["description"] as? String)
        #expect(explicacao.contains("Nunca JSON"), "o campo do conteúdo não diz que não é JSON")

        let texto = AppleProvider.instrucoes(sistema, comFerramentas: true)
        #expect(texto.contains("Nunca escreva JSON"), "a regra não chegou às instruções")
    }

    /// Todo campo que carrega texto de arquivo tem que se explicar — é o que impede o
    /// modelo de inventar um formato para ele.
    @Test func osCamposDeTextoSeExplicam() throws {
        for nome in ["write_file", "str_replace", "read_file", "grep", "list_dir"] {
            let spec = try #require(Tools.all.first { $0.name == nome })
            let props = try #require(spec.parameters["properties"] as? [String: Any])
            for (campo, esquema) in props {
                let dicionario = try #require(esquema as? [String: Any])
                #expect(
                    (dicionario["description"] as? String)?.isEmpty == false,
                    "\(nome).\(campo) não diz o que espera receber"
                )
            }
        }
    }

    /// "Next Steps: Verify HTML" e ponto final: ele sabia o que faltava e parou para
    /// contar em vez de fazer.
    @Test func asInstrucoesProibemAnunciarEmVezDeAgir() {
        let texto = AppleProvider.instrucoes(sistema, comFerramentas: true)
        #expect(texto.contains("Não anuncie o que vai fazer"))
        #expect(texto.contains("Próximos passos"), "falta proibir a lista de próximos passos")
    }

    @Test func semFerramentaAsInstrucoesDizemOQueFalta() {
        let texto = AppleProvider.instrucoes(sistema, comFerramentas: false)
        #expect(texto.contains("sem ferramentas"))
    }

    // MARK: o corte, quando ele precisa acontecer

    /// Num projeto pequeno o prompt cabe inteiro, e cortar seria perda pura.
    @Test func oQueCabeVaiInteiro() {
        let texto = AppleInstrucoes.cabendo(sistema, teto: 100_000)
        #expect(texto == sistema, "cortou um prompt que cabia")
    }

    /// Quando não cabe, quem encolhe é a lista de arquivos — a única parte que cresce com
    /// o tamanho do projeto. As regras são texto fixo: cortar regra é cortar
    /// comportamento.
    @Test func quandoNaoCabeQuemEncolheEhAListaDeArquivos() {
        let grande = Prompts.build(
            mode: .build,
            fileList: (1 ... 400).map { "src/arquivo\($0).ts" },
            extras: ["Regras do projeto: nenhuma."]
        )
        let teto = grande.count / 2
        let texto = AppleInstrucoes.cabendo(grande, teto: teto)
        #expect(texto.count <= teto, "o corte não respeitou o teto")
        #expect(texto.contains("Modo BUILD"), "o modo foi junto no corte")
        #expect(texto.contains("Regras do projeto"), "os acréscimos foram junto no corte")
        #expect(texto.contains("src/arquivo1.ts"), "a lista sumiu inteira quando era para só encolher")
        #expect(!texto.contains("src/arquivo400.ts"), "a lista não encolheu")
    }

    @Test func asRegrasDeFerramentaCabemNoTeto() {
        let texto = AppleInstrucoes.texto(sistema: sistema, comFerramentas: true, teto: 900)
        #expect(texto.count <= 900 + AppleInstrucoes.comFerramentas.count, "o texto final estourou o teto pedido")
        #expect(texto.contains("a escolha da ferramenta é sua"), "as regras foram cortadas antes da lista")
    }

    // MARK: a transcrição

    func ferramentasDeTeste() -> [any Tool] {
        AppleProvider.ferramentas(pedido()) { _, _ in }
    }

    func monta(_ mensagens: [AgentMessage], orcamento: Int = 100_000) -> (Transcript, String) {
        TranscricaoApple.montar(
            mensagens,
            instrucoes: "instruções",
            ferramentas: ferramentasDeTeste(),
            orcamento: orcamento
        )
    }

    /// A causa de o modelo escrever *sobre* editar em vez de editar.
    ///
    /// O histórico ia achatado num prompt de texto, onde a chamada anterior virava a
    /// frase "Odete pediu read_file: {...}". Modelo pequeno imita o formato que vê: ele
    /// passou a devolver prosa descrevendo a chamada — um bloco de CSS no chat com "nada
    /// foi alterado" embaixo. Chamada tem que voltar como chamada.
    @Test func aChamadaAnteriorVoltaComoChamadaENaoComoProsa() {
        let chamada = ToolCall(id: "1", name: "read_file", arguments: #"{"path":"src/style.css"}"#)
        let (transcricao, _) = monta([
            .user("deixa o botão azul"),
            AgentMessage(role: .assistant, content: "", toolCalls: [chamada]),
            AgentMessage(role: .tool, content: "button { color: red }", toolCallId: "1"),
        ])
        var viuChamada = false, viuResultado = false
        for entrada in transcricao {
            switch entrada {
            case let .toolCalls(c):
                viuChamada = c.contains { $0.toolName == "read_file" }
            case let .toolOutput(o):
                // O nome tem que vir junto: o resultado sozinho é órfão para o modelo.
                viuResultado = o.toolName == "read_file"
            default: break
            }
        }
        #expect(viuChamada, "a chamada anterior não virou entrada de chamada")
        #expect(viuResultado, "o resultado não virou entrada de resultado com o nome da ferramenta")
    }

    /// As instruções e as ferramentas entram na transcrição, e é a primeira entrada.
    @Test func aTranscricaoComecaPelasInstrucoesComAsFerramentas() throws {
        let (transcricao, _) = monta([.user("oi")])
        let primeira = try #require(transcricao.first)
        guard case let .instructions(i) = primeira else {
            Issue.record("a transcrição não começa pelas instruções")
            return
        }
        #expect(i.toolDefinitions.count == Tools.all.count, "as ferramentas não foram declaradas na transcrição")
    }

    /// A última fala é a pergunta da vez, e não mais uma linha da transcrição.
    @Test func aUltimaFalaViraOPrompt() {
        let (_, prompt) = monta([.user("primeira"), .user("deixa o botão azul")])
        #expect(prompt == "deixa o botão azul")
    }

    /// No meio de um trabalho a conversa termina em resultado de ferramenta: não há fala
    /// nova, e o framework exige um prompt.
    @Test func terminandoEmFerramentaOPromptMandaSeguir() {
        let (_, prompt) = monta([
            .user("arruma"),
            AgentMessage(role: .tool, content: "escrito a.css (4 → 4 linhas)", toolCallId: "1"),
        ])
        #expect(prompt.contains("arruma"), "sem fala nova, o prompt tem que lembrar o pedido")
    }

    /// Cortar o começo não pode deixar um resultado sem a chamada que o pediu: o modelo
    /// veria a resposta de uma ferramenta que, para ele, nunca foi chamada.
    @Test func oCorteNaoDeixaResultadoOrfao() {
        let longa = String(repeating: "x", count: 500)
        let mensagens: [AgentMessage] = (1 ... 20).flatMap { i -> [AgentMessage] in
            [
                AgentMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [ToolCall(id: "\(i)", name: "read_file", arguments: "{}")]
                ),
                AgentMessage(role: .tool, content: longa, toolCallId: "\(i)"),
            ]
        }
        let cortadas = TranscricaoApple.cortando(mensagens, orcamento: 1500)
        #expect(cortadas.first?.role != .tool, "a conversa começa num resultado sem dono")
        #expect(TranscricaoApple.tamanho(cortadas) <= 1500)
    }

    /// Os argumentos da chamada saem no orçamento da resposta, então um `write_file` de
    /// arquivo inteiro batia no teto de conversa e voltava truncado.
    @Test func comFerramentaOTetoDaRespostaSobe() {
        #expect(AppleProvider.respostaComFerramentas >= AppleProvider.respostaMaxima)
        #expect(AppleProvider.respostaComFerramentas > 1500 || AppleProvider.janela < 4500)
    }
}

/// Caixa com trava para os testes: `anotar` é `@Sendable` e roda fora do ator do teste.
final class Caixa<T>: @unchecked Sendable {
    private var valor: T
    private let trava = NSLock()
    init(_ inicial: T) {
        valor = inicial
    }

    func mexer(_ f: (inout T) -> Void) {
        trava.lock(); f(&valor); trava.unlock()
    }

    func ler() -> T {
        trava.lock(); defer { trava.unlock() }; return valor
    }
}

/// O pedido não pode sair da transcrição.
///
/// Foi a causa do agente vagar pelos arquivos depois de já ter feito o trabalho: o corte
/// tirava as mensagens mais velhas, e a mais velha é justamente a que diz o que fazer.
/// Sobrava uma pilha de arquivos lidos e um "siga daqui" que não diz para onde.
struct AppleEnunciadoTests {
    @Test func oPedidoNuncaSaiNoCorte() {
        let pedido = AgentMessage.user("troca a cor do botão para azul")
        let entulho = (1 ... 40).flatMap { i -> [AgentMessage] in
            [
                AgentMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [ToolCall(id: "\(i)", name: "read_file", arguments: "{}")]
                ),
                AgentMessage(role: .tool, content: String(repeating: "conteúdo ", count: 20), toolCallId: "\(i)"),
            ]
        }
        let ficaram = TranscricaoApple.cortando([pedido] + entulho, orcamento: 2000)
        #expect(ficaram.first?.content == pedido.content, "o corte levou o enunciado junto")
        #expect(TranscricaoApple.tamanho(ficaram) <= 2000 + pedido.content.count, "o corte não respeitou o teto")
        #expect(ficaram.count > 1, "cortou tudo menos o pedido")
    }

    /// Sem fala nova, o prompt repete o pedido em vez de dizer só "siga".
    @Test func semFalaNovaOPromptLembraOPedido() {
        let (_, prompt) = TranscricaoApple.montar(
            [
                .user("troca a cor do botão para azul"),
                AgentMessage(role: .tool, content: "escrito style.css (4 → 4 linhas)", toolCallId: "1"),
            ],
            instrucoes: "i",
            ferramentas: [],
            orcamento: 100_000
        )
        #expect(prompt.contains("cor do botão"), "o prompt de continuação não diz para onde seguir")
    }

    /// Com fala nova, quem manda é ela.
    @Test func comFalaNovaOPromptEhAFalaNova() {
        let (_, prompt) = TranscricaoApple.montar(
            [.user("primeiro pedido"), .user("agora deixa o título maior")],
            instrucoes: "i",
            ferramentas: [],
            orcamento: 100_000
        )
        #expect(prompt == "agora deixa o título maior")
    }
}
