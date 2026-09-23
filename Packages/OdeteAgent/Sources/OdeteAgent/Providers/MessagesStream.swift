import Foundation
import OdeteI18n

/// Anthropic Messages com SSE: Claude (OAuth) e Anthropic-compatível (x-api-key).
///
/// O corpo segue o que o modelo aceita (ver `Capacidades`), nunca o nome dele:
/// `max_tokens` é o teto de saída do próprio modelo — a API exige o campo, e um teto
/// menor que o do modelo só servia para cortar `write_file` grande no meio —, thinking
/// adaptativo com o esforço em `output_config.effort`, e orçamento (`budget_tokens`) só
/// para quem ainda pede. Sem `temperature`: os modelos novos recusam com 400.
enum MessagesStream {
    struct Opcoes {
        var saida = Familia.anthropic.saidaPadrao
        var pensamento: Pensamento = .adaptativo
        var esforcos = Familia.anthropic.esforcosMaisNovos
        /// api.anthropic.com: resumo do raciocínio, streaming de entrada ansioso e o
        /// vínculo do thinking. Proxy e compatível de terceiros podem recusar esses campos.
        var oficial = false
        var recusados: Set<String> = []
        /// De onde veio o raciocínio que pode voltar (`provedor@host`).
        var origem = ""
        /// Um 400 reclamou da assinatura de um bloco devolvido: vai sem raciocínio antigo.
        var semRaciocinio = false
        /// Blocos de uma resposta pausada (`pause_turn`), para ela continuar de onde parou.
        var continuacao: [[String: Any]] = []

        init() {}

        init(_ c: Capacidades, kind: ProviderKind, host: String) {
            let f = Familia(kind)
            saida = c.saida ?? f.saidaPadrao
            pensamento = c.pensamento ?? .adaptativo
            esforcos = c.esforcos ?? f.esforcosMaisNovos
            oficial = host == "api.anthropic.com"
            recusados = Set(c.recusados ?? [])
            origem = "\(kind.rawValue)@\(host)"
        }
    }

    struct Montado {
        var corpo: [String: Any]
        var mandado: PedidoMandado
        var betas: [String]
    }

    static let betaDoVinculo = "thinking-binding-controls-2026-08-01"

    static func body(_ t: TurnRequest, _ o: Opcoes = Opcoes()) -> Montado {
        var b: [String: Any] = [
            "model": t.model,
            "stream": true,
            "max_tokens": o.saida,
            "messages": messages(t, o),
        ]
        if !t.system.isEmpty {
            b["system"] = t.system
        }
        var m = PedidoMandado(saida: o.saida)
        var betas: [String] = []
        let nivel = Effort.nivel(t.effort, aceitos: o.esforcos)
        var thinking: [String: Any]?
        switch o.pensamento {
        case .adaptativo:
            var th: [String: Any] = ["type": "adaptive"]
            // A tela mostra o raciocínio; o padrão dos modelos novos é devolver o bloco
            // vazio, e aí o "pensando…" ficava uma pausa muda.
            if o.oficial, !o.recusados.contains("display") {
                th["display"] = "summarized"; m.campos.insert("display")
            }
            thinking = th
        case .orcamento:
            let n = Effort.nivel(t.effort, aceitos: Effort.niveisDeOrcamento)
            if let n, n != "none", let orcamento = Effort.orcamento(n, saida: o.saida) {
                thinking = ["type": "enabled", "budget_tokens": orcamento]
            }
        case .nenhum:
            break
        }
        if var th = thinking {
            // O raciocínio assinado fica preso ao começo da conversa; se o histórico
            // mudou (janela que anda, instruções refeitas), o servidor descarta os
            // blocos antigos em vez de recusar o pedido inteiro.
            if o.oficial, !o.recusados.contains("block_binding") {
                th["block_binding"] = ["prefix_mismatch_behavior": "drop_block"]
                betas.append(betaDoVinculo); m.campos.insert("block_binding")
            }
            b["thinking"] = th
            m.pensamento = o.pensamento
        }
        if let nivel {
            b["output_config"] = ["effort": nivel]
            m.nivel = nivel
        }
        if !t.tools.isEmpty {
            let ansioso = o.oficial && !o.recusados.contains("eager_input_streaming")
            if ansioso {
                m.campos.insert("eager_input_streaming")
            }
            b["tools"] = t.tools.map { spec -> [String: Any] in
                var d: [String: Any] = [
                    "name": spec.name,
                    "description": spec.description,
                    "input_schema": spec.parameters,
                ]
                // Argumento grande (um arquivo inteiro) chega aos pedaços em vez de
                // depois de minutos de silêncio. O servidor para de validar — valida-se
                // em `ToolAcc.calls`.
                if ansioso {
                    d["eager_input_streaming"] = true
                }
                return d
            }
        }
        return Montado(corpo: b, mandado: m, betas: betas)
    }

    static func messages(_ t: TurnRequest, _ o: Opcoes = Opcoes()) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in t.messages {
            switch m.role {
            case .system: continue
            case .user:
                if let imgs = m.images, !imgs.isEmpty {
                    var blocks: [[String: Any]] = imgs.map { [
                        "type": "image",
                        "source": ["type": "base64", "media_type": $0.mime, "data": $0.data],
                    ] }
                    blocks.append(["type": "text", "text": m.content.isEmpty ? " " : m.content])
                    out.append(["role": "user", "content": blocks])
                } else {
                    out.append(["role": "user", "content": m.content])
                }
            case .assistant:
                out.append(["role": "assistant", "content": assistente(m, t, o)])
            case .tool:
                let block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": m.toolCallId ?? "",
                    "content": m.content,
                ]
                if var last = out.last, last["role"] as? String == "user", var arr = last["content"] as? [
                    [String: Any]
                ],
                    arr.last?["type"] as? String == "tool_result"
                {
                    arr.append(block); last["content"] = arr; out[out.count - 1] = last
                } else {
                    out.append(["role": "user", "content": [block]])
                }
            }
        }
        if !o.continuacao.isEmpty {
            // A resposta pausada vai como última mensagem do assistente, e aí a API recusa
            // texto terminando em espaço.
            var blocos = o.continuacao
            if var ultimo = blocos.last, ultimo["type"] as? String == "text", let t = ultimo["text"] as? String {
                ultimo["text"] = String(t.reversed().drop(while: \.isWhitespace).reversed())
                blocos[blocos.count - 1] = ultimo
            }
            out.append(["role": "assistant", "content": blocos])
        }
        return out
    }

    /// O conteúdo de uma mensagem do assistente.
    ///
    /// Com o raciocínio guardado, volta a resposta como chegou: os blocos de `thinking`
    /// com a assinatura, na ordem em que vieram entre o texto e as chamadas. Quando a
    /// mensagem do histórico já não bate com eles (a rodada foi redirecionada, por
    /// exemplo), vão só os blocos de raciocínio na frente e o resto é remontado.
    static func assistente(_ m: AgentMessage, _ t: TurnRequest, _ o: Opcoes) -> Any {
        let brutos = raciocinioQueVolta(m, t, o)
        let chamadas = m.toolCalls ?? []
        // Uma resposta feita só de raciocínio não volta como está: sem texto nem chamada,
        // a mensagem do assistente fica sem conteúdo que a API aceite.
        if chamadas.isEmpty, m.content.isEmpty {
            return " "
        }
        if !brutos.isEmpty, bate(brutos, m) {
            return brutos
        }
        let pensados = brutos.filter { ["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
        if chamadas.isEmpty, pensados.isEmpty {
            return m.content
        }
        var blocks = pensados
        if !m.content.isEmpty {
            blocks.append(["type": "text", "text": m.content])
        }
        for c in chamadas {
            blocks.append(["type": "tool_use", "id": c.id, "name": c.name, "input": c.args])
        }
        return blocks
    }

    static func raciocinioQueVolta(_ m: AgentMessage, _ t: TurnRequest, _ o: Opcoes) -> [[String: Any]] {
        guard !o.semRaciocinio, let r = m.raciocinio, r.formato == "anthropic", r.origem == o.origem,
              // Na API oficial o servidor descarta o que outro modelo não lê; num
              // compatível de terceiros, bloco assinado de outro modelo pode derrubar o
              // pedido.
              o.oficial || r.modelo == t.model
        else { return [] }
        return r.itens
    }

    /// Os blocos guardados são a mesma resposta que está no histórico?
    static func bate(_ blocos: [[String: Any]], _ m: AgentMessage) -> Bool {
        let ids = blocos.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
        let texto = blocos.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        return ids == (m.toolCalls ?? []).map(\.id) && texto == m.content
    }

    /// Soma um pedaço de texto a um campo do bloco `i`.
    static func anexar(_ blocos: inout [Int: [String: Any]], _ i: Int, _ campo: String, _ s: String) {
        guard var b = blocos[i] else { return }
        b[campo] = ((b[campo] as? String) ?? "") + s
        blocos[i] = b
    }

    static func events(
        _ lines: AsyncThrowingStream<String, Error>,
        _ ctx: ContextoDoFluxo = ContextoDoFluxo()
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                var acc = SSE.ToolAcc()
                var blocos: [Int: [String: Any]] = [:]
                var ultimo = -1
                var parada: String?
                var detalhes: [String: Any]?
                var modelo = ctx.modelo
                var terminou = false
                var falhou = false
                do {
                    for try await line in lines {
                        let j = jsonObject(Data(line.utf8))
                        guard let type = j["type"] as? String else { continue }
                        if let u = TokenUse.pick(j) {
                            cont.yield(.usage(u))
                        }
                        switch type {
                        case "error":
                            let e = j["error"] as? [String: Any]
                            ctx.fim?.anotar { $0.tipoDoErro = e?["type"] as? String }
                            cont.yield(.error((e?["message"] as? String) ?? tr("erro do modelo")))
                            falhou = true
                        case "message_start":
                            if let m = (j["message"] as? [String: Any])?["model"] as? String, !m.isEmpty {
                                modelo = m
                            }
                        case "content_block_start":
                            var b = (j["content_block"] as? [String: Any]) ?? [:]
                            let i = (j["index"] as? Int) ?? ultimo + 1
                            ultimo = i
                            switch b["type"] as? String {
                            case "tool_use":
                                acc.add(i, id: b["id"] as? String, name: b["name"] as? String)
                                b["input"] = [String: Any]()
                            case "thinking":
                                b["thinking"] = (b["thinking"] as? String) ?? ""
                                b["signature"] = (b["signature"] as? String) ?? ""
                            case "text":
                                b["text"] = (b["text"] as? String) ?? ""
                            default: break
                            }
                            blocos[i] = b
                        case "content_block_delta":
                            let i = (j["index"] as? Int) ?? ultimo
                            guard let d = j["delta"] as? [String: Any] else { break }
                            switch d["type"] as? String {
                            case "thinking_delta":
                                if let s = d["thinking"] as? String, !s.isEmpty {
                                    anexar(&blocos, i, "thinking", s)
                                    cont.yield(.think(s))
                                }
                            case "signature_delta":
                                if let s = d["signature"] as? String {
                                    anexar(&blocos, i, "signature", s)
                                }
                            case "text_delta":
                                if let s = d["text"] as? String, !s.isEmpty {
                                    anexar(&blocos, i, "text", s)
                                    cont.yield(.text(s))
                                }
                            case "input_json_delta":
                                if blocos[i]?["type"] as? String == "tool_use" {
                                    acc.add(i, args: d["partial_json"] as? String)
                                }
                            default: break
                            }
                        case "content_block_stop":
                            let i = (j["index"] as? Int) ?? ultimo
                            if blocos[i]?["type"] as? String == "tool_use" {
                                acc.fechar(i)
                                let args = acc.items[i]?.args ?? ""
                                let objeto = try? JSONSerialization.jsonObject(with: Data((args.isEmpty ? "{}" : args).utf8))
                                blocos[i]?["input"] = (objeto as? [String: Any]) ?? [String: Any]()
                            }
                        case "message_delta":
                            let d = j["delta"] as? [String: Any]
                            parada = (d?["stop_reason"] as? String) ?? parada
                            detalhes = (d?["stop_details"] as? [String: Any]) ?? (j["stop_details"] as? [String: Any]) ??
                                detalhes
                        case "message_stop":
                            terminou = true
                        default: break
                        }
                        if falhou || terminou {
                            break
                        }
                    }
                    if falhou {
                        cont.finish(); return
                    }
                    ctx.fim?.anotar { $0.parada = parada; $0.modelo = modelo }
                    let todos = ctx.prefixo + blocos.sorted { $0.key < $1.key }.map(\.value)
                    switch parada {
                    case "refusal":
                        // Recusa não executa nada: o bloco de ferramenta pode ter sido
                        // cortado no meio pelo classificador.
                        cont.yield(.error(Cortes.recusa(detalhes)))
                        cont.finish(); return
                    case "pause_turn":
                        // Quem abriu o pedido continua a resposta de onde parou.
                        ctx.fim?.anotar { $0.pausado = RaciocinioBruto.de(todos, formato: "anthropic", origem: "", modelo: "")?.json }
                        cont.finish(); return
                    default: break
                    }
                    if !terminou, parada == nil {
                        cont.yield(.error(Cortes.conexaoCaiu))
                        cont.finish(); return
                    }
                    let cortado = parada == "max_tokens"
                    if todos.contains(where: { ["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }),
                       let r = RaciocinioBruto.de(todos, formato: "anthropic", origem: ctx.origem, modelo: modelo)
                    {
                        cont.yield(.raciocinio(r))
                    }
                    let calls = acc.calls(ferramentas: ctx.ferramentas, cortado: cortado)
                    if !calls.isEmpty {
                        cont.yield(.tools(calls))
                    } else if cortado {
                        cont.yield(.error(Cortes.respostaCortada))
                        cont.finish(); return
                    }
                    cont.yield(.done)
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}
