import Foundation
@testable import OdeteAgent
import Testing

/// Falha que passa (limite de uso, servidor fora do ar, conexão que caiu antes da
/// resposta começar) merece outra tentativa. Erro de conta ou pedido malformado, não.
struct RetryTests {
    @Test func insisteEmLimiteEEmErroDeServidor() {
        for code in [429, 500, 502, 503, 504] {
            #expect(pausaAntesDeTentarDeNovo(AgentError.http(code, ""), 1) != nil)
        }
    }

    @Test func naoInsisteEmErroDePedidoOuDeConta() {
        #expect(pausaAntesDeTentarDeNovo(AgentError.http(400, "Unsupported parameter"), 1) == nil)
        #expect(pausaAntesDeTentarDeNovo(AgentError.http(404, "Not Found"), 1) == nil)
        #expect(pausaAntesDeTentarDeNovo(AgentError.auth("401"), 1) == nil)
        #expect(pausaAntesDeTentarDeNovo(AgentError.noAccount, 1) == nil)
    }

    @Test func insisteQuandoAConexaoCai() {
        #expect(pausaAntesDeTentarDeNovo(URLError(.networkConnectionLost), 1) != nil)
        #expect(pausaAntesDeTentarDeNovo(URLError(.timedOut), 1) != nil)
        #expect(pausaAntesDeTentarDeNovo(URLError(.badURL), 1) == nil)
    }

    @Test func aEsperaCresceACadaTentativa() {
        let p1 = pausaAntesDeTentarDeNovo(AgentError.http(429, ""), 1)
        let p2 = pausaAntesDeTentarDeNovo(AgentError.http(429, ""), 2)
        #expect((p1 ?? 0) < (p2 ?? 0))
    }
}
