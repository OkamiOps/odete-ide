import Foundation
import FoundationModels
import OdeteI18n

/// O que deu errado no modelo da Apple, do jeito que a Odete sabe explicar.
///
/// O framework falha de dois jeitos. No iPadOS 26 é tudo
/// `LanguageModelSession.GenerationError`; do 27 em diante esse tipo fica descontinuado
/// e cada falha vem de um lugar (`LanguageModelError`, `SystemLanguageModel.Error`,
/// `LanguageModelSession.Error`, `GeneratedContent.ParsingError`). Os dois caminhos
/// desembocam aqui, e daqui sai uma frase por situação: traduzida, e dizendo o que fazer.
///
/// O texto do sistema não serve para a conversa. Vem em inglês, e quando o erro chega
/// como `NSError` sem descrição vira "The operation couldn't be completed.
/// (FoundationModels.LanguageModelSession.GenerationError error -1.)" — foi o que o QA
/// viu num simulador sem o modelo pronto.
enum FalhaApple: Equatable {
    /// A conversa passou da janela. Leva o tamanho da janela, em tokens.
    case janelaEstourada(Int)
    /// O modelo não está no aparelho: desligado, baixando ou aparelho sem suporte. Leva o
    /// motivo que a disponibilidade informa, quando ela informa.
    case modeloIndisponivel(motivo: String?)
    case filtroDeSeguranca
    /// O modelo se recusou. A explicação é gerada pelo próprio modelo, quando dá.
    case recusa(explicacao: String?)
    case idiomaNaoAtendido
    /// Uma ferramenta, um formato de resposta ou um anexo que o modelo não sabe usar.
    case recursoNaoSuportado
    case respostaIlegivel
    case pedidosDemais
    case pedidoEmAndamento
    case demorou
    /// O que não tem frase própria: vai o nome do caso, ou domínio e código, entre
    /// parênteses — nunca a descrição crua do sistema.
    case outra(String)

    var frase: String {
        switch self {
        case let .janelaEstourada(janela):
            tr("A conversa passou da janela de %1$@ tokens do modelo. Comece uma conversa nova.", "\(janela)")
        case let .modeloIndisponivel(motivo?):
            tr("%1$@ Para continuar agora, escolha outro modelo no seletor.", motivo)
        case .modeloIndisponivel(nil):
            tr(
                "O modelo da Apple ainda não está pronto neste aparelho. Confira em Ajustes › Apple Intelligence e Siri, ou escolha outro modelo no seletor."
            )
        case .filtroDeSeguranca:
            tr(
                "O filtro de segurança da Apple barrou este pedido. Reescreva o pedido ou escolha outro modelo no seletor."
            )
        case let .recusa(explicacao?):
            tr("O modelo da Apple se recusou a responder: %1$@", explicacao)
        case .recusa(nil):
            tr(
                "O modelo da Apple se recusou a responder a este pedido. Reescreva o pedido ou escolha outro modelo no seletor."
            )
        case .idiomaNaoAtendido:
            tr("O modelo da Apple não atende este idioma. Escolha outro modelo no seletor.")
        case .recursoNaoSuportado:
            tr(
                "O modelo da Apple não aceita algo deste pedido, como uma ferramenta ou um anexo. Escolha outro modelo no seletor."
            )
        case .respostaIlegivel:
            tr("O modelo da Apple devolveu uma resposta que não deu para ler. Tente de novo.")
        case .pedidosDemais:
            tr("O modelo da Apple recebeu pedidos demais. Espere alguns segundos e tente de novo.")
        case .pedidoEmAndamento:
            tr("O modelo da Apple ainda está respondendo ao pedido anterior. Espere terminar e tente de novo.")
        case .demorou:
            tr("O modelo da Apple demorou demais para responder. Tente de novo.")
        case let .outra(rotulo):
            tr("O modelo da Apple falhou (%1$@). Tente de novo ou escolha outro modelo no seletor.", rotulo)
        }
    }
}

extension AppleProvider {
    /// A falha do iPadOS 26, caso a caso.
    ///
    /// `motivo` é o impedimento da disponibilidade no momento da falha: quando o modelo
    /// sumiu porque o Apple Intelligence foi desligado ou ainda está baixando, a pessoa
    /// lê isso, e não "assets unavailable". `janela` entra por fora para o teste não
    /// depender do aparelho.
    static func falha(
        _ erro: LanguageModelSession.GenerationError,
        motivo: String?,
        janela: Int? = nil,
        explicacaoDaRecusa: String? = nil
    ) -> FalhaApple {
        switch erro {
        case .exceededContextWindowSize: .janelaEstourada(janela ?? Self.janela)
        case .assetsUnavailable: .modeloIndisponivel(motivo: motivo)
        case .guardrailViolation: .filtroDeSeguranca
        case .unsupportedGuide: .recursoNaoSuportado
        case .unsupportedLanguageOrLocale: .idiomaNaoAtendido
        case .decodingFailure: .respostaIlegivel
        case .rateLimited: .pedidosDemais
        case .concurrentRequests: .pedidoEmAndamento
        case .refusal: .recusa(explicacao: explicacaoDaRecusa)
        // O runtime do iPadOS 26.5 já traz um caso que a SDK não publica
        // (`unsupportedCapability`). Caso novo cai aqui, com o nome dele.
        @unknown default: .outra(rotulo(erro))
        }
    }

    /// As falhas do iPadOS 27, que substituem `GenerationError`. Nada quando o erro não é
    /// do modelo da Apple.
    @available(iOS 27.0, *)
    static func falhaDoFramework(_ erro: any Error, motivo: String?) -> FalhaApple? {
        switch erro {
        case let e as LanguageModelError:
            switch e {
            case let .contextSizeExceeded(c): return .janelaEstourada(c.contextSize)
            case .rateLimited: return .pedidosDemais
            case .guardrailViolation: return .filtroDeSeguranca
            case .refusal: return .recusa(explicacao: nil)
            case .unsupportedCapability, .unsupportedGenerationGuide, .unsupportedTranscriptContent:
                return .recursoNaoSuportado
            case .unsupportedLanguageOrLocale: return .idiomaNaoAtendido
            case .timeout: return .demorou
            @unknown default: return .outra(rotulo(erro))
            }
        case is SystemLanguageModel.Error:
            return .modeloIndisponivel(motivo: motivo)
        case let e as LanguageModelSession.Error:
            switch e {
            case .concurrentRequests, .transcriptMutationWhileResponding: return .pedidoEmAndamento
            @unknown default: return .outra(rotulo(erro))
            }
        case is GeneratedContent.ParsingError:
            return .respostaIlegivel
        default:
            return nil
        }
    }

    /// O que vai para o cartão de erro da conversa.
    ///
    /// Igual a `explicarQualquer`, mais a recusa: para ela o framework sabe gerar uma
    /// explicação, e a frase fica melhor com ela do que com um "recusou" seco.
    static func explicar(_ erro: any Error, motivo: String?) async -> String {
        if let g = erro as? LanguageModelSession.GenerationError, case let .refusal(recusa, _) = g {
            let explicacao = await explicacaoDaRecusa { try await recusa.explanation.content }
            return falha(g, motivo: motivo, explicacaoDaRecusa: explicacao).frase
        }
        if #available(iOS 27.0, *), let e = erro as? LanguageModelError, case let .refusal(recusa) = e {
            let explicacao = await explicacaoDaRecusa { try await recusa.explanation.content }
            return FalhaApple.recusa(explicacao: explicacao).frase
        }
        return explicarQualquer(erro, motivo: motivo)
    }

    /// Qualquer erro que chegue do modelo da Apple, em frase. Nunca a descrição do sistema.
    ///
    /// Primeiro as falhas conhecidas; depois, se o modelo deixou de estar disponível no
    /// meio do caminho, o motivo disso; por fim o nome do erro entre parênteses.
    static func explicarQualquer(_ erro: any Error, motivo: String?) -> String {
        if let erro = erro as? LanguageModelSession.GenerationError {
            return falha(erro, motivo: motivo).frase
        }
        if #available(iOS 27.0, *), let falha = falhaDoFramework(erro, motivo: motivo) {
            return falha.frase
        }
        if let recado = explicarNuvem(erro) {
            return recado
        }
        if let motivo {
            return FalhaApple.modeloIndisponivel(motivo: motivo).frase
        }
        return FalhaApple.outra(rotulo(erro)).frase
    }

    /// Nome curto do erro, para ir entre parênteses quando não há frase melhor.
    ///
    /// Enum do Swift vira `Tipo.caso` ("GenerationError.rateLimited"); `NSError` vira o
    /// fim do domínio e o código ("GenerationError -1"). A descrição do sistema fica de
    /// fora de propósito: é ela o texto cru que não pode aparecer.
    static func rotulo(_ erro: any Error) -> String {
        let ns = erro as NSError
        guard !(type(of: erro) is NSError.Type) else {
            let dominio = ns.domain.split(separator: ".").last.map(String.init) ?? ns.domain
            return "\(dominio) \(ns.code)"
        }
        let tipo = String(describing: type(of: erro))
        let espelho = Mirror(reflecting: erro)
        if espelho.displayStyle == .enum {
            if let caso = espelho.children.first?.label {
                return "\(tipo).\(caso)"
            }
            // Caso sem valor associado: o espelho não tem filho, e o nome é a descrição —
            // a não ser que o tipo escreva uma frase no lugar.
            let nome = String(describing: erro)
            if !nome.isEmpty, nome.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                return "\(tipo).\(nome)"
            }
        }
        return "\(tipo) \(ns.code)"
    }

    /// Pede ao modelo a explicação da recusa, com prazo.
    ///
    /// A explicação é outra geração do mesmo modelo, e o cartão de erro não pode ficar
    /// esperando por ela: passando do prazo, a frase sai sem explicação.
    static func explicacaoDaRecusa(
        prazo: Duration = .seconds(8),
        _ pedir: @escaping @Sendable () async throws -> String
    ) async -> String? {
        let texto = await withTaskGroup(of: String?.self) { grupo in
            grupo.addTask { try? await pedir() }
            grupo.addTask {
                try? await Task.sleep(for: prazo)
                return nil
            }
            let primeiro = await grupo.next() ?? nil
            grupo.cancelAll()
            return primeiro
        }
        let limpo = texto?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return limpo.isEmpty ? nil : limpo
    }
}
