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
        let paraEntrada = max(1024, janela - respostaMaxima)
        return Int(Double(paraEntrada) * 3.5 * 0.85)
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

    public init() {}

    public static var disponivel: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    /// Explicação em português do porquê de não dar para usar, ou nada quando dá.
    public static var impedimento: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case let .unavailable(motivo):
            switch motivo {
            case .deviceNotEligible:
                "Este aparelho não roda o Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                "Ligue o Apple Intelligence nos Ajustes do iPad."
            case .modelNotReady:
                "O modelo ainda está sendo baixado. Tente de novo daqui a pouco."
            @unknown default:
                tr("O modelo do sistema não está disponível agora.")
            }
        }
    }

    /// A janela vem do próprio modelo a partir do iOS 26.4; antes disso a Apple
    /// documenta 4096 fichas por sessão.
    public static var janela: Int {
        if #available(iOS 26.4, *) {
            return SystemLanguageModel.default.contextSize
        }
        return 4096
    }

    /// A nuvem privada está disponível? Só do iOS 27 em diante, e só em aparelho que a
    /// Apple considera elegível.
    public static var nuvemDisponivel: Bool {
        guard #available(iOS 27.0, *) else { return false }
        return PrivateCloudComputeLanguageModel().isAvailable
    }

    /// Por que a nuvem não dá, quando não dá.
    public static var impedimentoDaNuvem: String? {
        guard #available(iOS 27.0, *) else {
            return tr("A nuvem privada da Apple pede iPadOS 27.")
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

    public func models() async throws -> [ModelInfo] {
        var out = [ModelInfo(id: Self.idLocal, label: "Apple · no aparelho", efforts: nil, ctx: Self.janela)]
        if Self.nuvemDisponivel {
            // A janela da nuvem não é publicada pelo framework; o que se sabe é que é
            // bem maior que a local. Fica o número da sessão, que é o que limita aqui.
            out.append(ModelInfo(
                id: Self.idNuvem,
                label: "Apple · nuvem privada",
                efforts: nil,
                ctx: Self.janelaDaNuvem
            ))
        }
        return out
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

    /// Todas as ferramentas do modo, sem peneira.
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
        turn.tools.compactMap { spec in
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
        let (transcricao, prompt) = TranscricaoApple.montar(
            turn.messages,
            instrucoes: instrucoes(turn.system, comFerramentas: !ferramentas.isEmpty),
            ferramentas: ferramentas,
            orcamento: naNuvem ? janelaDaNuvem : orcamentoDeEntrada
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
                if let impedimento = naNuvem ? Self.impedimentoDaNuvem : Self.impedimento {
                    cont.yield(.error(impedimento))
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
                    var anterior = ""
                    let fluxo = sessao.streamResponse(
                        to: prompt,
                        options: GenerationOptions(
                            temperature: 0.6,
                            maximumResponseTokens: ferramentas.isEmpty
                                ? Self.respostaMaxima
                                : Self.respostaComFerramentas
                        )
                    )
                    for try await pedaco in fluxo {
                        if Task.isCancelled {
                            break
                        }
                        let texto = pedaco.content
                        if texto.count > anterior.count {
                            cont.yield(.text(String(texto.dropFirst(anterior.count))))
                            anterior = texto
                        }
                    }
                    Self.encerra(cont, pedidos.withLock { $0 })
                } catch let erro as LanguageModelSession.GenerationError {
                    // É por aqui que o pedido de ferramenta chega: a ferramenta anota e
                    // lança, e o framework embrulha isso num erro de geração. Com pedido
                    // anotado não houve falha nenhuma — o turno só acabou mais cedo.
                    let anotados = pedidos.withLock { $0 }
                    guard anotados.isEmpty else {
                        Self.encerra(cont, anotados)
                        return
                    }
                    cont.yield(.error(Self.explicar(erro)))
                    cont.finish()
                } catch {
                    let anotados = pedidos.withLock { $0 }
                    guard anotados.isEmpty else {
                        Self.encerra(cont, anotados)
                        return
                    }
                    if let recado = Self.explicarNuvem(error) {
                        cont.yield(.error(recado))
                        cont.finish()
                        return
                    }
                    cont.yield(.error(error.localizedDescription))
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
    static var orcamentoDeInstrucoes: Int {
        orcamentoDeEntrada / 2
    }

    /// O mesmo prompt que os provedores por assinatura recebem — ver `AppleInstrucoes`.
    static func instrucoes(_ sistema: String, comFerramentas: Bool) -> String {
        AppleInstrucoes.texto(sistema: sistema, comFerramentas: comFerramentas, teto: orcamentoDeInstrucoes)
    }

    /// Junta o histórico num prompt só, cortando o começo até caber na janela.
    /// O corte tem dois limites, e os dois precisam acompanhar a janela: o número de
    /// mensagens e o tamanho em caracteres. Só mexer no segundo não adianta — o primeiro
    /// amarra antes, e o modelo grande recebe a mesma conversinha do pequeno.
    /// A cota da nuvem é por uso e vem com data de renovação: dizer "tente de novo" sem
    /// dizer quando não ajuda ninguém.
    static func explicarNuvem(_ erro: Error) -> String? {
        guard #available(iOS 27.0, *) else { return nil }
        switch erro {
        case let cota as PrivateCloudComputeLanguageModel.Error.QuotaLimitReached:
            if let quando = cota.resetDate {
                let f = DateFormatter()
                f.dateStyle = .short
                f.timeStyle = .short
                return tr("A cota da nuvem privada da Apple acabou. Ela renova em %1$@.", f.string(from: quando))
            }
            return tr("A cota da nuvem privada da Apple acabou por enquanto.")
        case is PrivateCloudComputeLanguageModel.Error.ServiceUnavailable:
            return tr("A nuvem privada da Apple não respondeu. Tente de novo.")
        default:
            return nil
        }
    }

    static func explicar(_ erro: LanguageModelSession.GenerationError) -> String {
        switch erro {
        case .exceededContextWindowSize:
            tr("A conversa passou da janela de %1$@ fichas do modelo. Comece uma conversa nova.", "\(janela)")
        case .guardrailViolation:
            "O filtro de segurança da Apple barrou este pedido."
        case .unsupportedLanguageOrLocale:
            "O modelo do sistema não atende este idioma."
        default:
            erro.localizedDescription
        }
    }
}

/// Escolhe o provedor certo para a conta.
public enum ProviderFactory {
    public static func make(account: AIAccount, session: @autoclosure () -> Session) -> any Provider {
        account.kind == .apple ? AppleProvider() : HTTPProvider(account: account, session: session())
    }
}
