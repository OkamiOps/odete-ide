import Foundation
import FoundationModels

/// O modelo de linguagem do sistema, no próprio aparelho.
///
/// Com a SDK do iOS 26 o framework `FoundationModels` só expõe a apps de terceiros o
/// modelo local, de cerca de três bilhões de parâmetros, com janela medida em tempo de
/// execução: 4096 fichas contando entrada e saída. O modelo grande do Private Cloud
/// Compute atende funcionalidades do sistema e não tem API pública aqui.
///
/// Em troca: não precisa de conta, não precisa de rede e não sai nada do iPad.
///
/// Para ligar a nuvem quando a SDK do iOS 27 estiver instalada: trocar `model: .default`
/// por uma `PrivateCloudComputeLanguageModel` atrás de `if #available(iOS 27, *)`,
/// oferecer os dois como modelos diferentes em `models()` com a janela de cada um, e
/// pedir o entitlement `com.apple.developer.private-cloud-compute`, que a Apple aprova
/// caso a caso. O resto desta implementação continua igual: a sessão é a mesma classe.
public struct AppleProvider: Provider {
    public let kind: ProviderKind = .apple
    /// A janela é de 4096 fichas contando entrada e saída. O orçamento de entrada é em
    /// caracteres porque a contagem de fichas do framework só existe do iOS 26.4 em
    /// diante; em português dá mais ou menos três caracteres e meio por ficha.
    static let orcamentoDeEntrada = 8000
    static let respostaMaxima = 900

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
                "O modelo do sistema não está disponível agora."
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

    public func models() async throws -> [ModelInfo] {
        [ModelInfo(id: "apple-on-device", label: "Apple · no aparelho", efforts: nil, ctx: Self.janela)]
    }

    public func stream(_ turn: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let tarefa = Task {
                if let impedimento = Self.impedimento {
                    cont.yield(.error(impedimento))
                    cont.finish()
                    return
                }
                do {
                    let sessao = LanguageModelSession(
                        model: .default,
                        instructions: Self.instrucoes(turn.system)
                    )
                    let prompt = Self.prompt(turn.messages)
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
                    cont.yield(.usage(TokenUse(input: 0, output: 0)))
                    cont.finish()
                } catch let erro as LanguageModelSession.GenerationError {
                    cont.yield(.error(Self.explicar(erro)))
                    cont.finish()
                } catch {
                    cont.yield(.error(error.localizedDescription))
                    cont.finish()
                }
            }
            cont.onTermination = { _ in tarefa.cancel() }
        }
    }

    /// As instruções do agente completo não cabem aqui. Fica o essencial.
    static func instrucoes(_ sistema: String) -> String {
        let projeto = sistema
            .split(separator: "\n")
            .first { $0.lowercased().contains("projeto") }
            .map(String.init) ?? ""
        return """
        Você é a Odete, assistente de programação dentro de um editor no iPad.
        Responda em português do Brasil, com objetividade, em no máximo dois parágrafos
        curtos ou uma lista curta. Use markdown. Quando não souber, diga que não sabe.
        Você não edita arquivos nem roda comandos: para isso a pessoa precisa de uma
        conta de IA com ferramentas. \(projeto)
        """
    }

    /// Junta o histórico num prompt só, cortando o começo até caber na janela.
    static func prompt(_ mensagens: [AgentMessage]) -> String {
        var partes: [String] = []
        for m in mensagens.suffix(20) {
            switch m.role {
            case .user: partes.append("Pessoa: " + m.content)
            case .assistant where !m.content.isEmpty: partes.append("Odete: " + m.content)
            case .tool: partes.append("Resultado de ferramenta: " + m.content.prefix(400))
            default: break
            }
        }
        while partes.count > 1 {
            let texto = partes.joined(separator: "\n\n")
            if texto.count <= orcamentoDeEntrada {
                return texto
            }
            partes.removeFirst()
        }
        return String((partes.first ?? "").suffix(orcamentoDeEntrada))
    }

    static func explicar(_ erro: LanguageModelSession.GenerationError) -> String {
        switch erro {
        case .exceededContextWindowSize:
            "A conversa passou da janela de \(janela) fichas do modelo local. Comece uma conversa nova."
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
