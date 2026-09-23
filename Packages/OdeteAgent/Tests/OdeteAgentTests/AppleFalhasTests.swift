import Foundation
import FoundationModels
@testable import OdeteAgent
import OdeteI18n
import Testing

/// O que a conversa mostra quando o modelo da Apple falha.
///
/// No QA, com o provedor da Apple num simulador sem o modelo pronto, o cartão vermelho
/// dizia "The operation couldn't be completed. (FoundationModels.LanguageModelSession.
/// GenerationError error -1.)": texto do sistema, em inglês, sem dizer o que fazer. Estes
/// testes fixam uma frase por caso e que nenhum caminho devolve o texto cru.
struct AppleFalhasTests {
    /// As frases conferidas são as do código, que é o português.
    init() {
        Texto.escolher(.ptBR)
    }

    typealias Falha = LanguageModelSession.GenerationError
    static let contexto = Falha.Context(debugDescription: "teste")

    /// Todos os casos que a SDK publica, com a falha que cada um tem que virar.
    static var casos: [(Falha, FalhaApple)] {
        let c = contexto
        return [
            (.exceededContextWindowSize(c), .janelaEstourada(4096)),
            (.assetsUnavailable(c), .modeloIndisponivel(motivo: nil)),
            (.guardrailViolation(c), .filtroDeSeguranca),
            (.unsupportedGuide(c), .recursoNaoSuportado),
            (.unsupportedLanguageOrLocale(c), .idiomaNaoAtendido),
            (.decodingFailure(c), .respostaIlegivel),
            (.rateLimited(c), .pedidosDemais),
            (.concurrentRequests(c), .pedidoEmAndamento),
            (.refusal(Falha.Refusal(transcriptEntries: []), c), .recusa(explicacao: nil)),
        ]
    }

    /// O que diz à pessoa o que fazer. Toda frase tem pelo menos uma destas.
    static let saidas = ["seletor", "Tente de novo", "tente de novo", "conversa nova", "Ajustes"]

    @Test func cadaCasoDoSDKViraAFalhaCerta() {
        for (erro, esperada) in Self.casos {
            #expect(AppleProvider.falha(erro, motivo: nil, janela: 4096) == esperada, "\(erro)")
        }
    }

    @Test func nenhumaFraseEhOTextoDoSistema() {
        for (erro, _) in Self.casos {
            let frase = AppleProvider.explicarQualquer(erro, motivo: nil)
            #expect(frase != erro.localizedDescription, "devolveu o texto do sistema em \(erro)")
            #expect(!frase.contains("The operation couldn"), "\(erro)")
            if let doSistema = erro.errorDescription, !doSistema.isEmpty {
                #expect(!frase.contains(doSistema), "a descrição em inglês vazou em \(erro)")
            }
            #expect(Self.saidas.contains { frase.contains($0) }, "não diz o que fazer: \(frase)")
        }
    }

    /// Frase repetida entre casos diferentes quer dizer que um deles ficou genérico.
    @Test func cadaCasoTemFrasePropria() {
        let frases = Set(Self.casos.map { AppleProvider.explicarQualquer($0.0, motivo: nil) })
        #expect(frases.count == Self.casos.count)
    }

    /// Com o Apple Intelligence desligado, o que aparece é o motivo real — o mesmo que o
    /// seletor e os Ajustes mostram — e não "os arquivos do modelo não estão disponíveis".
    @Test func modeloIndisponivelDizOMotivoDaDisponibilidade() {
        let motivo = "Ligue o Apple Intelligence em Ajustes › Apple Intelligence e Siri."
        let frase = AppleProvider.explicarQualquer(Falha.assetsUnavailable(Self.contexto), motivo: motivo)
        #expect(frase.hasPrefix(motivo))
        #expect(frase.contains("seletor"))
    }

    /// Sem motivo informado (a disponibilidade diz que dá, mas o modelo não está lá), a
    /// frase ainda aponta onde conferir.
    @Test func modeloIndisponivelSemMotivoApontaOsAjustes() {
        let frase = AppleProvider.explicarQualquer(Falha.assetsUnavailable(Self.contexto), motivo: nil)
        #expect(frase.contains("Ajustes › Apple Intelligence e Siri"))
    }

    @Test func recusaUsaAExplicacaoDoModelo() {
        let recusa = Falha.refusal(Falha.Refusal(transcriptEntries: []), Self.contexto)
        let frase = AppleProvider.falha(recusa, motivo: nil, explicacaoDaRecusa: "Não posso ajudar com isso.").frase
        #expect(frase.contains("Não posso ajudar com isso."))
    }

    @Test func janelaEstouradaUsaONumeroDoModelo() {
        let frase = AppleProvider.falha(Falha.exceededContextWindowSize(Self.contexto), motivo: nil, janela: 8192).frase
        #expect(frase.contains("8192"))
    }

    /// O caso do QA: o erro chega como `NSError` do domínio do framework, sem descrição,
    /// e não converte para o enum. Caía direto em `localizedDescription`.
    @Test func nsErrorDoFrameworkNaoApareceCru() {
        let erro = NSError(domain: "FoundationModels.LanguageModelSession.GenerationError", code: -1)
        #expect(erro.localizedDescription.contains("The operation couldn"), "o cenário do QA mudou")
        #expect(!((erro as Error) is Falha), "o NSError passou a converter para o enum")
        let frase = AppleProvider.explicarQualquer(erro, motivo: nil)
        #expect(frase.contains("(GenerationError -1)"), "\(frase)")
        #expect(!frase.contains("The operation couldn"))
        #expect(frase.contains("seletor"))
    }

    /// Se o modelo deixou de estar disponível, o motivo vale mais que o código.
    @Test func nsErrorComModeloIndisponivelDizOMotivo() {
        let erro = NSError(domain: "FoundationModels.LanguageModelSession.GenerationError", code: -1)
        let motivo = "O modelo ainda está sendo baixado. Tente de novo daqui a pouco."
        #expect(AppleProvider.explicarQualquer(erro, motivo: motivo).hasPrefix(motivo))
    }

    enum ErroDeTeste: Error { case quebrou(Int), parou }
    struct OutroErro: Error {}

    @Test func erroDesconhecidoLevaONomeEntreParenteses() {
        #expect(AppleProvider.rotulo(Falha.rateLimited(Self.contexto)) == "GenerationError.rateLimited")
        #expect(AppleProvider.rotulo(Falha.refusal(Falha.Refusal(transcriptEntries: []), Self.contexto))
            == "GenerationError.refusal")
        #expect(AppleProvider.rotulo(ErroDeTeste.quebrou(3)) == "ErroDeTeste.quebrou")
        #expect(AppleProvider.rotulo(ErroDeTeste.parou) == "ErroDeTeste.parou")
        #expect(AppleProvider.rotulo(OutroErro()).hasPrefix("OutroErro "))
        let frase = AppleProvider.explicarQualquer(ErroDeTeste.quebrou(3), motivo: nil)
        #expect(frase.contains("(ErroDeTeste.quebrou)"))
        #expect(!frase.contains("The operation couldn"))
    }

    /// A explicação da recusa é outra geração do modelo: o cartão não pode esperar por
    /// ela para sempre.
    @Test func explicacaoDaRecusaTemPrazo() async {
        let tarde = await AppleProvider.explicacaoDaRecusa(prazo: .milliseconds(50)) {
            try await Task.sleep(for: .seconds(5))
            return "tarde demais"
        }
        #expect(tarde == nil)
        let pronta = await AppleProvider.explicacaoDaRecusa { "  Não posso ajudar.\n" }
        #expect(pronta == "Não posso ajudar.")
        let vazia = await AppleProvider.explicacaoDaRecusa { "  " }
        #expect(vazia == nil)
        let falhou = await AppleProvider.explicacaoDaRecusa { throw ErroDeTeste.parou }
        #expect(falhou == nil)
    }

    /// De ponta a ponta: com o modelo do aparelho indisponível (o simulador não tem), o
    /// envio nem chega ao framework — a conversa recebe o motivo e o que fazer.
    @Test func enviarSemOModeloProntoDizOMotivoReal() async throws {
        guard let motivo = AppleProvider.impedimento else { return }
        let erro = try await Self.primeiroErro(modelo: AppleProvider.idLocal)
        #expect(erro == FalhaApple.modeloIndisponivel(motivo: motivo).frase)
        #expect(erro.hasPrefix(motivo))
        #expect(erro.contains("seletor"))
    }

    /// A nuvem sem permissão também: o motivo dela, e não um erro de geração.
    @Test func enviarParaANuvemIndisponivelDizOMotivo() async throws {
        guard let motivo = AppleProvider.impedimentoDaNuvem else { return }
        let erro = try await Self.primeiroErro(modelo: AppleProvider.idNuvem)
        #expect(erro.hasPrefix(motivo))
    }

    static func primeiroErro(modelo: String) async throws -> String {
        let turno = TurnRequest(system: "", messages: [.user("oi")], tools: [], model: modelo)
        for try await evento in AppleProvider().stream(turno) {
            if case let .error(texto) = evento {
                return texto
            }
        }
        Issue.record("o envio terminou sem erro")
        return ""
    }

    #if compiler(>=6.4)
        /// O iPadOS 27 troca `GenerationError` por tipos novos; as frases são as mesmas. Só
        /// roda num runtime 27.
        @Test func asFalhasDoIPadOS27TemAsMesmasFrases() {
            guard #available(iOS 27.0, *) else { return }
            #expect(AppleProvider.falhaDoFramework(
                LanguageModelError.contextSizeExceeded(.init(
                    contextSize: 8192,
                    tokenCount: 9000,
                    debugDescription: ""
                )),
                motivo: nil
            ) == .janelaEstourada(8192))
            #expect(AppleProvider.falhaDoFramework(
                LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "")),
                motivo: nil
            ) == .pedidosDemais)
            #expect(AppleProvider.falhaDoFramework(
                LanguageModelError.timeout(.init(debugDescription: "")),
                motivo: nil
            ) == .demorou)
            #expect(AppleProvider.falhaDoFramework(
                SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "")),
                motivo: "motivo"
            ) == .modeloIndisponivel(motivo: "motivo"))
            #expect(AppleProvider.falhaDoFramework(LanguageModelSession.Error.concurrentRequests, motivo: nil)
                == .pedidoEmAndamento)
            #expect(AppleProvider.falhaDoFramework(
                GeneratedContent.ParsingError(rawContent: "{", debugDescription: ""),
                motivo: nil
            ) == .respostaIlegivel)
            #expect(AppleProvider.falhaDoFramework(ErroDeTeste.parou, motivo: nil) == nil)
        }
    #endif
}
