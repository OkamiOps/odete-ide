import OdeteAgent
@testable import OdeteApp
import OdeteI18n
import Testing

/// Quando o cartão vermelho do agente oferece "Tentar de novo".
struct RetomadaTests {
    /// Os testes conferem a frase exata que está no código, que é o português. Sem
    /// travar o idioma, o mesmo teste passa no Mac e falha no simulador em inglês.
    init() {
        Texto.escolher(.ptBR)
    }

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

    /// Com o Apple Intelligence desligado, repetir manda o mesmo pedido para o mesmo
    /// modelo que não existe no aparelho: o cartão oferece trocar de modelo no lugar.
    @Test func modeloIndisponivelTrocaORepetirPorTrocarDeModelo() {
        let erro = ChatItem.error(id: "1", text: "Ligue o Apple Intelligence em Ajustes › Apple Intelligence e Siri.")
        let motivo = "Ligue o Apple Intelligence em Ajustes › Apple Intelligence e Siri."
        #expect(!AgentModel.ehErroQueDaParaRepetir(erro, modeloIndisponivel: motivo))
        #expect(AgentModel.ofereceTrocarDeModelo(erro, modeloIndisponivel: motivo))
        // Com o modelo de volta, volta o "Tentar de novo".
        #expect(AgentModel.ehErroQueDaParaRepetir(erro, modeloIndisponivel: nil))
        #expect(!AgentModel.ofereceTrocarDeModelo(erro, modeloIndisponivel: nil))
    }

    /// Parar e desfazer continuam sem botão nenhum, mesmo com o modelo indisponível.
    @Test func pararNaoOfereceTrocarDeModelo() {
        #expect(!AgentModel.ofereceTrocarDeModelo(.error(id: "1", text: "parado"), modeloIndisponivel: "x"))
        #expect(!AgentModel.ofereceTrocarDeModelo(
            .error(id: AgentModel.prefixoDoDesfazer + "1", text: "desfeito"),
            modeloIndisponivel: "x"
        ))
        #expect(!AgentModel.ofereceTrocarDeModelo(nil, modeloIndisponivel: "x"))
    }

    /// As frases novas da Apple não podem ganhar a dica de HTTP por acaso.
    @Test func falhaDaAppleNaoGanhaDicaDeHTTP() {
        let frase = "O modelo da Apple falhou (GenerationError -1). Tente de novo ou escolha outro modelo no seletor."
        #expect(ChatRow.dica(frase) == nil)
    }

    /// O texto cru do provedor não diz o que fazer; a dica diz.
    @Test func dicaTraduzOsErrosComuns() {
        #expect(ChatRow.dica("HTTP 404: chatgpt.com {\"detail\":\"Not Found\"}")?.contains("modelo") == true)
        #expect(ChatRow.dica("HTTP 400: Unsupported parameter: max_output_tokens") != nil)
        #expect(ChatRow.dica("HTTP 429: rate limit")?.contains("Limite") == true)
        #expect(ChatRow.dica("deu ruim") == nil)
    }
}
