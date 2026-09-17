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

    // MARK: o histórico

    /// Sem o pedido no histórico, a rodada seguinte recebe um resultado sem dono: o
    /// modelo vê o conteúdo de um arquivo e não sabe de qual, nem por que pediu.
    @Test func oHistoricoGuardaOPedidoEOResultado() {
        let chamada = ToolCall(id: "1", name: "read_file", arguments: #"{"path":"index.html"}"#)
        let texto = AppleProvider.prompt([
            .user("troca o título"),
            AgentMessage(role: .assistant, content: "", toolCalls: [chamada]),
            AgentMessage(role: .tool, content: "<h1>oi</h1>", toolCallId: "1"),
        ])
        #expect(texto.contains("read_file"), "o pedido de ferramenta sumiu do histórico")
        #expect(texto.contains("index.html"), "o argumento do pedido sumiu")
        #expect(texto.contains("<h1>oi</h1>"), "o resultado sumiu")
    }

    /// Quatrocentos caracteres davam para conversar e não davam para editar: com o
    /// arquivo cortado não há como montar um `str_replace` com o trecho exato.
    @Test func oResultadoDeFerramentaCabeUmArquivo() {
        let arquivo = String(repeating: "uma linha de código\n", count: 200)
        let texto = AppleProvider.prompt([AgentMessage(role: .tool, content: arquivo, toolCallId: "1")])
        #expect(texto.count > 400, "o resultado voltou cortado em 400, como antes")
        #expect(
            AppleProvider.tetoDoResultado(AppleProvider.janelaDaNuvem)
                > AppleProvider.tetoDoResultado(AppleProvider.orcamentoDeEntrada),
            "o teto não acompanha a janela: o modelo grande recebe o mesmo pedaço do pequeno"
        )
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
