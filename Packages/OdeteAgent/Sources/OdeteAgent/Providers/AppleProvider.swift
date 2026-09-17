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

    /// As ferramentas que cabem no modelo local.
    ///
    /// Toda ferramenta ocupa lugar na janela: nome, descrição e schema entram nas
    /// instruções antes de qualquer conversa. Numa janela de poucos milhares de fichas,
    /// oferecer as sete é gastar metade do orçamento explicando ferramenta que não vai
    /// ser usada. Ficam as que fazem o trabalho de editar código; `github`, que tem a
    /// descrição mais longa de todas, fica de fora do modelo local.
    static let enxutas: Set<String> = ["read_file", "str_replace", "write_file", "list_dir", "grep", "run_shell"]

    static func ferramentas(
        _ turn: TurnRequest,
        anotar: @escaping @Sendable (String, String) -> Void
    ) -> [any Tool] {
        let naNuvem = turn.model == idNuvem
        return turn.tools.compactMap { spec in
            guard naNuvem || enxutas.contains(spec.name) else { return nil }
            guard let esquema = try? EsquemaApple.esquema(de: spec) else { return nil }
            return FerramentaDaOdete(
                name: spec.name,
                description: spec.description,
                parameters: esquema,
                anotar: anotar
            )
        }
    }

    /// A sessão da rodada, com o modelo que o pedido escolheu.
    static func sessao(_ turn: TurnRequest, ferramentas: [any Tool]) -> LanguageModelSession {
        if turn.model == idNuvem, #available(iOS 27.0, *), nuvemDisponivel {
            return LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(),
                tools: ferramentas,
                instructions: Instructions(instrucoes(turn.system, comFerramentas: !ferramentas.isEmpty))
            )
        }
        return LanguageModelSession(
            model: .default,
            tools: ferramentas,
            instructions: instrucoes(turn.system, comFerramentas: !ferramentas.isEmpty)
        )
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
                    let sessao = Self.sessao(turn, ferramentas: ferramentas)
                    let prompt = Self.prompt(
                        turn.messages,
                        orcamento: naNuvem ? Self.janelaDaNuvem : Self
                            .orcamentoDeEntrada
                    )
                    var anterior = ""
                    let fluxo = sessao.streamResponse(
                        to: prompt,
                        options: GenerationOptions(temperature: 0.6, maximumResponseTokens: Self.respostaMaxima)
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

    /// As instruções do agente completo não cabem aqui. Fica o essencial.
    ///
    /// O que entra é escrito para este modelo, e não recortado do prompt grande. A versão
    /// antiga pescava do sistema a primeira linha que falasse em "projeto" e colava aqui;
    /// como essa linha é `O projeto é uma pasta real no dispositivo. A lista de caminhos
    /// vem no sistema; o conteúdo só entra se VOCÊ chamar read_file`, o modelo pequeno
    /// devolvia isso parafraseado na cara de quem perguntou. Entranha do sistema não é
    /// resposta.
    static func instrucoes(_ sistema: String, comFerramentas: Bool) -> String {
        let arquivos = Self.arquivosDoSistema(sistema)
        let comoAgir = comFerramentas
            ? """
            Você mexe no projeto de verdade, pelas ferramentas.

            - Aja, não peça licença. Nunca pergunte "posso seguir?", "confirma?" ou "quer
              que eu liste?". Quem aprova é o app: cada mudança aparece para a pessoa
              aceitar antes de valer. Pergunte só quando o pedido for ambíguo a ponto de
              você não saber em qual arquivo mexer.
            - Uma ferramenta por vez. O resultado chega na mensagem seguinte, e aí você
              segue sozinho, até terminar o que foi pedido.
            - Leia antes de escrever. Em str_replace, `old` tem que ser copiado caractere
              por caractere do que o read_file devolveu — nunca escrito de memória. Se o
              trecho não for encontrado, leia o arquivo de novo em vez de tentar outro
              palpite.
            - Não sabe o caminho? list_dir ou grep, sem perguntar.
            - Nunca responda que não consegue editar.
            """
            : """
            Nesta rodada você está sem ferramentas: responda com o que dá para responder
            e diga, em uma frase, o que precisaria abrir para ir além.
            """
        return """
        Você é a Odete, assistente de programação dentro de um editor no iPad.
        Responda em \(Texto.idioma.paraOModelo), com objetividade, em no máximo dois parágrafos
        curtos ou uma lista curta. Use markdown. Quando não souber, diga que não sabe.
        \(comoAgir)\(modoDoSistema(sistema))\(arquivos)
        """
    }

    /// A linha do modo, tirada do prompt grande.
    ///
    /// Sem ela o modelo não sabe se está em CHAT, PLAN ou BUILD — e no BUILD, que é o
    /// modo em que ele pode editar, ficava perguntando se podia editar. As instruções
    /// daqui são escritas à parte de propósito, mas o modo não dá para inventar: ele é
    /// uma escolha que a pessoa fez na tela.
    static func modoDoSistema(_ sistema: String) -> String {
        guard let linha = sistema.split(separator: "\n").first(where: { $0.hasPrefix("Modo ") }) else { return "" }
        return "\n\n" + linha
    }

    /// Os primeiros caminhos do projeto, para o modelo não gastar uma rodada de `list_dir`
    /// só para descobrir que existe um `src/`.
    ///
    /// O prompt grande manda até 400 caminhos; aqui cabem poucos, e poucos já resolvem o
    /// caso comum — quem quiser o resto pede `list_dir`. O corte é por quantidade e não
    /// por caractere para a lista nunca terminar no meio de um caminho.
    static let quantosArquivos = 40

    static func arquivosDoSistema(_ sistema: String) -> String {
        guard let faixa = sistema.range(of: "Arquivos no projeto:\n") else { return "" }
        // As seções do prompt grande são separadas por linha em branco, então é a linha
        // em branco que marca o fim da lista.
        let caminhos = sistema[faixa.upperBound...]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.isEmpty }
            .prefix(quantosArquivos)
        if caminhos.isEmpty {
            return ""
        }
        return "\n\nArquivos do projeto:\n" + caminhos.joined(separator: "\n")
    }

    /// Junta o histórico num prompt só, cortando o começo até caber na janela.
    /// O corte tem dois limites, e os dois precisam acompanhar a janela: o número de
    /// mensagens e o tamanho em caracteres. Só mexer no segundo não adianta — o primeiro
    /// amarra antes, e o modelo grande recebe a mesma conversinha do pequeno.
    /// Quanto de um resultado de ferramenta cabe numa mensagem do histórico.
    ///
    /// Estava preso em 400 caracteres. Para conversar bastava; para editar, não: quem
    /// pede `read_file` e recebe um pedaço do arquivo não tem como montar um
    /// `str_replace` com o trecho exato, e o modelo passa a errar por falta de texto, não
    /// por falta de capacidade. Um terço do orçamento é o que sobra para o arquivo depois
    /// das instruções e da conversa — o que não couber ele busca de novo, com `grep` ou
    /// lendo outro pedaço.
    static func tetoDoResultado(_ orcamento: Int) -> Int {
        max(400, orcamento / 3)
    }

    static func prompt(_ mensagens: [AgentMessage], orcamento: Int = orcamentoDeEntrada) -> String {
        var partes: [String] = []
        let quantas = max(20, (orcamento / orcamentoDeEntrada) * 20)
        let teto = tetoDoResultado(orcamento)
        for m in mensagens.suffix(quantas) {
            switch m.role {
            case .user:
                partes.append("Pessoa: " + m.content)
            case .assistant:
                if !m.content.isEmpty {
                    partes.append("Odete: " + m.content)
                }
                // O pedido entra mesmo quando não veio texto junto: sem ele a rodada
                // seguinte vê um resultado caído do céu, sem saber de qual arquivo é nem
                // por que foi pedido.
                for chamada in m.toolCalls ?? [] {
                    partes.append(tr("Odete pediu %1$@: %2$@", chamada.name, chamada.arguments))
                }
            case .tool:
                partes.append(tr("Resultado de ferramenta: ") + m.content.prefix(teto))
            default:
                break
            }
        }
        while partes.count > 1 {
            let texto = partes.joined(separator: "\n\n")
            if texto.count <= orcamento {
                return texto
            }
            partes.removeFirst()
        }
        return String((partes.first ?? "").suffix(orcamento))
    }

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
