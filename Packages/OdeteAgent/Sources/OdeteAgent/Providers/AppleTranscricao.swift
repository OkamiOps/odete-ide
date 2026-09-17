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
        var prompt = tr("Siga a partir do resultado acima.")
        var corpo = cabendo
        // A última fala da pessoa é a pergunta da vez; o resto é transcrição.
        if corpo.last?.role == .user {
            prompt = corpo.removeLast().content
        }
        for m in corpo {
            entradas.append(contentsOf: entrada(m, entre: corpo))
        }
        return (Transcript(entries: entradas), prompt)
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

    /// Corta o começo da conversa até caber, sem separar uma chamada do resultado dela.
    ///
    /// Transcrição com resultado órfão é pior que transcrição curta: o modelo vê a
    /// resposta de uma ferramenta que, para ele, nunca foi chamada.
    static func cortando(_ mensagens: [AgentMessage], orcamento: Int) -> [AgentMessage] {
        var fim = mensagens
        while tamanho(fim) > orcamento, !fim.isEmpty {
            fim.removeFirst()
            while let primeira = fim.first, primeira.role == .tool {
                fim.removeFirst()
            }
        }
        return fim
    }

    static func tamanho(_ mensagens: [AgentMessage]) -> Int {
        mensagens.reduce(0) { total, m in
            total + m.content.count + (m.toolCalls ?? []).reduce(0) { $0 + $1.name.count + $1.arguments.count }
        }
    }
}
