import Foundation

/// Uma imagem anexada pelo usuário (base64).
public struct AgentImage: Codable, Sendable, Hashable {
    public var mime: String
    public var data: String
    public init(mime: String, data: String) {
        self.mime = mime; self.data = data
    }
}

public struct ToolCall: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: String
    public init(id: String, name: String, arguments: String) {
        self.id = id; self.name = name; self.arguments = arguments
    }

    public var args: [String: Any] {
        jsonObject(Data(arguments.utf8))
    }
}

/// Mensagem do histórico, no formato neutro que cada adaptador converte.
public struct AgentMessage: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public var role: Role
    public var content: String
    public var thinking: String?
    public var images: [AgentImage]?
    public var toolCalls: [ToolCall]?
    public var toolCallId: String?

    public init(
        role: Role,
        content: String,
        thinking: String? = nil,
        images: [AgentImage]? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil
    ) {
        self.role = role; self.content = content; self.thinking = thinking; self.images = images; self
            .toolCalls = toolCalls; self.toolCallId = toolCallId
    }

    public static func user(_ text: String, images: [AgentImage]? = nil) -> AgentMessage {
        .init(
            role: .user,
            content: text,
            images: images?.isEmpty == false ? images : nil
        )
    }

    public static func tool(_ id: String, _ text: String) -> AgentMessage {
        .init(
            role: .tool,
            content: text,
            toolCallId: id
        )
    }
}

public struct TokenUse: Codable, Sendable, Hashable {
    public var input = 0, output = 0, cache = 0, reasoning = 0
    public init(input: Int = 0, output: Int = 0, cache: Int = 0, reasoning: Int = 0) {
        self.input = input; self.output = output; self.cache = cache; self.reasoning = reasoning
    }

    public var isEmpty: Bool {
        input == 0 && output == 0 && cache == 0 && reasoning == 0
    }

    public static func + (a: TokenUse, b: TokenUse) -> TokenUse {
        .init(
            input: a.input + b.input,
            output: a.output + b.output,
            cache: a.cache + b.cache,
            reasoning: a.reasoning + b.reasoning
        )
    }

    /// Preenche só o que ainda está zerado (streams mandam usage parcial).
    public func filled(with n: TokenUse) -> TokenUse {
        .init(
            input: n.input > 0 ? n.input : input,
            output: n.output > 0 ? n.output : output,
            cache: n.cache > 0 ? n.cache : cache,
            reasoning: n.reasoning > 0 ? n.reasoning : reasoning
        )
    }

    /// Lê `usage` no formato OpenAI ou Anthropic.
    static func pick(_ json: [String: Any]) -> TokenUse? {
        let u = (json["usage"] as? [String: Any]) ?? (
            (json["message"] as? [String: Any])?["usage"] as? [String: Any]
        ) ??
            ((json["response"] as? [String: Any])?["usage"] as? [String: Any])
        guard let u else { return nil }
        let det = (u["prompt_tokens_details"] as? [String: Any]) ?? (u["input_tokens_details"] as? [String: Any]) ?? [:]
        let out = (u["output_tokens_details"] as? [String: Any]) ?? (
            u["completion_tokens_details"] as? [String: Any]
        ) ??
            [:]
        func n(_ v: Any?) -> Int {
            (v as? Int) ?? Int((v as? Double) ?? 0)
        }
        let t = TokenUse(
            input: n(u["prompt_tokens"] ?? u["input_tokens"]),
            output: n(u["completion_tokens"] ?? u["output_tokens"]),
            cache: n(det["cached_tokens"] ?? u["cache_read_input_tokens"] ?? u["cached_tokens"]),
            reasoning: n(out["reasoning_tokens"] ?? u["reasoning_tokens"])
        )
        return t.isEmpty ? nil : t
    }
}

public enum StreamEvent: Sendable, Equatable {
    case think(String), text(String), tools([ToolCall]), usage(TokenUse), error(String), done
}

/// Ferramenta no formato neutro (schema JSON como dicionário).
public struct ToolSpec: Sendable, Hashable {
    public var name: String
    public var description: String
    /// Schema JSON serializado (Any não é Sendable).
    public var parametersJSON: String
    public init(name: String, description: String, parameters: [String: Any]) {
        self.name = name
        self.description = description
        parametersJSON = String(
            decoding: (try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])) ??
                Data("{}".utf8),
            as: UTF8.self
        )
    }

    public var parameters: [String: Any] {
        jsonObject(Data(parametersJSON.utf8))
    }
}

public struct TurnRequest: Sendable {
    public var system: String
    public var messages: [AgentMessage]
    public var tools: [ToolSpec]
    public var model: String
    public var effort: String
    public var conversationId: String
    public init(
        system: String,
        messages: [AgentMessage],
        tools: [ToolSpec],
        model: String,
        effort: String = "",
        conversationId: String = ""
    ) {
        self.system = system; self.messages = messages; self.tools = tools; self.model = model; self
            .effort = effort; self.conversationId = conversationId
    }
}

public struct ModelInfo: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var label: String
    public var efforts: [String]?
    public var ctx: Int?
    public init(id: String, label: String? = nil, efforts: [String]? = nil, ctx: Int? = nil) {
        self.id = id; self.label = label ?? id; self.efforts = efforts; self.ctx = ctx
    }
}

/// Um provedor: streama um turno e lista modelos.
public protocol Provider: Sendable {
    var kind: ProviderKind { get }
    func stream(_ turn: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error>
    func models() async throws -> [ModelInfo]
}
