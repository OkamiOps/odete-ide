import Foundation
@testable import OdeteAgent
import OdeteI18n
import Testing

/// Os dois níveis do modelo da Apple: o que roda no aparelho e o da nuvem privada.
///
/// Disponibilidade depende do aparelho e do Apple Intelligence estar ligado, então nada
/// aqui pode exigir que ele exista — o simulador não tem. O que dá para fixar é a forma:
/// o local sempre aparece, a nuvem só quando disponível, e o orçamento de cada um.
struct AppleProviderTests {
    @Test func oModeloLocalSempreAparece() async throws {
        let modelos = try await AppleProvider().models()
        #expect(modelos.contains { $0.id == AppleProvider.idLocal }, "o modelo do aparelho sumiu da lista")
        #expect(modelos.first?.ctx ?? 0 > 0, "a janela do modelo local veio zerada")
    }

    /// A nuvem aparece sempre — o que muda é se dá para escolher.
    ///
    /// Escondendo a linha quando o aparelho ainda não tem o modelo, quem está no iPadOS 27
    /// não descobre que existe: some sem explicação e parece que a Odete só roda o modelo
    /// pequeno. Aparecendo com o motivo ao lado, a pessoa sabe o que falta.
    @Test func aNuvemApareceSempre() async throws {
        let modelos = try await AppleProvider().models()
        let nuvem = try #require(
            modelos.first { $0.id == AppleProvider.idNuvem },
            "a nuvem sumiu da lista: quem não vê não sabe que existe"
        )
        #expect(
            (nuvem.indisponivel == nil) == AppleProvider.nuvemDisponivel,
            "a linha e a disponibilidade discordam"
        )
    }

    /// Sem a permissão da Apple, a nuvem não pode ser oferecida de jeito nenhum.
    ///
    /// Não é preferência de interface: `PrivateCloudComputeLanguageModel` derruba o
    /// processo — `fatalError` dentro do framework, que nenhum `catch` pega — quando o
    /// app não tem `com.apple.developer.private-cloud-compute`. Deixar `nuvemDisponivel`
    /// dizer sim sem a permissão é entregar um app que fecha sozinho quando a pessoa
    /// escolhe o modelo. Este teste é o que impede isso de voltar.
    @Test func semPermissaoANuvemNaoEhOferecida() {
        guard !AppleProvider.temPermissaoDaNuvem else { return }
        #expect(!AppleProvider.nuvemDisponivel, "ofereceu a nuvem sem a permissão: isso derruba o app")
        #expect(AppleProvider.impedimentoDaNuvem?.isEmpty == false, "recusou e não disse por quê")
    }

    /// Quando não dá, tem que dizer por quê — e não só sumir da lista.
    @Test func aNuvemIndisponivelExplicaOMotivo() {
        if AppleProvider.nuvemDisponivel {
            #expect(AppleProvider.impedimentoDaNuvem == nil)
        } else {
            #expect(AppleProvider.impedimentoDaNuvem?.isEmpty == false, "ficou indisponível e calada")
        }
    }

    /// A nuvem tem janela maior: o corte do histórico precisa acompanhar, senão o modelo
    /// grande recebe a mesma conversinha do modelo pequeno.
    @Test func oOrcamentoDaNuvemEhMaior() {
        #expect(AppleProvider.janelaDaNuvem > AppleProvider.orcamentoDeEntrada)
        let longa = (1 ... 60).map { AgentMessage.user("mensagem número \($0) " + String(repeating: "x", count: 300)) }
        let local = TranscricaoApple.cortando(longa, orcamento: AppleProvider.orcamentoDeEntrada)
        let nuvem = TranscricaoApple.cortando(longa, orcamento: AppleProvider.janelaDaNuvem)
        #expect(nuvem.count > local.count, "a nuvem recebeu o mesmo pedaço que o modelo local")
        #expect(TranscricaoApple.tamanho(local) <= AppleProvider.orcamentoDeEntrada)
        #expect(TranscricaoApple.tamanho(nuvem) <= AppleProvider.janelaDaNuvem)
    }

    /// O número que mais envelhece: quando a Apple troca o modelo por um de janela maior,
    /// `contextSize` cresce sozinho e o orçamento tem que crescer junto. Estava fixo em
    /// 8000 caracteres e ficaria fixo para sempre.
    @Test func oOrcamentoAcompanhaAJanelaDoAparelho() {
        let janela = AppleProvider.janela
        #expect(janela >= 4096, "a janela informada pelo aparelho veio menor que o mínimo documentado")
        // Sobra para a entrada tudo menos a resposta, convertido em caracteres.
        #expect(
            AppleProvider.orcamentoDeEntrada > janela,
            "o orçamento em caracteres ficou menor que a janela em fichas"
        )
        #expect(
            AppleProvider.orcamentoDeEntrada < janela * 4,
            "o orçamento passou de três caracteres e meio por ficha e vai estourar a janela"
        )
        #expect(AppleProvider.respostaMaxima < janela, "a resposta sozinha não pode ocupar a janela toda")
    }

    /// O histórico cortado guarda o fim da conversa, que é a parte que importa.
    @Test func oCorteGuardaOFimDaConversa() {
        let msgs = (1 ... 40).map { AgentMessage.user("linha \($0) " + String(repeating: "y", count: 400)) }
        let ficaram = TranscricaoApple.cortando(msgs, orcamento: AppleProvider.orcamentoDeEntrada)
        #expect(ficaram.last?.content.hasPrefix("linha 40") == true, "cortou a mensagem mais recente")
        // O enunciado fica preso — ver `TranscricaoApple.cortando` — e quem encolhe é o
        // meio: some a linha 2, nunca a 1 nem a 40.
        #expect(ficaram.first?.content.hasPrefix("linha 1 ") == true, "o corte levou o pedido junto")
        #expect(!ficaram.contains { $0.content.hasPrefix("linha 2 ") }, "não cortou nada do meio")
    }
}
