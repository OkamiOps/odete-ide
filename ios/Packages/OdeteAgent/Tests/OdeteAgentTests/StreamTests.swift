import Foundation
@testable import OdeteAgent
import Testing

func fixture(_ name: String) -> String {
    let u = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appending(path: name)
    return try! String(contentsOf: u, encoding: .utf8)
}

func collect(_ s: AsyncThrowingStream<StreamEvent, Error>) async throws
    -> (think: String, text: String, tools: [ToolCall], use: TokenUse, done: Bool)
{
    var think = "", text = "", tools: [ToolCall] = [], use = TokenUse(), done = false
    for try await e in s {
        switch e {
        case let .think(t): think += t
        case let .text(t): text += t
        case let .tools(c): tools = c
        case let .usage(u): use = use.filled(with: u)
        case .done: done = true
        case let .error(m): Issue.record("erro: \(m)")
        }
    }
    return (think, text, tools, use, done)
}

struct StreamTests {
    @Test func chatCompletions() async throws {
        let r = try await collect(ChatCompletionsStream.events(SSE.data(fromText: fixture("chat.sse"))))
        #expect(r.think == "pensando " && r.text == "Olá, mundo" && r.done)
        #expect(r.tools == [ToolCall(id: "call_1", name: "read_file", arguments: #"{"path":"a.txt"}"#)])
        #expect(r.use == TokenUse(input: 120, output: 30, cache: 100, reasoning: 5))
    }

    @Test func anthropicMessages() async throws {
        let r = try await collect(MessagesStream.events(SSE.data(fromText: fixture("messages.sse"))))
        #expect(r.think == "vou ler" && r.text == "Lendo o arquivo." && r.done)
        #expect(r.tools.count == 1 && r.tools[0].id == "toolu_1" && r.tools[0].args["path"] as? String == "a.txt")
        #expect(r.use == TokenUse(input: 200, output: 40, cache: 50))
    }

    @Test func openaiResponses() async throws {
        let r = try await collect(ResponsesStream.events(SSE.data(fromText: fixture("responses.sse"))))
        #expect(r.think == "analisando" && r.text == "Vou abrir." && r.done)
        #expect(r.tools == [ToolCall(id: "call_9", name: "read_file", arguments: #"{"path":"a.txt"}"#)])
        #expect(r.use == TokenUse(input: 300, output: 20, cache: 10, reasoning: 7))
    }

    @Test func historyConversions() throws {
        let hist: [AgentMessage] = [
            .user("oi", images: [AgentImage(mime: "image/png", data: "AAA")]),
            AgentMessage(
                role: .assistant,
                content: "lendo",
                toolCalls: [ToolCall(id: "t1", name: "read_file", arguments: #"{"path":"a"}"#)]
            ),
            .tool("t1", "conteúdo"),
            AgentMessage(role: .assistant, content: "pronto"),
        ]
        let turn = TurnRequest(
            system: "sys",
            messages: hist,
            tools: [ToolSpec(name: "read_file", description: "lê", parameters: ["type": "object"])],
            model: "m",
            effort: "medium"
        )
        let cc = ChatCompletionsStream.body(turn, maxTokensKey: "max_tokens")
        let ccm = try #require(cc["messages"] as? [[String: Any]])
        #expect(ccm.count == 5 && ccm[0]["role"] as? String == "system" && (ccm[1]["content"] as? [[String: Any]])?
            .count == 2)
        #expect(ccm[3]["role"] as? String == "tool" && ccm[3]["tool_call_id"] as? String == "t1" &&
            cc["reasoning_effort"] as? String == "medium")
        let an = MessagesStream.body(turn)
        let anm = try #require(an["messages"] as? [[String: Any]])
        #expect(anm.count == 4 && an["system"] as? String == "sys")
        let toolResult = (anm[2]["content"] as? [[String: Any]])?.first
        #expect(anm[2]["role"] as? String == "user" && toolResult?["type"] as? String == "tool_result" &&
            toolResult?["tool_use_id"] as? String == "t1")
        #expect((an["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 4096 &&
            ((an["tools"] as? [[String: Any]])?.first?["input_schema"]) != nil)
        let rs = ResponsesStream.body(turn)
        let inp = try #require(rs["input"] as? [[String: Any]])
        #expect(inp[1]["role"] as? String == "assistant" && inp[2]["type"] as? String == "function_call" &&
            inp[2]["call_id"] as? String == "t1")
        #expect(inp[3]["type"] as? String == "function_call_output" &&
            (rs["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
        #expect((rs["tools"] as? [[String: Any]])?.first?["name"] as? String == "read_file")
    }

    @Test func effortTable() {
        #expect(Effort.options(kind: .claude, model: "claude-sonnet-5") == ["low", "medium", "high", "xhigh", "max"])
        #expect(Effort.options(kind: .claude, model: "claude-haiku-4-5").isEmpty)
        #expect(Effort.options(kind: .codex, model: "gpt-5.4-codex") == ["low", "medium", "high", "xhigh"])
        #expect(Effort.options(kind: .grok, model: "grok-4.6") == ["low", "medium", "high", "xhigh"])
        #expect(Effort.options(kind: .grok, model: "grok-composer-2.5-fast").isEmpty)
        #expect(Effort.defaultOption(["low", "high"]) == "high" && Effort.defaultOption([]) == "")
        #expect(Effort.anthropic("max")?.maxTokens == 24000 && Effort.openai("minimal") == "low" && Effort
            .openai("none") == nil)
    }

    @Test func modelListParsing() {
        let a = ModelList
            .parse(
                Data(#"{"data":[{"id":"claude-sonnet-5","display_name":"Claude Sonnet 5"},{"id":"claude-haiku-4-5"}]}"#
                    .utf8)
            )
        #expect(Set(a.map(\.id)) == ["claude-haiku-4-5", "claude-sonnet-5"] && a.first { $0.id == "claude-sonnet-5" }?
            .label == "Claude Sonnet 5")
        let b = ModelList
            .parse(
                Data(
                    #"{"models":[{"slug":"gpt-5.4-codex","title":"GPT-5.4 Codex","supported_reasoning_efforts":["high","low"],"context_window":400000},{"slug":"x","visibility":"hidden"}]}"#
                        .utf8
                )
            )
        #expect(b.count == 1 && b[0].efforts == ["low", "high"] && b[0].ctx == 400_000)
        #expect(ModelList.parse(Data("nada".utf8)).isEmpty && ModelList.grokCatalog.first?.id == "grok-4.6")
    }
}
