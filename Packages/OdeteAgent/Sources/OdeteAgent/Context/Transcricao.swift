import Foundation
import OdeteI18n

/// A conversa que vai para o provedor tem que fechar: toda chamada de ferramenta com o
/// seu resultado, e nenhum resultado sem a chamada que o pediu.
///
/// Uma conversa que termina numa chamada sem resultado recebe 400 de todo provedor — e
/// como o histórico é regravado assim, toda mensagem seguinte recebia o mesmo 400. Três
/// caminhos chegavam lá: o freio de repetição, que desistia com um `return` antes de
/// gravar os resultados que faltavam; o corte `suffix(40)` do `ChatStore`, que podia
/// começar a conversa guardada num resultado cuja chamada ficou do lado de fora; e
/// conversas antigas, gravadas quebradas por versões anteriores. Consertar antes de cada
/// envio cobre os três e o que vier.
public enum Transcricao {
    /// O resultado posto no lugar de um que não existe.
    static var semResultado: String {
        tr("cancelado: esta chamada ficou sem resultado")
    }

    /// A conversa com os pares fechados.
    ///
    /// - Resultado cuja chamada não está logo antes (na mesma rodada) sai: é órfão.
    /// - Chamada sem resultado ganha um, logo depois dos resultados que a rodada tem.
    ///
    /// Numa conversa que já fecha, devolve a mesma sequência, sem tocar em nada — o que
    /// importa para quem compara o histórico mensagem a mensagem (cache do provedor e o
    /// raciocínio preservado dos modelos da Anthropic).
    public static func consertar(_ mensagens: [AgentMessage]) -> [AgentMessage] {
        guard !fecha(mensagens) else { return mensagens }
        var out: [AgentMessage] = []
        out.reserveCapacity(mensagens.count + 2)
        var abertas: [String] = []
        func fechar() {
            for id in abertas {
                out.append(.tool(id, semResultado))
            }
            abertas = []
        }
        for m in mensagens {
            switch m.role {
            case .tool:
                guard let id = m.toolCallId, let i = abertas.firstIndex(of: id) else { continue }
                abertas.remove(at: i)
                out.append(m)
            case .assistant:
                fechar()
                out.append(m)
                abertas = (m.toolCalls ?? []).map(\.id)
            case .user, .system:
                fechar()
                out.append(m)
            }
        }
        fechar()
        // Acrescentar resultados no fim é o fluxo normal. Tirar ou pôr alguma coisa no meio
        // edita a conversa, e os blocos de raciocínio que vieram depois ficam inválidos para
        // os modelos que os amarram ao histórico — ver `Compactacao.semRaciocinio`.
        return out.starts(with: mensagens) ? out : Compactacao.semRaciocinio(out)
    }

    /// A conversa já fecha? A mesma leitura de `consertar`, sem montar nada.
    public static func fecha(_ mensagens: [AgentMessage]) -> Bool {
        var abertas: [String] = []
        for m in mensagens {
            switch m.role {
            case .tool:
                guard let id = m.toolCallId, let i = abertas.firstIndex(of: id) else { return false }
                abertas.remove(at: i)
            case .assistant:
                guard abertas.isEmpty else { return false }
                abertas = (m.toolCalls ?? []).map(\.id)
            case .user, .system:
                guard abertas.isEmpty else { return false }
            }
        }
        return abertas.isEmpty
    }

    /// Corta o começo de uma conversa grande sem deixar ninguém pela metade.
    ///
    /// O `suffix(40)` do `ChatStore` cortava em qualquer lugar: a conversa reaberta podia
    /// começar num resultado de ferramenta sem a chamada. Aqui o corte cai no começo de uma
    /// mensagem da pessoa — ou, num turno tão longo que não tem nenhuma, no começo de uma
    /// rodada do agente — e o resumo de uma compactação, se houver, fica.
    public static func aparar(_ mensagens: [AgentMessage], maximo: Int) -> [AgentMessage] {
        guard mensagens.count > maximo else { return mensagens }
        let resumo = mensagens.first.flatMap { Compactacao.ehResumo($0) ? $0 : nil }
        let desde = mensagens.count - maximo
        let candidatos = mensagens.indices.filter { $0 >= desde }
        guard let corte = candidatos.first(where: { mensagens[$0].role == .user })
            ?? candidatos.first(where: { mensagens[$0].role == .assistant })
        else {
            return resumo.map { [$0] } ?? []
        }
        // Tirar o começo muda o prefixo de todo raciocínio que fica, como uma compactação:
        // ele sai junto, uma vez, aqui na fronteira.
        let resto = Compactacao.semRaciocinio(Array(mensagens[corte...]))
        guard let resumo, !(resto.first.map(Compactacao.ehResumo) ?? false) else { return resto }
        return [resumo] + resto
    }
}
