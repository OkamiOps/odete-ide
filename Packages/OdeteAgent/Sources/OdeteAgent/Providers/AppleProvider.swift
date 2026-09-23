import Foundation
import FoundationModels
import OdeteI18n
import Synchronization

/// O modelo de linguagem do sistema, no próprio aparelho.
///
/// O modelo local vem do sistema e muda com ele: a Apple troca a geração do modelo numa
/// atualização de iPadOS e o app não recompila. Por isso **nenhum número aqui é fixo** —
/// janela, orçamento de entrada e tamanho de resposta saem todos de `contextSize`, que o
/// aparelho informa em tempo de execução. Quem chegar num aparelho com janela maior usa
/// a janela maior sem trocar uma linha.
///
/// Em troca: não precisa de conta, não precisa de rede e não sai nada do iPad.
///
/// A partir do iOS 27 existe um segundo nível: `PrivateCloudComputeLanguageModel`, o
/// modelo grande da Apple rodando no Private Cloud Compute. É o mesmo `LanguageModelSession`
/// — só muda o modelo que entra nela —, continua sem conta e sem chave, e tem cota, que
/// aparece como erro com data de renovação. Os dois são oferecidos como modelos separados.
public struct AppleProvider: Provider {
    public let kind: ProviderKind = .apple
    /// Identificadores que aparecem em `models()` e chegam de volta em `TurnRequest.model`.
    public static let idLocal = "apple-on-device"
    public static let idNuvem = "apple-private-cloud"
    /// Orçamento de entrada, em caracteres, derivado da janela que o aparelho informa.
    ///
    /// Estava fixo em 8000 — o que dava certo para a janela de 4096 fichas do modelo de
    /// terceira geração da SDK 26 e **parava aí**. Quando a Apple troca o modelo por um
    /// com janela maior, `contextSize` cresce sozinho e este número tinha que crescer
    /// junto, senão a Odete continua mandando meia conversa para um modelo que aguentava
    /// o dobro. Em caracteres e não em fichas porque a contagem de fichas do framework
    /// só existe do iOS 26.4 em diante; em português dá uns três caracteres e meio por
    /// ficha, e o desconto de 15% é a margem para essa conta ser aproximada.
    static var orcamentoDeEntrada: Int {
        orcamentoDeEntrada(comFerramentas: false)
    }

    /// Com ferramentas sobra menos: o teto da resposta sobe, e o que sobe lá tem que
    /// descer aqui.
    ///
    /// Estava contando contra `respostaMaxima` mesmo quando a geração usava
    /// `respostaComFerramentas`, que é maior. Somado à conta de instruções, que pedia
    /// metade *deste* número em vez de metade do total, o provedor mandava uma vez e meia
    /// o que cabia — foi o que apareceu no medidor do app como 329% da janela.
    static func orcamentoDeEntrada(comFerramentas: Bool) -> Int {
        let resposta = comFerramentas ? respostaComFerramentas : respostaMaxima
        let paraEntrada = max(1024, janela - resposta)
        return Int(Double(paraEntrada) * 3.5 * 0.85)
    }

    /// O que as definições de ferramenta ocupam nas instruções.
    ///
    /// Nome, descrição e schema de cada uma entram na sessão antes de qualquer conversa,
    /// e isso não é de graça: com oito ferramentas são milhares de caracteres. Sem
    /// descontar, o orçamento da conversa mente.
    static func custoDasFerramentas(_ specs: [ToolSpec]) -> Int {
        specs.reduce(0) { $0 + $1.name.count + $1.description.count + $1.parametersJSON.count }
    }

    /// A resposta também acompanha: um quarto da janela, com teto para a pessoa não
    /// esperar três parágrafos quando pediu uma linha.
    static var respostaMaxima: Int {
        min(1500, max(400, janela / 4))
    }

    /// Com ferramentas o teto sobe, e o de 1500 fichas sai de cena.
    ///
    /// Os argumentos da chamada saem no mesmo orçamento da resposta: um `write_file` de
    /// arquivo inteiro bate no teto e volta truncado, e o que se vê na tela é o modelo
    /// "não conseguindo" — por falta de espaço, não de juízo. O teto de conversa existia
    /// para ninguém receber três parágrafos ao pedir uma linha; para escrever arquivo ele
    /// só atrapalha.
    static var respostaComFerramentas: Int {
        max(respostaMaxima, janela / 3)
    }

    /// Na nuvem o teto é outro: o do aparelho sai da janela do modelo pequeno.
    ///
    /// `respostaComFerramentas` é um terço de `janela`, que é a janela do modelo **local**
    /// — umas 2700 fichas. Usar esse número na nuvem é pedir a um modelo grande que
    /// escreva pela régua do pequeno: um `write_file` de arquivo inteiro volta cortado no
    /// meio, e o que aparece na tela é o modelo grande "falhando" por falta de espaço.
    static let respostaDaNuvem = 8000

    public init() {}

    public static var disponivel: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    /// Por que não dá para usar, ou nada quando dá. Aparece no seletor, nos Ajustes e —
    /// com o que fazer em seguida — no cartão de erro da conversa.
    public static var impedimento: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case let .unavailable(motivo):
            switch motivo {
            case .deviceNotEligible:
                tr("Este aparelho não roda o Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                tr("Ligue o Apple Intelligence em Ajustes › Apple Intelligence e Siri.")
            case .modelNotReady:
                tr("O modelo ainda está sendo baixado. Tente de novo daqui a pouco.")
            @unknown default:
                tr("O modelo do sistema não está disponível agora.")
            }
        }
    }

    /// O impedimento do modelo escolhido: o do aparelho ou o da nuvem.
    public static func impedimento(doModelo id: String) -> String? {
        id == idNuvem ? impedimentoDaNuvem : impedimento
    }

    /// A janela vem do próprio modelo a partir do iOS 26.4; antes disso a Apple
    /// documenta 4096 fichas por sessão.
    public static var janela: Int {
        if #available(iOS 26.4, *) {
            return SystemLanguageModel.default.contextSize
        }
        return 4096
    }

    /// A Odete já tem a permissão da Apple para usar a nuvem privada?
    ///
    /// Usar `PrivateCloudComputeLanguageModel` não depende só do aparelho: a Apple exige
    /// do app a entitlement gerenciada `com.apple.developer.private-cloud-compute`, que
    /// não se marca no Xcode — se pede num formulário e ela é concedida. Medido aqui no
    /// Mac, com o modelo da nuvem dizendo `isAvailable: true` e `availability: available`:
    /// a sessão é criada, a primeira resposta é pedida e o framework **derruba o
    /// processo** com "Missing entitlement: com.apple.developer.private-cloud-compute".
    /// Não é erro que dá para pegar num `catch`; é `fatalError` dentro do framework.
    ///
    /// Por isso a chave é esta, e não `isAvailable`: oferecer a nuvem sem a entitlement
    /// não daria uma mensagem de erro, daria um app que fecha sozinho quando a pessoa
    /// escolhe o modelo.
    ///
    /// Quando a concessão sair, isto vira `true` **e** a entitlement entra em
    /// `Odete/Odete.entitlements`. As duas coisas andam juntas: uma sem a outra é o
    /// mesmo estrago. O pedido é feito em
    /// <https://developer.apple.com/contact/request/private-cloud-compute/>.
    public static let temPermissaoDaNuvem = false

    /// A nuvem privada está disponível? Precisa da permissão da Apple, do iOS 27 em
    /// diante, e de um aparelho que a Apple considere elegível.
    public static var nuvemDisponivel: Bool {
        guard temPermissaoDaNuvem, #available(iOS 27.0, *) else { return false }
        return PrivateCloudComputeLanguageModel().isAvailable
    }

    /// Por que a nuvem não dá, quando não dá.
    public static var impedimentoDaNuvem: String? {
        guard #available(iOS 27.0, *) else {
            return tr("A nuvem privada da Apple pede iPadOS 27.")
        }
        // A falta da permissão vem antes de qualquer conversa sobre o aparelho: o
        // aparelho pode estar pronto e o app não poder usar assim mesmo.
        guard temPermissaoDaNuvem else {
            return tr("A Apple ainda não liberou a permissão para a Odete usar a nuvem privada.")
        }
        switch PrivateCloudComputeLanguageModel().availability {
        case .available: return nil
        case let .unavailable(motivo):
            switch motivo {
            case .deviceNotEligible:
                return tr("Este aparelho não é elegível para a nuvem privada da Apple.")
            case .systemNotReady:
                return tr("A nuvem privada da Apple ainda não está pronta. Tente daqui a pouco.")
            @unknown default:
                return tr("A nuvem privada da Apple não está disponível agora.")
            }
        }
    }

    /// Os dois modelos, sempre — com o motivo quando um deles não dá.
    ///
    /// A nuvem privada só aparecia quando estava disponível, e isso a tornava invisível:
    /// quem está no iPadOS 27 e não a vê na lista conclui que a Odete não tem, e não que
    /// o aparelho ainda não liberou. A linha aparece dos dois jeitos; o que muda é poder
    /// tocar nela.
    public func models() async throws -> [ModelInfo] {
        [
            ModelInfo(
                id: Self.idLocal,
                label: "Apple · no aparelho",
                efforts: nil,
                ctx: Self.janela,
                indisponivel: Self.impedimento
            ),
            // A janela da nuvem não é publicada pelo framework; o que se sabe é que é bem
            // maior que a local. Fica o número da sessão, que é o que limita aqui.
            ModelInfo(
                id: Self.idNuvem,
                label: "Apple · nuvem privada",
                efforts: nil,
                ctx: Self.janelaDaNuvem,
                indisponivel: Self.impedimentoDaNuvem
            ),
        ]
    }

    /// Orçamento de entrada da nuvem. Mais generoso que o local, e ainda assim um teto:
    /// a cota da Apple é por uso, então mandar a conversa inteira a cada turno gasta à toa.
    static let janelaDaNuvem = 32000

    /// Fecha a rodada. O que o modelo pediu sai como `.tools`; quem executa é o laço do
    /// agente, que é onde mora a confirmação e a revisão do patch.
    static func encerra(_ cont: AsyncThrowingStream<StreamEvent, Error>.Continuation, _ pedidos: [ToolCall]) {
        if !pedidos.isEmpty {
            cont.yield(.tools(pedidos))
        }
        cont.yield(.usage(TokenUse(input: 0, output: 0)))
        cont.finish()
    }

    /// O que um retrato cumulativo da resposta trouxe de novo desde o último.
    ///
    /// O framework entrega a resposta inteira a cada passo, não o pedaço. Contar
    /// `Character` e cortar com `dropFirst` anda pelo texto todo a cada retrato — trabalho
    /// quadrático numa resposta longa. Em bytes UTF-8 as duas contas são diretas. E ainda
    /// pega o que a contagem de caracteres perdia: um acento que chega depois da letra não
    /// muda o número de caracteres, e sumia.
    static func trechoNovo(_ texto: String, enviados: inout Int) -> String? {
        let bytes = texto.utf8
        guard bytes.count > enviados else { return nil }
        let inicio = bytes.index(bytes.startIndex, offsetBy: enviados)
        enviados = bytes.count
        return String(decoding: bytes[inicio...], as: UTF8.self)
    }

    /// Ferramentas que ficam de fora do modelo **do aparelho**.
    ///
    /// A regra continua sendo não podar: o modelo local recebe o mesmo que os outros. A
    /// exceção é o que só repete outra ferramenta. Os erros do console do preview já
    /// chegam por `read_problems`; o console inteiro custaria umas duzentas letras de
    /// schema, tiradas da conversa numa janela de quatro mil fichas, para dizer quase a
    /// mesma coisa. A nuvem privada, com janela folgada, recebe tudo.
    static let soForaDoAparelho: Set<String> = ["read_preview_console"]

    /// As definições que vão para o modelo da vez.
    static func especificacoes(_ turn: TurnRequest) -> [ToolSpec] {
        turn.model == idNuvem ? turn.tools : turn.tools.filter { !soForaDoAparelho.contains($0.name) }
    }

    /// Todas as ferramentas do modo, sem peneira — fora a exceção de `soForaDoAparelho`.
    ///
    /// Aqui havia uma lista curta para o modelo local, tirando o `github` por ele ter a
    /// descrição mais longa. Era economia de mentira: a diferença é de algumas centenas
    /// de caracteres numa janela que o aparelho informa em milhares, e o preço era um
    /// modelo que sabe menos do que o da assinatura sem ninguém ter pedido isso. Quem
    /// decide o que cabe é o orçamento, não um palpite meu sobre o que a pessoa vai
    /// querer usar.
    static func ferramentas(
        _ turn: TurnRequest,
        anotar: @escaping @Sendable (String, String) -> Void
    ) -> [any Tool] {
        especificacoes(turn).compactMap { spec in
            guard let esquema = try? EsquemaApple.esquema(de: spec) else { return nil }
            return FerramentaDaOdete(
                name: spec.name,
                description: spec.description,
                parameters: esquema,
                anotar: anotar
            )
        }
    }

    /// A sessão da rodada, montada sobre a transcrição da conversa.
    ///
    /// A transcrição carrega as instruções e as ferramentas dentro dela — ver
    /// `TranscricaoApple`. Por isso não existe aqui um `instructions:` separado: ele
    /// duplicaria o que já é a primeira entrada.
    static func sessao(_ turn: TurnRequest, ferramentas: [any Tool]) -> (LanguageModelSession, String) {
        let naNuvem = turn.model == idNuvem
        let comFerramentas = !ferramentas.isEmpty
        let instrucoes = instrucoes(turn.system, comFerramentas: comFerramentas)
        // O que sobra para a conversa é o total menos o que as instruções e as definições
        // de ferramenta já ocuparam. Somar orçamentos independentes é como a sessão
        // acabava com mais texto do que a janela aguenta.
        let total = naNuvem ? janelaDaNuvem : orcamentoDeEntrada(comFerramentas: comFerramentas)
        let sobra = max(1000, total - instrucoes.count - custoDasFerramentas(especificacoes(turn)))
        let (transcricao, prompt) = TranscricaoApple.montar(
            turn.messages,
            instrucoes: instrucoes,
            ferramentas: ferramentas,
            orcamento: sobra
        )
        if naNuvem, #available(iOS 27.0, *), nuvemDisponivel {
            return (
                LanguageModelSession(
                    model: PrivateCloudComputeLanguageModel(),
                    tools: ferramentas,
                    transcript: transcricao
                ),
                prompt
            )
        }
        return (LanguageModelSession(model: .default, tools: ferramentas, transcript: transcricao), prompt)
    }

    public func stream(_ turn: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let tarefa = Task {
                let naNuvem = turn.model == Self.idNuvem
                // Quando a disponibilidade já sabe que não dá, o motivo dela vai para a
                // conversa em vez de um erro de geração: "ligue o Apple Intelligence"
                // diz o que fazer, "assets unavailable" não.
                if let impedimento = Self.impedimento(doModelo: turn.model) {
                    cont.yield(.error(FalhaApple.modeloIndisponivel(motivo: impedimento).frase))
                    cont.finish()
                    return
                }
                let pedidos = Mutex<[ToolCall]>([])
                do {
                    let ferramentas = Self.ferramentas(turn) { nome, argumentos in
                        pedidos.withLock {
                            $0.append(ToolCall(
                                id: "apple-\($0.count)-\(UUID().uuidString.prefix(8))",
                                name: nome,
                                arguments: argumentos
                            ))
                        }
                    }
                    let (sessao, prompt) = Self.sessao(turn, ferramentas: ferramentas)
                    var enviados = 0
                    let fluxo = sessao.streamResponse(
                        to: prompt,
                        options: GenerationOptions(
                            temperature: 0.6,
                            maximumResponseTokens: naNuvem
                                ? Self.respostaDaNuvem
                                : (ferramentas.isEmpty ? Self.respostaMaxima : Self.respostaComFerramentas)
                        )
                    )
                    for try await pedaco in fluxo {
                        if Task.isCancelled {
                            break
                        }
                        if let novo = Self.trechoNovo(pedaco.content, enviados: &enviados) {
                            cont.yield(.text(novo))
                        }
                    }
                    Self.encerra(cont, pedidos.withLock { $0 })
                } catch {
                    // É por aqui que o pedido de ferramenta chega: a ferramenta anota e
                    // lança, e o framework embrulha isso num erro. Com pedido anotado não
                    // houve falha nenhuma — o turno só acabou mais cedo.
                    let anotados = pedidos.withLock { $0 }
                    guard anotados.isEmpty else {
                        Self.encerra(cont, anotados)
                        return
                    }
                    // Nunca `localizedDescription`: sem descrição, ele vira "The operation
                    // couldn't be completed. (… error -1.)" na conversa. A disponibilidade
                    // é lida de novo porque pode ter mudado desde o começo do turno.
                    let recado = await Self.explicar(error, motivo: Self.impedimento(doModelo: turn.model))
                    cont.yield(.error(recado))
                    cont.finish()
                }
            }
            cont.onTermination = { _ in tarefa.cancel() }
        }
    }

    /// Orçamento de caracteres para as instruções.
    ///
    /// Metade do que entra; a outra metade é a conversa e o que as ferramentas
    /// devolveram. Acompanha a janela que o aparelho informa, como todo número daqui.
    /// Quanto do total as instruções podem ocupar: dois quintos, e o resto é a conversa.
    static func orcamentoDeInstrucoes(comFerramentas: Bool) -> Int {
        orcamentoDeEntrada(comFerramentas: comFerramentas) * 2 / 5
    }

    /// O mesmo prompt que os provedores por assinatura recebem — ver `AppleInstrucoes`.
    static func instrucoes(_ sistema: String, comFerramentas: Bool) -> String {
        AppleInstrucoes.texto(
            sistema: sistema,
            comFerramentas: comFerramentas,
            teto: orcamentoDeInstrucoes(comFerramentas: comFerramentas)
        )
    }

    /// A cota da nuvem é por uso e vem com data de renovação: dizer "tente de novo" sem
    /// dizer quando não ajuda ninguém.
    ///
    /// O erro é um enum com a cota e a indisponibilidade como casos. Aqui se testava
    /// `erro as QuotaLimitReached`, que é o valor associado e não um erro: o teste nunca
    /// passava, e a cota esgotada chegava na conversa como texto do sistema.
    static func explicarNuvem(_ erro: Error) -> String? {
        guard #available(iOS 27.0, *), let erro = erro as? PrivateCloudComputeLanguageModel.Error else {
            return nil
        }
        switch erro {
        case let .quotaLimitReached(cota):
            if let quando = cota.resetDate {
                let f = DateFormatter()
                f.dateStyle = .short
                f.timeStyle = .short
                return tr("A cota da nuvem privada da Apple acabou. Ela renova em %1$@.", f.string(from: quando))
            }
            return tr("A cota da nuvem privada da Apple acabou por enquanto.")
        case .serviceUnavailable, .networkFailure:
            return tr("A nuvem privada da Apple não respondeu. Tente de novo.")
        @unknown default:
            return nil
        }
    }
}

/// Escolhe o provedor certo para a conta.
public enum ProviderFactory {
    public static func make(account: AIAccount, session: @autoclosure () -> Session) -> any Provider {
        account.kind == .apple ? AppleProvider() : HTTPProvider(account: account, session: session())
    }
}
