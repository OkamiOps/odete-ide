import Foundation

/// Janela de contexto e teto de saída de um modelo, em tokens.
///
/// Serve a quem precisa do tamanho sem montar pedido — a compactação da conversa, por
/// exemplo. O número vem do mesmo lugar que os provedores usam: o que a API do provedor
/// informou (guardado quando a lista de modelos é lida ou o modelo é consultado), e na
/// falta dela o catálogo do models.dev. Nulo é "ninguém sabe": melhor que um chute
/// parecendo certeza.
public enum LimitesDosModelos {
    public static func limites(provider: ProviderKind, model: String) async -> (contexto: Int?, saida: Int?) {
        await limites(provider: provider, model: model, registro: .compartilhado, catalogo: .compartilhado)
    }

    static func limites(
        provider: ProviderKind,
        model: String,
        registro: RegistroDeCapacidades,
        catalogo: CatalogoDeModelos?
    ) async -> (contexto: Int?, saida: Int?) {
        // O modelo do aparelho informa a própria janela em tempo de execução; o teto de
        // saída é o que o AppleProvider pede — único lugar onde a Odete limita a saída.
        if provider == .apple {
            if model == AppleProvider.idNuvem {
                return (AppleProvider.janelaDaNuvem, AppleProvider.respostaDaNuvem)
            }
            return (AppleProvider.janela, AppleProvider.respostaComFerramentas)
        }
        let id = model.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return (nil, nil) }
        var c = registro.ler(provider, id) ?? Capacidades()
        // Espera curta: quem pergunta está no meio de um turno. Sem resposta a tempo, vale
        // o nulo agora e o catálogo já está no aparelho na próxima vez.
        if c.contexto == nil || c.saida == nil,
           let e = await catalogo?.entrada(kind: provider, model: id, esperaMaxima: 5)
        {
            c = c.completada(com: e.capacidades)
        }
        return (c.contexto, c.saida)
    }
}
