import Foundation
import OdeteI18n
import Synchronization

// MARK: - Comum aos três formatos

/// O que o leitor do stream precisa saber além das linhas.
struct ContextoDoFluxo: Sendable {
    /// `provedor@host`, gravado junto do raciocínio para ele só voltar ao mesmo lugar.
    var origem = ""
    var modelo = ""
    /// As ferramentas do pedido, para conferir os argumentos obrigatórios.
    var ferramentas: [ToolSpec] = []
    /// Blocos de uma resposta pausada (Anthropic), que entram na frente do raciocínio.
    var prefixoJSON: String?
    /// Onde o leitor anota como a resposta terminou, para quem abriu o pedido decidir.
    var fim: FimDoFluxo?

    var prefixo: [[String: Any]] {
        guard let prefixoJSON else { return [] }
        return (try? JSONSerialization.jsonObject(with: Data(prefixoJSON.utf8)) as? [[String: Any]]) ?? []
    }
}

/// Como a resposta terminou, anotado pelo leitor do stream.
final class FimDoFluxo: Sendable {
    struct Estado: Sendable {
        var parada: String?
        var modelo: String?
        /// Tipo do evento de erro no meio do stream (`overloaded_error`, …).
        var tipoDoErro: String?
        /// Blocos de uma resposta com `pause_turn`, em JSON.
        var pausado: String?
    }

    private let estado = Mutex(Estado())

    func anotar(_ f: (inout Estado) -> Void) {
        estado.withLock { f(&$0) }
    }

    var atual: Estado {
        estado.withLock { $0 }
    }
}

/// OpenAI Chat Completions com SSE: provedores compatíveis com a OpenAI.
///
/// Sem `max_tokens` e sem `temperature`: modelo na nuvem escreve até o limite dele, e
/// os modelos de raciocínio recusam temperatura diferente de 1.
enum ChatCompletionsStream {
    struct Opcoes {
        var esforcos = Familia.openai.esforcosMaisNovos
        var recusados: Set<String> = []
        /// Onde o provedor quer o raciocínio de volta (`reasoning_content`), se quiser.
        var campoDoRaciocinio: String?

        init() {}

        init(_ c: Capacidades, kind: ProviderKind) {
            esforcos = c.esforcos ?? Familia(kind).esforcosMaisNovos
            recusados = Set(c.recusados ?? [])
            campoDoRaciocinio = c.campoDoRaciocinio
        }
    }

    static func body(_ t: TurnRequest, _ o: Opcoes = Opcoes()) -> MessagesStream.Montado {
        var m = PedidoMandado()
        var b: [String: Any] = [
            "model": t.model,
            "messages": messages(t, o, &m),
            "stream": true,
        ]
        if !o.recusados.contains("stream_options") {
            b["stream_options"] = ["include_usage": true]; m.campos.insert("stream_options")
        }
        if let e = Effort.nivel(t.effort, aceitos: o.esforcos) {
            b["reasoning_effort"] = e; m.nivel = e
        }
        if !t.tools.isEmpty {
            b["tools"] = t.tools.map { [
                "type": "function",
                "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters],
            ] }
            b["tool_choice"] = "auto"
        }
        return MessagesStream.Montado(corpo: b, mandado: m, betas: [])
    }

    static func messages(_ t: TurnRequest, _ o: Opcoes, _ mandado: inout PedidoMandado) -> [[String: Any]] {
        // O raciocínio volta só no campo de texto que o provedor declarou; um formato
        // estruturado (`reasoning_details`) teria que voltar como chegou, e não é guardado.
        let campo = o.campoDoRaciocinio.flatMap { $0 == "reasoning_content" && !o.recusados.contains($0) ? $0 : nil }
        var out: [[String: Any]] = [["role": "system", "content": t.system]]
        for m in t.messages {
            switch m.role {
            case .system: continue
            case .tool: out.append(["role": "tool", "tool_call_id": m.toolCallId ?? "", "content": m.content])
            case .assistant:
                var d: [String: Any] = ["role": "assistant", "content": m.content]
                if let tc = m.toolCalls, !tc.isEmpty {
                    d["tool_calls"] = tc.map { [
                        "id": $0.id,
                        "type": "function",
                        "function": ["name": $0.name, "arguments": $0.arguments],
                    ] }
                    // DeepSeek e parecidos recusam a rodada seguinte de ferramentas sem
                    // o raciocínio da anterior.
                    if let campo, let th = m.thinking, !th.isEmpty {
                        d[campo] = th; mandado.campos.insert(campo)
                    }
                }
                out.append(d)
            case .user:
                if let imgs = m.images, !imgs.isEmpty {
                    var parts: [[String: Any]] = [["type": "text", "text": m.content.isEmpty ? " " : m.content]]
                    parts += imgs
                        .map { ["type": "image_url", "image_url": ["url": "data:\($0.mime);base64,\($0.data)"]] }
                    out.append(["role": "user", "content": parts])
                } else {
                    out.append(["role": "user", "content": m.content])
                }
            }
        }
        return out
    }

    /// Converte as linhas `data:` em eventos.
    static func events(
        _ lines: AsyncThrowingStream<String, Error>,
        _ ctx: ContextoDoFluxo = ContextoDoFluxo()
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                var acc = SSE.ToolAcc()
                var parada: String?
                var viuFim = false
                do {
                    for try await line in lines {
                        if line == "[DONE]" {
                            viuFim = true
                            break
                        }
                        let j = jsonObject(Data(line.utf8))
                        if j.isEmpty {
                            continue
                        }
                        if let e = j["error"] as? [String: Any],
                           let msg = e["message"] as? String
                        {
                            cont.yield(.error(msg)); cont.finish(); return
                        }
                        if let u = TokenUse.pick(j) {
                            cont.yield(.usage(u))
                        }
                        guard let choice = (j["choices"] as? [[String: Any]])?.first else { continue }
                        if let f = choice["finish_reason"] as? String, !f.isEmpty {
                            parada = f
                        }
                        guard let delta = choice["delta"] as? [String: Any] else { continue }
                        if let rc = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String),
                           !rc.isEmpty
                        {
                            cont.yield(.think(rc))
                        }
                        if let c = delta["content"] as? String, !c.isEmpty {
                            cont.yield(.text(c))
                        }
                        for tc in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                            let f = tc["function"] as? [String: Any]
                            acc.add(
                                (tc["index"] as? Int) ?? 0,
                                id: tc["id"] as? String,
                                name: f?["name"] as? String,
                                args: f?["arguments"] as? String
                            )
                        }
                    }
                    if !viuFim, parada == nil {
                        cont.yield(.error(Cortes.conexaoCaiu)); cont.finish(); return
                    }
                    if parada == "content_filter" {
                        cont.yield(.error(Cortes.filtro)); cont.finish(); return
                    }
                    let cortado = parada == "length"
                    // Aqui não há aviso de chamada terminada: a cortada é a que não fecha
                    // o JSON.
                    let calls = acc.calls(ferramentas: ctx.ferramentas, cortado: cortado, sabeQuemFechou: false)
                    if !calls.isEmpty {
                        cont.yield(.tools(calls))
                    } else if cortado {
                        cont.yield(.error(Cortes.respostaCortada)); cont.finish(); return
                    }
                    cont.yield(.done)
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}

/// OpenAI Responses com SSE: Codex (conta ChatGPT) e Grok (proxy do Grok CLI).
///
/// Sem `max_output_tokens`: quem manda no tamanho da resposta é o modelo. O raciocínio
/// vem criptografado (`include: ["reasoning.encrypted_content"]`, com `store: false`) e
/// volta intacto na rodada seguinte, que é como o modelo continua de onde parou em vez
/// de repensar tudo a cada chamada de ferramenta.
enum ResponsesStream {
    struct Opcoes {
        var esforcos = Familia.openai.esforcosMaisNovos
        var recusados: Set<String> = []
        var origem = ""
        var semRaciocinio = false

        init() {}

        init(_ c: Capacidades, kind: ProviderKind, host: String) {
            esforcos = c.esforcos ?? Familia(kind).esforcosMaisNovos
            recusados = Set(c.recusados ?? [])
            origem = "\(kind.rawValue)@\(host)"
        }
    }

    static func body(_ t: TurnRequest, _ o: Opcoes = Opcoes()) -> MessagesStream.Montado {
        var m = PedidoMandado()
        var b: [String: Any] = [
            "model": t.model,
            "stream": true,
            "instructions": t.system,
            "input": input(t, o),
            "store": false,
        ]
        if let e = Effort.nivel(t.effort, aceitos: o.esforcos) {
            var r: [String: Any] = ["effort": e]
            if !o.recusados.contains("summary") {
                r["summary"] = "auto"; m.campos.insert("summary")
            }
            b["reasoning"] = r
            m.nivel = e
        }
        if !o.recusados.contains("include") {
            b["include"] = ["reasoning.encrypted_content"]; m.campos.insert("include")
        }
        if !t.tools.isEmpty {
            b["tools"] = t.tools.map { [
                "type": "function",
                "name": $0.name,
                "description": $0.description,
                "parameters": $0.parameters,
            ] }
            b["tool_choice"] = "auto"
        }
        return MessagesStream.Montado(corpo: b, mandado: m, betas: [])
    }

    static func input(_ t: TurnRequest, _ o: Opcoes = Opcoes()) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in t.messages {
            switch m.role {
            case .system: continue
            case .user:
                var parts: [[String: Any]] = [["type": "input_text", "text": m.content.isEmpty ? " " : m.content]]
                for i in m.images ?? [] {
                    parts.append([
                        "type": "input_image",
                        "image_url": "data:\(i.mime);base64,\(i.data)",
                    ])
                }
                out.append(["role": "user", "content": parts])
            case .assistant:
                // O raciocínio criptografado volta antes do que ele produziu, só para o
                // mesmo lugar e o mesmo modelo.
                if !o.semRaciocinio, let r = m.raciocinio, r.formato == "responses", r.origem == o.origem,
                   r.modelo == t.model
                {
                    out += r.itens
                }
                if !m.content.isEmpty {
                    out.append([
                        "role": "assistant",
                        "content": [["type": "output_text", "text": m.content]],
                    ])
                }
                for c in m.toolCalls ?? [] {
                    out.append([
                        "type": "function_call",
                        "call_id": c.id,
                        "name": c.name,
                        "arguments": c.arguments,
                    ])
                }
            case .tool:
                out.append(["type": "function_call_output", "call_id": m.toolCallId ?? "", "output": m.content])
            }
        }
        return out
    }

    static func events(
        _ lines: AsyncThrowingStream<String, Error>,
        _ ctx: ContextoDoFluxo = ContextoDoFluxo()
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                var acc = SSE.ToolAcc()
                var itemIndex: [String: Int] = [:] // item_id → índice
                var raciocinios: [[String: Any]] = []
                var modelo = ctx.modelo
                var status: String?
                var motivo: String?
                var viuFim = false
                do {
                    for try await line in lines {
                        if line == "[DONE]" {
                            viuFim = true
                            break
                        }
                        let j = jsonObject(Data(line.utf8))
                        guard let type = j["type"] as? String else { continue }
                        if let m = (j["response"] as? [String: Any])?["model"] as? String, !m.isEmpty {
                            modelo = m
                        }
                        switch type {
                        case "response.output_text.delta": if let d = j["delta"] as? String,
                                                              !d.isEmpty
                            {
                                cont.yield(.text(d))
                            }
                        case "response.reasoning_summary_text.delta",
                             "response.reasoning_text.delta": if let d = j["delta"] as? String,
                                                            !d.isEmpty
                            {
                                cont.yield(.think(d))
                            }
                        case "response.output_item.added":
                            if let item = j["item"] as? [String: Any], item["type"] as? String == "function_call" {
                                let i = (j["output_index"] as? Int) ?? acc.items.count
                                itemIndex[(item["id"] as? String) ?? ""] = i
                                acc.add(
                                    i,
                                    id: item["call_id"] as? String,
                                    name: item["name"] as? String,
                                    args: item["arguments"] as? String
                                )
                            }
                        case "response.function_call_arguments.delta":
                            let i = itemIndex[(j["item_id"] as? String) ?? ""] ?? (j["output_index"] as? Int) ?? 0
                            acc.add(i, args: j["delta"] as? String)
                        case "response.output_item.done":
                            guard let item = j["item"] as? [String: Any] else { break }
                            if item["type"] as? String == "function_call",
                               let i = itemIndex[(item["id"] as? String) ?? ""] ?? (j["output_index"] as? Int)
                            {
                                // argumentos completos vencem o acumulado
                                if let a = item["arguments"] as? String, !a.isEmpty {
                                    acc.items[i] = (
                                        acc.items[i]?.id ?? (item["call_id"] as? String) ?? "",
                                        acc.items[i]?.name ?? (item["name"] as? String) ?? "",
                                        a
                                    )
                                }
                                acc.fechar(i)
                            } else if item["type"] as? String == "reasoning", item["encrypted_content"] is String {
                                // Sem o conteúdo criptografado o item não serve para voltar:
                                // com `store: false` o servidor não acha pelo id.
                                raciocinios.append(item)
                            }
                        case "response.completed", "response.done", "response.incomplete":
                            if let u = TokenUse.pick(j) {
                                cont.yield(.usage(u))
                            }
                            let r = j["response"] as? [String: Any]
                            status = (r?["status"] as? String) ??
                                (type == "response.incomplete" ? "incomplete" : "completed")
                            motivo = (r?["incomplete_details"] as? [String: Any])?["reason"] as? String
                            viuFim = true
                        case "response.failed", "error":
                            let msg =
                                ((j["response"] as? [
                                    String: Any
                                ])?["error"] as? [String: Any])?["message"] as? String ??
                                (j["error"] as? [String: Any])?["message"] as? String ??
                                (j["message"] as? String) ?? tr("erro do modelo")
                            cont.yield(.error(msg))
                            cont.finish(); return
                        default: break
                        }
                        if viuFim {
                            break
                        }
                    }
                    if !viuFim {
                        cont.yield(.error(Cortes.conexaoCaiu)); cont.finish(); return
                    }
                    if status == "incomplete", motivo == "content_filter" {
                        cont.yield(.error(Cortes.filtro)); cont.finish(); return
                    }
                    let cortado = status == "incomplete"
                    if let r = RaciocinioBruto.de(
                        raciocinios,
                        formato: "responses",
                        origem: ctx.origem,
                        modelo: modelo
                    ) {
                        cont.yield(.raciocinio(r))
                    }
                    let calls = acc.calls(ferramentas: ctx.ferramentas, cortado: cortado)
                    if !calls.isEmpty {
                        cont.yield(.tools(calls))
                    } else if cortado {
                        cont.yield(.error(Cortes.respostaCortada)); cont.finish(); return
                    }
                    cont.yield(.done)
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}
