import Foundation
import OdeteAccounts
@testable import OdeteAgent
import OdeteI18n
import Synchronization
import Testing

/// Os provedores de nuvem de ponta a ponta, contra um servidor falso.
///
/// Em série porque o servidor falso é um só para o processo inteiro.
@Suite(.serialized)
struct ProvedoresTests {
    init() {
        Texto.escolher(.ptBR)
    }

    static let turnoComFerramenta = TurnRequest(
        system: "sys",
        messages: [.user("escreve o arquivo")],
        tools: [ToolSpec(
            name: "write_file",
            description: "escreve",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string"], "content": ["type": "string"]],
                "required": ["path", "content"],
            ]
        )],
        model: "claude-sonnet-5",
        effort: "high"
    )

    static func turno(_ modelo: String, esforco: String = "high") -> TurnRequest {
        var t = turnoComFerramenta
        t.model = modelo
        t.effort = esforco
        return t
    }

    /// A Models API conhece estes; o resto é 404, como um modelo que saiu depois.
    static func apiDaAnthropic(_ p: StubURLProtocol.Pedido) -> StubURLProtocol.Resposta? {
        guard p.url.path().contains("/v1/models/") else { return nil }
        let id = p.url.lastPathComponent
        switch id {
        case "claude-sonnet-5", "claude-opus-5-5", "claude-fable-5-1":
            return .init(corpo: modeloDaAnthropic(
                id,
                contexto: 1_000_000,
                saida: 128_000,
                adaptativo: true,
                orcamento: false,
                esforcos: ["low", "medium", "high", "xhigh", "max"]
            ))
        case "claude-haiku-4-5":
            return .init(corpo: modeloDaAnthropic(
                id,
                contexto: 200_000,
                saida: 64000,
                adaptativo: false,
                orcamento: true,
                esforcos: nil
            ))
        default:
            return .init(status: 404, corpo: #"{"type":"error","error":{"type":"not_found_error","message":"model"}}"#)
        }
    }

    static let respostaSimples = sseAnthropic([["type": "text", "text": "ok"]])

    // MARK: corpo Anthropic

    /// Sonnet 5 (o modelo padrão), Opus 5.5 e Fable 5.1 recusam `budget_tokens` e
    /// `temperature` com 400. Antes ia `thinking.enabled` com orçamento e `max_tokens`
    /// de 14000; sem esforço, `temperature: 0.3` e 1600.
    @Test(arguments: ["claude-sonnet-5", "claude-opus-5-5", "claude-fable-5-1"])
    func corpoDosModelosAdaptativos(_ modelo: String) async throws {
        StubURLProtocol.servir { p in Self.apiDaAnthropic(p) ?? .init(corpo: Self.respostaSimples) }
        let ev = try await eventos(provedorDeTeste(.claude).stream(Self.turno(modelo)))
        #expect(ev.texto == "ok" && ev.erros.isEmpty)
        let pedido = try #require(StubURLProtocol.pedidos("/v1/messages").first)
        let b = pedido.json
        #expect(b["model"] as? String == modelo)
        #expect(b["max_tokens"] as? Int == 128_000)
        #expect(b["temperature"] == nil && b["top_p"] == nil && b["top_k"] == nil)
        let th = try #require(b["thinking"] as? [String: Any])
        #expect(th["type"] as? String == "adaptive" && th["budget_tokens"] == nil)
        #expect(th["display"] as? String == "summarized")
        #expect((th["block_binding"] as? [String: Any])?["prefix_mismatch_behavior"] as? String == "drop_block")
        #expect((b["output_config"] as? [String: Any])?["effort"] as? String == "high")
        #expect(b["tool_choice"] == nil)
        let tool = try #require((b["tools"] as? [[String: Any]])?.first)
        #expect(tool["eager_input_streaming"] as? Bool == true)
        let betas = pedido.headers["anthropic-beta"] ?? ""
        #expect(betas.contains("oauth-2025-04-20") && betas.contains(MessagesStream.betaDoVinculo))
    }

    /// Haiku 4.5 ainda pede orçamento e não tem esforço: o corpo sai do que a Models API
    /// disse, não do nome.
    @Test func corpoDoHaiku45() async throws {
        StubURLProtocol.servir { p in Self.apiDaAnthropic(p) ?? .init(corpo: Self.respostaSimples) }
        let registro = RegistroDeCapacidades(arquivo: nil)
        _ = try await eventos(provedorDeTeste(.claude, registro: registro).stream(Self.turno("claude-haiku-4-5")))
        let b = try #require(StubURLProtocol.pedidos("/v1/messages").first).json
        #expect(b["max_tokens"] as? Int == 64000)
        let th = try #require(b["thinking"] as? [String: Any])
        let orcamento = try #require(th["budget_tokens"] as? Int)
        #expect(th["type"] as? String == "enabled" && orcamento >= 1024 && orcamento < 64000)
        #expect(th["display"] == nil)
        #expect(b["output_config"] == nil && b["temperature"] == nil)
        // E a tela passa a oferecer os níveis de orçamento, não os de esforço.
        #expect(Effort.options(
            kind: .claude,
            model: "claude-haiku-4-5",
            fromAPI: nil,
            registro: registro,
            catalogo: nil
        ) == Effort.niveisDeOrcamento)
    }

    /// Um modelo que ninguém descreveu (a Models API ainda não o conhece) sai no formato
    /// mais novo — nunca no mais antigo.
    @Test func modeloInventadoSaiNoFormatoNovo() async throws {
        StubURLProtocol.servir { p in Self.apiDaAnthropic(p) ?? .init(corpo: Self.respostaSimples) }
        _ = try await eventos(provedorDeTeste(.claude).stream(Self.turno("claude-opus-6", esforco: "max")))
        let b = try #require(StubURLProtocol.pedidos("/v1/messages").first).json
        #expect(b["max_tokens"] as? Int == 128_000)
        #expect((b["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((b["output_config"] as? [String: Any])?["effort"] as? String == "max")
        #expect(b["temperature"] == nil)
    }

    /// Chutou alto e a API disse o teto: o pedido é refeito com ele, e o teto fica
    /// guardado para a janela da compactação e para o próximo pedido.
    @Test func quatrocentosEnsinaOTetoDeSaida() async throws {
        StubURLProtocol.servir { p in
            if let r = Self.apiDaAnthropic(p) {
                return r
            }
            if (p.json["max_tokens"] as? Int ?? 0) > 64000 {
                return .init(
                    status: 400,
                    corpo: #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: 128000 > 64000, which is the maximum allowed number of output tokens for claude-opus-6"}}"#
                )
            }
            return .init(corpo: Self.respostaSimples)
        }
        let registro = RegistroDeCapacidades(arquivo: nil)
        let ev = try await eventos(provedorDeTeste(.claude, registro: registro).stream(Self.turno("claude-opus-6")))
        #expect(ev.texto == "ok" && ev.erros.isEmpty)
        let mandados = StubURLProtocol.pedidos("/v1/messages").map { $0.json["max_tokens"] as? Int }
        #expect(mandados == [128_000, 64000])
        #expect(registro.ler(.claude, "claude-opus-6")?.saida == 64000)
        let limites = await LimitesDosModelos.limites(
            provider: .claude,
            model: "claude-opus-6",
            registro: registro,
            catalogo: nil
        )
        #expect(limites.saida == 64000)
    }

    /// Conversa quase enchendo a janela: o teto de saída encolhe para o que sobra, só
    /// neste pedido — o do modelo não muda.
    @Test func tetoCabeNoQueSobraDaJanela() async throws {
        StubURLProtocol.servir { p in
            if let r = Self.apiDaAnthropic(p) {
                return r
            }
            if (p.json["max_tokens"] as? Int ?? 0) > 50000 {
                return .init(
                    status: 400,
                    corpo: #"{"type":"error","error":{"type":"invalid_request_error","message":"input length and `max_tokens` exceed context limit: 150000 + 64000 > 200000, decrease input length or `max_tokens` and try again"}}"#
                )
            }
            return .init(corpo: Self.respostaSimples)
        }
        let registro = RegistroDeCapacidades(arquivo: nil)
        let ev = try await eventos(provedorDeTeste(.claude, registro: registro).stream(Self.turno("claude-haiku-4-5")))
        #expect(ev.texto == "ok" && ev.erros.isEmpty)
        let mandados = StubURLProtocol.pedidos("/v1/messages").map { $0.json["max_tokens"] as? Int }
        #expect(mandados == [64000, 50000])
        #expect(registro.ler(.claude, "claude-haiku-4-5")?.saida == 64000)
        // O orçamento de thinking acompanha, sempre abaixo do teto do pedido.
        let orcamento = (StubURLProtocol.pedidos("/v1/messages").last?.json["thinking"] as? [String: Any])?[
            "budget_tokens"
        ] as? Int
        #expect((orcamento ?? .max) < 50000)
    }

    /// Endpoint compatível de terceiros sem Models API: o catálogo do models.dev diz o
    /// teto e o formato de thinking; e os campos que só a API oficial conhece não vão.
    @Test func compativelUsaOCatalogo() async throws {
        StubURLProtocol.servir { p in
            p.url.path().contains("/v1/models/") ? .init(status: 404, corpo: "{}") : .init(corpo: Self.respostaSimples)
        }
        let fake = FakeHTTP()
        fake.enqueue("https://models.dev/api.json", 200, #"""
        {"deepseek":{"id":"deepseek","models":{"deepseek-v4":{"id":"deepseek-v4","reasoning":true,
          "reasoning_options":[{"type":"toggle"},{"type":"budget_tokens","min":1024}],
          "limit":{"context":256000,"output":32000}}}}}
        """#)
        let catalogo = CatalogoDeModelos(pasta: nil, http: fake)
        let p = provedorDeTeste(.anthropicCompat, base: "https://proxy.exemplo.test", catalogo: catalogo)
        _ = try await eventos(p.stream(Self.turno("deepseek-v4", esforco: "medium")))
        let pedido = try #require(StubURLProtocol.pedidos("/v1/messages").first)
        let b = pedido.json
        #expect(b["max_tokens"] as? Int == 32000)
        #expect((b["thinking"] as? [String: Any])?["type"] as? String == "enabled")
        #expect((b["thinking"] as? [String: Any])?["block_binding"] == nil)
        #expect((b["tools"] as? [[String: Any]])?.first?["eager_input_streaming"] == nil)
        #expect(pedido.headers["anthropic-beta"] == nil)
        #expect(pedido.headers["x-api-key"] == "chave-de-teste")
    }

    // MARK: OpenAI e Grok

    /// Modelo na nuvem não tem teto artificial de saída: nem `max_output_tokens` (que o
    /// Codex recusava com 400), nem `max_tokens`, nem `max_completion_tokens`.
    @Test(arguments: ["gpt-6-sol", "gpt-6-luna"])
    func openAISemLimiteDeSaida(_ modelo: String) async throws {
        let respostas = sse([
            ["type": "response.created", "response": ["id": "r1", "model": modelo]],
            ["type": "response.output_text.delta", "delta": "ok"],
            ["type": "response.completed", "response": ["id": "r1", "status": "completed"]],
        ])
        let chat = #"data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"# +
            "\n\ndata: [DONE]\n\n"
        StubURLProtocol.servir { p in .init(corpo: p.url.path().hasSuffix("/chat/completions") ? chat : respostas) }
        let proibidos = ["max_output_tokens", "max_tokens", "max_completion_tokens", "temperature"]
        for kind in [ProviderKind.codex, .openaiCompat, .grok] {
            let ev = try await eventos(provedorDeTeste(kind).stream(Self.turno(modelo, esforco: "high")))
            #expect(ev.texto == "ok" && ev.erros.isEmpty, "\(kind)")
        }
        let pedidos = StubURLProtocol.pedidos.filter { $0.metodo == "POST" }
        #expect(pedidos.count == 3)
        for p in pedidos {
            let b = p.json
            #expect(proibidos.allSatisfy { b[$0] == nil }, "\(p.url)")
        }
        let responses = pedidos.filter { $0.url.path().hasSuffix("/responses") }
        #expect(responses.count == 2)
        for p in responses {
            #expect(p.json["include"] as? [String] == ["reasoning.encrypted_content"])
            #expect((p.json["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        }
    }

    // MARK: cortes

    /// `stop_reason: max_tokens` com só texto: erro explícito, não um fim silencioso.
    @Test func maxTokensViraErroExplicito() async throws {
        StubURLProtocol.servir { p in
            Self.apiDaAnthropic(p) ?? .init(corpo: sseAnthropic([["type": "text", "text": "metade"]], parada: "max_tokens"))
        }
        let ev = try await eventos(provedorDeTeste(.claude).stream(Self.turno("claude-sonnet-5")))
        #expect(ev.erros == [Cortes.respostaCortada])
        #expect(!ev.terminou)
    }

    /// A chamada que estava sendo escrita quando o teto chegou volta marcada, e o
    /// executor devolve ao modelo que ela foi cortada — antes era "argumentos JSON
    /// inválidos".
    @Test func chamadaCortadaChegaAoModeloComoErro() async throws {
        StubURLProtocol.servir { p in
            Self.apiDaAnthropic(p) ?? .init(corpo: sseAnthropic([
                ["type": "text", "text": "Vou escrever."],
                ["type": "tool_use", "id": "toolu_9", "name": "write_file",
                 "json": #"{"path":"a.txt","content":"começo do arq"#, "aberto": true],
            ], parada: "max_tokens"))
        }
        let ev = try await eventos(provedorDeTeste(.claude).stream(Self.turno("claude-sonnet-5")))
        let c = try #require(ev.chamadas.first)
        #expect(c.id == "toolu_9" && c.problema == Cortes.chamadaCortada("write_file"))
        let root = try tmpProject()
        let host = TestHost(root: root)
        let saida = await ToolRunner(host: host, patches: PatchStore(root: root)).run(c, mode: .build)
        #expect(saida.text == Cortes.chamadaCortada("write_file") && saida.patch == nil)
        #expect((try? String(contentsOf: root.appending(path: "a.txt"), encoding: .utf8)) == "a\nb\nc\n")
    }

    /// Responses incompleto por teto e Chat Completions com `length`: mesmo tratamento.
    @Test func cortesDaOpenAIViramErro() async throws {
        let incompleto = sse([
            ["type": "response.output_text.delta", "delta": "metade"],
            ["type": "response.incomplete", "response": [
                "status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"],
            ]],
        ])
        let r = try await eventos(ResponsesStream.events(SSE.data(fromText: incompleto)))
        #expect(r.erros == [Cortes.respostaCortada])
        let chat = #"data: {"choices":[{"index":0,"delta":{"content":"meta"},"finish_reason":"length"}]}"# + "\n"
        let c = try await eventos(ChatCompletionsStream.events(SSE.data(fromText: chat)))
        #expect(c.erros == [Cortes.respostaCortada])
    }

    /// Stream que termina sem `message_stop` (conexão caiu) não passa por resposta
    /// completa.
    @Test func conexaoQueCaiNaoPassaPorFim() async throws {
        let s = sse([
            ["type": "message_start", "message": ["id": "m", "model": "claude-sonnet-5"]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "meio"]],
        ])
        let ev = try await eventos(MessagesStream.events(SSE.data(fromText: s)))
        #expect(ev.texto == "meio" && ev.erros == [Cortes.conexaoCaiu] && !ev.terminou)
        let r = try await eventos(ResponsesStream.events(SSE.data(fromText: sse([
            ["type": "response.output_text.delta", "delta": "meio"],
        ]))))
        #expect(r.erros == [Cortes.conexaoCaiu])
    }

    /// Recusa do classificador: erro com a categoria de `stop_details`, e a ferramenta
    /// que estava no meio não roda.
    @Test func recusaNaoExecutaFerramenta() async throws {
        StubURLProtocol.servir { p in
            Self.apiDaAnthropic(p) ?? .init(corpo: sseAnthropic(
                [["type": "tool_use", "id": "toolu_1", "name": "write_file", "json": "{}"]],
                parada: "refusal",
                detalhes: ["type": "refusal", "category": "cyber"]
            ))
        }
        let ev = try await eventos(provedorDeTeste(.claude).stream(Self.turno("claude-opus-5-5")))
        #expect(ev.chamadas.isEmpty)
        #expect(ev.erros.count == 1 && ev.erros[0].contains("cyber"))
    }

    /// `pause_turn`: a resposta pausada volta como está e o modelo continua dela, no
    /// mesmo turno.
    @Test func pauseTurnContinua() async throws {
        let n = Mutex(0)
        StubURLProtocol.servir { p in
            if let r = Self.apiDaAnthropic(p) {
                return r
            }
            let i = n.withLock { $0 += 1; return $0 }
            return .init(corpo: i == 1
                ? sseAnthropic([["type": "text", "text": "parte 1 "]], parada: "pause_turn")
                : sseAnthropic([["type": "text", "text": "parte 2"]]))
        }
        let ev = try await eventos(provedorDeTeste(.claude).stream(Self.turno("claude-sonnet-5")))
        #expect(ev.texto == "parte 1 parte 2" && ev.erros.isEmpty && ev.terminou)
        let pedidos = StubURLProtocol.pedidos("/v1/messages")
        #expect(pedidos.count == 2)
        let ultima = try #require((pedidos[1].json["messages"] as? [[String: Any]])?.last)
        #expect(ultima["role"] as? String == "assistant")
        // Espaço no fim da última mensagem do assistente a API recusa; o resto vai igual.
        #expect((ultima["content"] as? [[String: Any]])?.first?["text"] as? String == "parte 1")
    }

    // MARK: raciocínio devolvido

    /// O bloco de thinking assinado volta intacto, na posição em que veio, na rodada
    /// seguinte com o mesmo modelo.
    @Test func raciocinioAnthropicVoltaIntacto() async throws {
        let n = Mutex(0)
        StubURLProtocol.servir { p in
            if let r = Self.apiDaAnthropic(p) {
                return r
            }
            let i = n.withLock { $0 += 1; return $0 }
            return .init(corpo: i == 1
                ? sseAnthropic([
                    ["type": "thinking", "thinking": "preciso ler antes", "signature": "sig-A1"],
                    ["type": "text", "text": "Lendo."],
                    ["type": "tool_use", "id": "toolu_7", "name": "write_file",
                     "json": #"{"path":"x.txt","content":"oi"}"#],
                ], parada: "tool_use")
                : Self.respostaSimples)
        }
        let p = provedorDeTeste(.claude)
        let turno1 = Self.turno("claude-opus-5-5")
        let ev = try await eventos(p.stream(turno1))
        let r = try #require(ev.raciocinio)
        #expect(r.formato == "anthropic" && r.origem == "claude@api.anthropic.com")
        var turno2 = turno1
        turno2.messages += [
            AgentMessage(
                role: .assistant,
                content: ev.texto,
                thinking: "preciso ler antes",
                toolCalls: ev.chamadas,
                raciocinio: r
            ),
            .tool("toolu_7", "gravado"),
        ]
        _ = try await eventos(p.stream(turno2))
        let segundo = try #require(StubURLProtocol.pedidos("/v1/messages").last).json
        let msgs = try #require(segundo["messages"] as? [[String: Any]])
        let conteudo = try #require(msgs[1]["content"] as? [[String: Any]])
        #expect(conteudo.map { $0["type"] as? String } == ["thinking", "text", "tool_use"])
        #expect(conteudo[0]["thinking"] as? String == "preciso ler antes")
        #expect(conteudo[0]["signature"] as? String == "sig-A1")
        #expect(conteudo[2]["id"] as? String == "toolu_7")
        #expect((conteudo[2]["input"] as? [String: Any])?["path"] as? String == "x.txt")
    }

    /// O raciocínio criptografado da OpenAI volta antes da chamada que ele produziu, e
    /// não vai para outro modelo.
    @Test func raciocinioCriptografadoVolta() async throws {
        let item: [String: Any] = [
            "type": "reasoning", "id": "rs_1", "encrypted_content": "gAAAA-cripto",
            "summary": [["type": "summary_text", "text": "pensei"]],
        ]
        let resposta = sse([
                ["type": "response.created", "response": ["id": "r1", "model": "gpt-6-sol"]],
                ["type": "response.output_item.done", "output_index": 0, "item": item],
                ["type": "response.output_item.added", "output_index": 1, "item": [
                    "type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "write_file", "arguments": "",
                ]],
                ["type": "response.function_call_arguments.delta", "item_id": "fc_1",
                 "delta": #"{"path":"a","content":"b"}"#],
                ["type": "response.output_item.done", "output_index": 1, "item": [
                    "type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "write_file",
                    "arguments": #"{"path":"a","content":"b"}"#,
                ]],
                ["type": "response.completed", "response": ["id": "r1", "status": "completed"]],
            ])
        StubURLProtocol.servir { _ in .init(corpo: resposta) }
        let p = provedorDeTeste(.codex)
        let t1 = Self.turno("gpt-6-sol")
        let ev = try await eventos(p.stream(t1))
        let r = try #require(ev.raciocinio)
        var t2 = t1
        t2.messages += [
            AgentMessage(role: .assistant, content: "", toolCalls: ev.chamadas, raciocinio: r),
            .tool("call_1", "ok"),
        ]
        _ = try await eventos(p.stream(t2))
        let input = try #require(StubURLProtocol.pedidos.last?.json["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == [nil, "reasoning", "function_call", "function_call_output"])
        #expect(input[1]["encrypted_content"] as? String == "gAAAA-cripto")
        // Outro modelo: o criptografado não vai.
        var t3 = t2
        t3.model = "gpt-6-luna"
        _ = try await eventos(p.stream(t3))
        let input3 = try #require(StubURLProtocol.pedidos.last?.json["input"] as? [[String: Any]])
        #expect(!input3.contains { $0["type"] as? String == "reasoning" })
    }

    /// Assinatura recusada (histórico mexido em conta nova): o pedido vai de novo sem o
    /// raciocínio antigo, uma vez, em vez de o turno morrer.
    @Test func assinaturaRecusadaTiraORaciocinio() async throws {
        StubURLProtocol.servir { p in
            if let r = Self.apiDaAnthropic(p) {
                return r
            }
            let temThinking = ((p.json["messages"] as? [[String: Any]]) ?? []).contains { m in
                ((m["content"] as? [[String: Any]]) ?? []).contains { $0["type"] as? String == "thinking" }
            }
            return temThinking
                ? .init(status: 400, corpo: #"{"type":"error","error":{"type":"invalid_request_error","message":"messages.1.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation."}}"#)
                : .init(corpo: Self.respostaSimples)
        }
        let bruto = try #require(RaciocinioBruto.de(
            [["type": "thinking", "thinking": "x", "signature": "velha"], ["type": "text", "text": "a"]],
            formato: "anthropic",
            origem: "claude@api.anthropic.com",
            modelo: "claude-sonnet-5"
        ))
        var t = Self.turno("claude-sonnet-5")
        t.messages = [.user("oi"), AgentMessage(role: .assistant, content: "a", raciocinio: bruto), .user("e aí")]
        let ev = try await eventos(provedorDeTeste(.claude).stream(t))
        #expect(ev.texto == "ok" && ev.erros.isEmpty)
        #expect(StubURLProtocol.pedidos("/v1/messages").count == 2)
    }

    // MARK: novas tentativas

    /// 529 (sobrecarga) antes do stream começar: espera curta e tenta de novo.
    @Test func tentaDeNovoEm529() async throws {
        let n = Mutex(0)
        StubURLProtocol.servir { p in
            if let r = Self.apiDaAnthropic(p) {
                return r
            }
            let i = n.withLock { $0 += 1; return $0 }
            return i == 1
                ? .init(status: 529, corpo: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
                : .init(corpo: Self.respostaSimples)
        }
        let esperas = Esperas()
        let ev = try await eventos(provedorDeTeste(.claude, esperas: esperas).stream(Self.turno("claude-sonnet-5")))
        #expect(ev.texto == "ok" && ev.erros.isEmpty)
        #expect(StubURLProtocol.pedidos("/v1/messages").count == 2)
        #expect(esperas.todas.count == 1)
    }

    /// Conexão que cai antes de a resposta começar: tenta de novo depois de uma espera
    /// curta, em vez de o turno morrer na primeira oscilação do wifi.
    @Test func conexaoCaidaTentaDeNovo() async throws {
        let n = Mutex(0)
        StubURLProtocol.servir { p in
            if let r = Self.apiDaAnthropic(p) {
                return r
            }
            let i = n.withLock { $0 += 1; return $0 }
            return i == 1 ? .init(cair: true) : .init(corpo: Self.respostaSimples)
        }
        let esperas = Esperas()
        let ev = try await eventos(provedorDeTeste(.claude, esperas: esperas).stream(Self.turno("claude-sonnet-5")))
        #expect(ev.texto == "ok" && ev.erros.isEmpty)
        #expect(StubURLProtocol.pedidos("/v1/messages").count == 2 && esperas.todas.count == 1)
    }

    /// `overloaded_error` no começo do stream, antes de qualquer texto, também merece
    /// outra tentativa — nada foi mostrado ainda.
    @Test func sobrecargaNoComecoDoStream() async throws {
        let n = Mutex(0)
        StubURLProtocol.servir { p in
            if let r = Self.apiDaAnthropic(p) {
                return r
            }
            let i = n.withLock { $0 += 1; return $0 }
            return .init(corpo: i == 1
                ? sse([["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]]])
                : Self.respostaSimples)
        }
        let ev = try await eventos(provedorDeTeste(.claude).stream(Self.turno("claude-sonnet-5")))
        #expect(ev.texto == "ok" && ev.erros.isEmpty)
    }

    /// 429 com `Retry-After`: espera o que o servidor pediu. Teto de gasto do mês não
    /// adianta esperar.
    @Test func respeitaRetryAfter() async throws {
        let n = Mutex(0)
        StubURLProtocol.servir { p in
            if let r = Self.apiDaAnthropic(p) {
                return r
            }
            let i = n.withLock { $0 += 1; return $0 }
            return i == 1
                ? .init(status: 429, corpo: #"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#,
                        headers: ["retry-after": "3"])
                : .init(corpo: Self.respostaSimples)
        }
        let esperas = Esperas()
        _ = try await eventos(provedorDeTeste(.claude, esperas: esperas).stream(Self.turno("claude-sonnet-5")))
        #expect(esperas.todas == [3])
        #expect(pausaAntesDeTentarDeNovo(AgentError.http(429, "enforced_spend_limit_reached"), 1) == nil)
        #expect(pausaAntesDeTentarDeNovo(AgentError.http(429, ""), 1, pedida: 120) == nil)
        #expect(pausaAntesDeTentarDeNovo(AgentError.http(529, ""), 1) != nil)
    }

    /// A lista de modelos da Anthropic já diz as capacidades de cada um: ficam guardadas
    /// e viram os níveis de esforço da tela e a janela da compactação.
    @Test func listaDeModelosGuardaCapacidades() async throws {
        let lista = "{\"data\":[" + modeloDaAnthropic(
            "claude-haiku-4-5", contexto: 200_000, saida: 64000, adaptativo: false, orcamento: true, esforcos: nil
        ) + "," + modeloDaAnthropic(
            "claude-sonnet-5", contexto: 1_000_000, saida: 128_000, adaptativo: true, orcamento: false,
            esforcos: ["low", "medium", "high", "xhigh", "max"]
        ) + "]}"
        StubURLProtocol.servir { _ in .init(corpo: lista) }
        let registro = RegistroDeCapacidades(arquivo: nil)
        let modelos = try await provedorDeTeste(.claude, registro: registro).models()
        let sonnet = try #require(modelos.first { $0.id == "claude-sonnet-5" })
        #expect(sonnet.efforts == ["low", "medium", "high", "xhigh", "max"] && sonnet.ctx == 1_000_000)
        #expect(modelos.first { $0.id == "claude-haiku-4-5" }?.efforts == Effort.niveisDeOrcamento)
        let l = await LimitesDosModelos.limites(provider: .claude, model: "claude-haiku-4-5", registro: registro, catalogo: nil)
        #expect(l.contexto == 200_000 && l.saida == 64000)
    }
}

// MARK: - Sem rede

/// A renovação do token que falha por rede não pede para reconectar a conta; só a recusa
/// do servidor pede.
@MainActor
struct RenovacaoTests {
    func conta(_ http: FakeHTTP) throws -> (AIAccountStore, AIAccount, Session) {
        let url = FileManager.default.temporaryDirectory.appending(path: "contas-\(UUID().uuidString).json")
        let store = AIAccountStore(url: url, secrets: MemorySecrets())
        let a = AIAccount(kind: .claude)
        try store.add(a, tokens: TokenBundle(access: "velho", refresh: "R", expiresAt: .distantPast))
        return (store, a, store.session(for: a, http: http))
    }

    func esperarAtualizacao(_ store: AIAccountStore, _ a: AIAccount, ate condicao: (AIAccount) -> Bool) async {
        for _ in 0 ..< 50 {
            if let atual = store.accounts.first(where: { $0.id == a.id }), condicao(atual) {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func erroDeRedeNaoDesconecta() async throws {
        let http = FakeHTTP() // sem resposta enfileirada: falha de transporte
        let (store, a, s) = try conta(http)
        await #expect(throws: (any Error).self) { try await s.refreshNow() }
        await esperarAtualizacao(store, a) { $0.needsReconnect }
        #expect(store.accounts.first { $0.id == a.id }?.needsReconnect == false)
        #expect(!AIAccountStore.precisaReconectar(URLError(.notConnectedToInternet)))
        #expect(!AIAccountStore.precisaReconectar(AgentError.http(503, "")))
    }

    @Test func refreshRecusadoDesconecta() async throws {
        let http = FakeHTTP()
        http.enqueue("https://platform.claude.com/v1/oauth/token", 400, #"{"error":"invalid_grant"}"#)
        let (store, a, s) = try conta(http)
        await #expect(throws: AgentError.invalidGrant) { try await s.refreshNow() }
        await esperarAtualizacao(store, a) { $0.needsReconnect }
        #expect(store.accounts.first { $0.id == a.id }?.needsReconnect == true)
        #expect(AIAccountStore.precisaReconectar(AgentError.http(401, "")))
    }
}

struct CapacidadesTests {
    @Test func aprendeTetoEEsforcoDaMensagem() {
        #expect(Aprendizado.limiteDeSaida(
            "max_tokens: 128000 > 64000, which is the maximum allowed number of output tokens for claude-haiku-4-5"
        ) == 64000)
        // O corpo inteiro do 400, como a OpenAI manda: é o `param` que diz de onde é o erro.
        let c = Aprendizado.aprender(
            #"{"error":{"message":"Unsupported value: 'max' is not supported with the 'gpt-6-sol' model. Supported values are: 'low', 'medium', 'high', and 'xhigh'.","type":"invalid_request_error","param":"reasoning.effort","code":"unsupported_value"}}"#,
            familia: .openai,
            cap: Capacidades(),
            mandado: PedidoMandado(nivel: "max")
        )
        #expect(c?.esforcos == ["low", "medium", "high", "xhigh"])
        // Endpoint antigo que só conhece `enabled`: vai para orçamento, não para "sem thinking".
        let d = Aprendizado.aprender(
            "thinking.type: Input should be 'enabled' or 'disabled'",
            familia: .anthropic,
            cap: Capacidades(),
            mandado: PedidoMandado(pensamento: .adaptativo)
        )
        #expect(d?.pensamento == .orcamento)
        let e = Aprendizado.aprender(
            "thinking.adaptive.display: Extra inputs are not permitted",
            familia: .anthropic,
            cap: Capacidades(),
            mandado: PedidoMandado(pensamento: .adaptativo, campos: ["display", "block_binding"])
        )
        #expect(e?.recusados == ["display"] && e?.pensamento == nil)
    }

    /// Modelo sem esforço nenhum: o campo sai de vez, em vez de ir tirando nível a nível.
    @Test func campoDesconhecidoZeraOEsforco() {
        let c = Aprendizado.aprender(
            #"{"error":{"message":"Unrecognized request argument supplied: reasoning_effort","param":null}}"#,
            familia: .openai,
            cap: Capacidades(),
            mandado: PedidoMandado(nivel: "medium")
        )
        #expect(c?.esforcos == [])
        let d = Aprendizado.aprender(
            "output_config.effort: 'xhigh' is not supported for this model",
            familia: .anthropic,
            cap: Capacidades(esforcos: ["low", "medium", "high", "xhigh"]),
            mandado: PedidoMandado(nivel: "xhigh")
        )
        #expect(d?.esforcos == ["low", "medium", "high"])
    }

    /// Provedor que declara querer o raciocínio de volta (models.dev `interleaved`) recebe
    /// o texto dele na mensagem com as chamadas.
    @Test func raciocinioVoltaNoCampoDoCompativel() throws {
        var o = ChatCompletionsStream.Opcoes()
        o.campoDoRaciocinio = "reasoning_content"
        let t = TurnRequest(
            system: "s",
            messages: [
                .user("oi"),
                AgentMessage(
                    role: .assistant,
                    content: "",
                    thinking: "vou ler",
                    toolCalls: [ToolCall(id: "c1", name: "read_file", arguments: #"{"path":"a"}"#)]
                ),
                .tool("c1", "x"),
            ],
            tools: [],
            model: "deepseek-v4"
        )
        let m = try #require(ChatCompletionsStream.body(t, o).corpo["messages"] as? [[String: Any]])
        #expect(m[2]["reasoning_content"] as? String == "vou ler")
        let semCampo = try #require(ChatCompletionsStream.body(t).corpo["messages"] as? [[String: Any]])
        #expect(semCampo[2]["reasoning_content"] == nil)
    }

    @Test func esforcoVemDaCapacidadeNaoDoNome() {
        let r = RegistroDeCapacidades(arquivo: nil)
        // Sem ninguém dizer nada: os níveis mais novos da família.
        #expect(Effort.options(kind: .claude, model: "claude-opus-6", fromAPI: nil, registro: r, catalogo: nil) ==
            ["low", "medium", "high", "xhigh", "max"])
        #expect(Effort.options(kind: .codex, model: "gpt-6-sol", fromAPI: nil, registro: r, catalogo: nil) ==
            ["low", "medium", "high", "xhigh", "max"])
        #expect(Effort.options(kind: .grok, model: "grok-5", fromAPI: nil, registro: r, catalogo: nil) ==
            ["low", "medium", "high", "xhigh"])
        // Um 400 disse que o modelo não tem esforço: some da tela.
        r.atualizar(.grok, "grok-composer-2.5-fast", com: Capacidades(esforcos: []))
        #expect(Effort.options(kind: .grok, model: "grok-composer-2.5-fast", fromAPI: nil, registro: r, catalogo: nil)
            .isEmpty)
        #expect(Effort.options(kind: .apple, model: "apple-on-device").isEmpty)
        #expect(Effort.nivel("max", aceitos: ["low", "medium", "high", "xhigh"]) == "xhigh")
        #expect(Effort.nivel("minimal", aceitos: ["low", "high"]) == "low")
        #expect(Effort.ordenar(["ultra", "high", "low"]) == ["low", "high", "ultra"])
    }

    @Test func limitesVemDoCatalogoQuandoAAPINaoDisse() async {
        let fake = FakeHTTP()
        fake.enqueue("https://models.dev/api.json", 200, #"""
        {"openai":{"id":"openai","models":{"gpt-6-sol":{"id":"gpt-6-sol","reasoning":true,
          "reasoning_options":[{"type":"effort","values":["low","medium","high","xhigh","max"]}],
          "limit":{"context":1050000,"output":256000}}}},
         "openrouter":{"id":"openrouter","models":{"anthropic/claude-sonnet-5":{"reasoning":true,
          "limit":{"context":1000000,"output":128000}}}}}
        """#)
        let catalogo = CatalogoDeModelos(pasta: nil, http: fake)
        let r = RegistroDeCapacidades(arquivo: nil)
        let a = await LimitesDosModelos.limites(provider: .codex, model: "gpt-6-sol", registro: r, catalogo: catalogo)
        #expect(a.contexto == 1_050_000 && a.saida == 256_000)
        // Id de compatível com prefixo de fornecedor também acha.
        let b = await LimitesDosModelos.limites(
            provider: .openaiCompat,
            model: "anthropic/claude-sonnet-5",
            registro: r,
            catalogo: catalogo
        )
        #expect(b.contexto == 1_000_000)
        #expect(fake.count == 1) // baixado uma vez só
        let nada = await LimitesDosModelos.limites(provider: .claude, model: "nao-existe", registro: r, catalogo: catalogo)
        #expect(nada.contexto == nil && nada.saida == nil)
    }

    @Test func appleDevolveAJanelaDoAparelho() async {
        let l = await LimitesDosModelos.limites(provider: .apple, model: AppleProvider.idLocal)
        #expect(l.contexto == AppleProvider.janela && l.saida == AppleProvider.respostaComFerramentas)
        let n = await LimitesDosModelos.limites(provider: .apple, model: AppleProvider.idNuvem)
        #expect(n.contexto == AppleProvider.janelaDaNuvem)
    }
}

/// O laço guarda o raciocínio do provedor e entrega ao modelo o problema da chamada.
struct LacoComProvedorTests {
    init() {
        Texto.escolher(.ptBR)
    }

    @Test func raciocinioEProblemaChegamAoHistorico() async throws {
        let root = try tmpProject()
        let host = TestHost(root: root)
        let bruto = RaciocinioBruto(formato: "anthropic", origem: "claude@x", modelo: "m", json: "[]")
        let cortada = ToolCall(
            id: "c1",
            name: "write_file",
            arguments: #"{"path":"a.txt","content":"pela met"#,
            problema: Cortes.chamadaCortada("write_file")
        )
        let p = FakeProvider([
            [.raciocinio(bruto), .tools([cortada]), .done],
            [.text("Vou dividir."), .done],
        ])
        let loop = AgentLoop(provider: p, host: host, patches: PatchStore(root: root))
        let r = await runAll(loop, "escreve", LoopConfig(mode: .build, permit: .full, model: "m"))
        let assistente = try #require(r.history.first { $0.role == .assistant && $0.toolCalls != nil })
        #expect(assistente.raciocinio == bruto)
        let resultado = try #require(r.history.first { $0.role == .tool })
        #expect(resultado.content == Cortes.chamadaCortada("write_file"))
        #expect((try? String(contentsOf: root.appending(path: "a.txt"), encoding: .utf8)) == "a\nb\nc\n")
        // E a segunda rodada vai ao provedor com o raciocínio junto da mensagem.
        let segunda = p.turns.withLock { $0[1] }
        #expect(segunda.messages.contains { $0.raciocinio == bruto })
    }
}
