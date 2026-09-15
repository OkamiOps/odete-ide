import OdeteAgent
@testable import OdeteApp
import Testing

/// Quando o cartão vermelho do agente oferece "Tentar de novo".
struct RetomadaTests {
    @Test func erroDoProvedorDaParaRepetir() {
        #expect(AgentModel.ehErroQueDaParaRepetir(.error(id: "1", text: "HTTP 404: chatgpt.com")))
    }

    @Test func pararNaoEErro() {
        #expect(!AgentModel.ehErroQueDaParaRepetir(.error(id: "1", text: "parado")))
    }

    @Test func respostaNoFimNaoOferece() {
        #expect(!AgentModel.ehErroQueDaParaRepetir(.assistant(id: "1", text: "pronto")))
        #expect(!AgentModel.ehErroQueDaParaRepetir(nil))
    }

    /// O texto cru do provedor não diz o que fazer; a dica diz.
    @Test func dicaTraduzOsErrosComuns() {
        #expect(ChatRow.dica("HTTP 404: chatgpt.com {\"detail\":\"Not Found\"}")?.contains("modelo") == true)
        #expect(ChatRow.dica("HTTP 400: Unsupported parameter: max_output_tokens") != nil)
        #expect(ChatRow.dica("HTTP 429: rate limit")?.contains("Limite") == true)
        #expect(ChatRow.dica("deu ruim") == nil)
    }
}
