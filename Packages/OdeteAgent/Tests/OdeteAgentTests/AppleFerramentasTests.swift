import Foundation
import FoundationModels
@testable import OdeteAgent
import OdeteI18n
import Testing

/// O modelo da Apple editando arquivo.
///
/// Este é o modelo que sobra num voo sem internet, então recusar-se a editar não é uma
/// limitação aceitável — era o que acontecia: as instruções diziam ao modelo que ele não
/// tinha ferramentas, e ele obedecia. Aqui se fixa o contrário, nas três pontas que
/// podem quebrar sem ninguém notar: o schema traduzido, a ferramenta que anota em vez de
/// executar, e as instruções.
///
/// Nada aqui liga o modelo. O simulador não tem Apple Intelligence, e um teste que
/// dependesse disso não rodaria em lugar nenhum.
struct AppleFerramentasTests {
    func pedido(_ modelo: String = AppleProvider.idLocal, tools: [ToolSpec] = Tools.all) -> TurnRequest {
        TurnRequest(system: "", messages: [], tools: tools, model: modelo)
    }

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

    /// A ferramenta anota e para. Se um dia ela executar de verdade aqui dentro, o laço
    /// do agente deixa de ver a chamada — e com ele somem a confirmação e a revisão do
    /// patch.
    @Test func aFerramentaAnotaEParaEmVezDeExecutar() async throws {
        let vistos = Caixa<[(String, String)]>([])
        let ferramenta = try FerramentaDaOdete(
            name: "read_file",
            description: "lê",
            parameters: EsquemaApple.esquema(de: #require(Tools.all.first { $0.name == "read_file" })),
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

    /// Ferramenta oferecida ocupa janela mesmo sem ser usada: nome, descrição e schema
    /// entram nas instruções. No modelo local isso é caro.
    @Test func oModeloLocalNaoRecebeAFerramentaMaisPesada() {
        let local = AppleProvider.ferramentas(pedido()) { _, _ in }
        let nuvem = AppleProvider.ferramentas(pedido(AppleProvider.idNuvem)) { _, _ in }
        #expect(!local.contains { $0.name == "github" }, "github entrou no modelo local")
        #expect(local.contains { $0.name == "str_replace" }, "sem str_replace o modelo local não edita nada")
        #expect(nuvem.contains { $0.name == "github" }, "a nuvem tem janela de sobra e mesmo assim perdeu github")
        #expect(nuvem.count > local.count)
    }

    /// O bug que apareceu num vídeo: a resposta ao usuário repetia, parafraseada, a linha
    /// do prompt do sistema sobre `read_file`. Ela chegava lá porque as instruções do
    /// modelo da Apple pescavam do sistema a primeira linha que falasse em "projeto".
    @Test func asInstrucoesNaoLevamOPromptDoSistemaJunto() {
        let sistema = Prompts.build(mode: .build, fileList: ["src/app.ts"], extras: [])
        let texto = AppleProvider.instrucoes(sistema, comFerramentas: true)
        #expect(!texto.contains("só entra se VOCÊ chamar"), "a entranha do sistema voltou para as instruções")
        #expect(!texto.contains("TDAH"), "o bloco de formato do prompt grande vazou para cá")
    }

    @Test func comFerramentaAsInstrucoesMandamEditar() {
        let texto = AppleProvider.instrucoes("", comFerramentas: true)
        #expect(!texto.contains("não edita arquivos"), "as instruções continuam dizendo que ele não edita")
        #expect(texto.contains("str_replace"), "ninguém disse ao modelo por onde editar")
    }

    @Test func semFerramentaAsInstrucoesDizemOQueFalta() {
        let texto = AppleProvider.instrucoes("", comFerramentas: false)
        #expect(texto.contains("sem ferramentas"))
    }

    /// A lista de caminhos poupa uma rodada de `list_dir`, mas a do prompt grande vai até
    /// 400 linhas — numa janela de poucos milhares de fichas isso é o orçamento inteiro.
    @Test func aListaDeArquivosEntraECortaNoLimite() {
        let muitos = (1 ... 300).map { "src/arquivo\($0).ts" }
        let texto = AppleProvider.instrucoes(
            Prompts.build(mode: .build, fileList: muitos, extras: ["Regras do projeto: nenhuma."]),
            comFerramentas: true
        )
        #expect(texto.contains("src/arquivo1.ts"), "a lista de arquivos não entrou")
        #expect(!texto.contains("src/arquivo\(AppleProvider.quantosArquivos + 1).ts"), "a lista passou do corte")
        #expect(!texto.contains("Regras do projeto"), "a leitura passou da lista e entrou na seção seguinte")
    }

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

    @Test func semListaNoSistemaAsInstrucoesSeguemInteiras() {
        let texto = AppleProvider.instrucoes("qualquer coisa sem lista", comFerramentas: true)
        #expect(!texto.contains("Arquivos do projeto:"))
        #expect(texto.contains("Você é a Odete"))
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
