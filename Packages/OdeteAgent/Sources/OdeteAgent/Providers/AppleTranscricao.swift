import Foundation
import FoundationModels
import OdeteI18n

/// A conversa como transcrição, e não como texto corrido.
///
/// É aqui que estava a causa de o modelo local escrever *sobre* editar em vez de editar.
///
/// O histórico ia achatado num prompt único: a chamada da rodada anterior aparecia como a
/// frase `Odete pediu read_file: {"path":"src/style.css"}` e a resposta da ferramenta como
/// `Resultado de ferramenta: …`. Para o modelo, aquilo era uma conversa em que chamada de
/// ferramenta é **prosa**. Modelo pequeno é guiado por formato: mostrando prosa, ele
/// devolve prosa — foi assim que "deixa o botão azul" virou um bloco de CSS no chat com
/// "Nada foi alterado" logo abaixo. Ele estava imitando o que via.
///
/// Com `Transcript` cada chamada volta a ser uma chamada e cada resultado um resultado,
/// nos mesmos tipos que o framework usa quando executa a ferramenta por conta própria. É a
/// diferença entre mostrar ao modelo uma transcrição e mostrar uma redação sobre ela.
@available(iOS 26.0, *)
enum TranscricaoApple {
    /// A transcrição da conversa e o que perguntar agora.
    ///
    /// A última fala não entra na transcrição: ela é o prompt da vez. Quando a conversa
    /// termina em resultado de ferramenta — que é o caso mais comum no meio de um
    /// trabalho — não há fala nova, e o prompt vira uma linha de "siga daqui", porque o
    /// framework exige um.
    static func montar(
        _ mensagens: [AgentMessage],
        instrucoes: String,
        ferramentas: [any Tool],
        orcamento: Int
    ) -> (transcricao: Transcript, prompt: String) {
        let cabendo = cortando(mensagens, orcamento: orcamento)
        var entradas: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instrucoes))],
                toolDefinitions: ferramentas.map { Transcript.ToolDefinition(tool: $0) }
            )),
        ]
        var corpo = cabendo
        if corpo.last?.role == .user {
            corpo.removeLast()
        }
        // O pedido da vez é a **última** fala da pessoa, não a primeira: quem manda "agora
        // deixa o título maior" no meio da conversa mudou de assunto. E o estado — leu,
        // editou — é o que aconteceu depois dela, senão um trabalho terminado antes faria
        // o pedido novo já nascer "pronto".
        let ultima = cabendo.lastIndex { $0.role == .user }
        let prompt = ordem(
            pedido: ultima.map { cabendo[$0].content } ?? "",
            feito: ultima.map { Array(cabendo.suffix(from: $0 + 1)) } ?? cabendo
        )
        for m in corpo {
            entradas.append(contentsOf: entrada(m, entre: corpo))
        }
        return (Transcript(entries: entradas), prompt)
    }

    /// A ordem da vez, conforme o que já foi feito.
    ///
    /// Medido na bancada, com o modelo do sistema rodando de verdade: dado só o objetivo
    /// — "preciso trocar a cor do botão para azul" — ele responde com conselho de CSS e
    /// não chama ferramenta nenhuma. Dado o mesmo objetivo com uma primeira ordem
    /// concreta junto — "chame read_file no arquivo que precisa mudar" — ele chama. Esse
    /// modelo atende pedido que mapeia numa ferramenta e não decompõe objetivo em passos;
    /// decompor é trabalho do harness, não dele.
    ///
    /// E a ordem muda com o estado, senão vira laço: mandar "aplique com str_replace"
    /// depois de aplicado é pedir para aplicar de novo — foi exatamente o que a bancada
    /// mostrou, vinte chamadas seguidas editando o mesmo arquivo.
    static func ordem(pedido: String, feito: [AgentMessage]) -> String {
        guard !pedido.isEmpty else { return tr("Siga a partir do resultado acima.") }
        var leu = false, editou = false, errouOTrecho = false
        for m in feito where m.role == .tool {
            if m.content.hasPrefix("escrito ") {
                editou = true
                errouOTrecho = false
            } else if m.content.hasPrefix("trecho não encontrado") {
                errouOTrecho = true
            } else if !m.content.isEmpty {
                leu = true
                errouOTrecho = false
            }
        }
        // Errar o trecho e mandar "aplique de novo" é pedir o mesmo palpite outra vez —
        // medido na bancada: dez, vinte chamadas do mesmo str_replace que não casa. Quem
        // errou o texto precisa do texto, não de mais uma ordem para aplicar.
        if errouOTrecho {
            return tr(
                "Pedido: %1$@\n\nO trecho não foi encontrado no arquivo. Chame read_file de novo e copie daí o texto exato antes de tentar outra vez.",
                pedido
            )
        }
        if editou {
            return tr(
                "Pedido: %1$@\n\nA mudança já foi aplicada no arquivo. Diga em uma frase o que mudou e pare. Não chame mais ferramentas.",
                pedido
            )
        }
        if leu {
            return tr(
                "Pedido: %1$@\n\nAgora aplique a mudança chamando str_replace, com old copiado exatamente do que você leu. Não explique antes de chamar.",
                pedido
            )
        }
        return tr(
            "%1$@\n\nPrimeiro passo: chame read_file no arquivo que precisa mudar, ou list_dir se não souber qual. Não explique antes de chamar.",
            pedido
        )
    }

    static func entrada(_ m: AgentMessage, entre todas: [AgentMessage]) -> [Transcript.Entry] {
        switch m.role {
        case .user:
            return [.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: m.content))]))]
        case .assistant:
            var saida: [Transcript.Entry] = []
            if !m.content.isEmpty {
                saida.append(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(content: m.content))]
                )))
            }
            if let chamadas = m.toolCalls, !chamadas.isEmpty {
                saida.append(.toolCalls(Transcript.ToolCalls(chamadas.map {
                    Transcript.ToolCall(
                        id: $0.id,
                        toolName: $0.name,
                        arguments: (try? GeneratedContent(json: $0.arguments)) ?? GeneratedContent($0.arguments)
                    )
                })))
            }
            return saida
        case .tool:
            // O resultado precisa dizer de qual ferramenta veio, e a mensagem só guarda o
            // id da chamada — o nome está na chamada que a pediu.
            let id = m.toolCallId ?? UUID().uuidString
            let nome = todas
                .compactMap(\.toolCalls)
                .flatMap(\.self)
                .first { $0.id == id }?
                .name ?? "tool"
            return [.toolOutput(Transcript.ToolOutput(
                id: id,
                toolName: nome,
                segments: [.text(Transcript.TextSegment(content: m.content))]
            ))]
        case .system:
            return []
        }
    }

    /// Corta a conversa até caber, **sem nunca tirar o pedido**.
    ///
    /// Cortar pela frente parecia óbvio: o começo é o mais velho. Só que o começo é o
    /// enunciado. Depois de umas rodadas de arquivo lido — e arquivo lido é grande — a
    /// primeira fala, "troca a cor do botão para azul", era a primeira a sair, e o que
    /// sobrava era uma pilha de conteúdo e um "siga daqui". O agente não estava teimoso:
    /// ele tinha perdido o enunciado e ficava relendo o projeto procurando o que fazer.
    ///
    /// Então o pedido fica preso no lugar e quem encolhe é o meio. E o corte continua
    /// nunca separando uma chamada do resultado dela: transcrição com resultado órfão é
    /// pior que transcrição curta, porque o modelo vê a resposta de uma ferramenta que,
    /// para ele, nunca foi chamada.
    static func cortando(_ mensagens: [AgentMessage], orcamento: Int) -> [AgentMessage] {
        guard tamanho(mensagens) > orcamento else { return mensagens }
        guard let pedido = mensagens.first(where: { $0.role == .user }) else {
            return []
        }
        var resto = Array(mensagens.drop { $0.role != .user }.dropFirst())
        let fixo = tamanho([pedido])
        while tamanho(resto) + fixo > orcamento, !resto.isEmpty {
            resto.removeFirst()
            while let primeira = resto.first, primeira.role == .tool {
                resto.removeFirst()
            }
        }
        return [pedido] + resto
    }

    static func tamanho(_ mensagens: [AgentMessage]) -> Int {
        mensagens.reduce(0) { total, m in
            total + m.content.count + (m.toolCalls ?? []).reduce(0) { $0 + $1.name.count + $1.arguments.count }
        }
    }
}
