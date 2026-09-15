import Foundation
import OdeteI18n

/// Provedor concreto: conta + sessão + formato.
public struct HTTPProvider: Provider {
    public let kind: ProviderKind
    let account: AIAccount
    let session: Session
    let http: HTTPClient
    public static let grokClientVersion = "0.2.91"

    public init(account: AIAccount, session: Session, http: HTTPClient = URLSessionClient()) {
        kind = account.kind
        self.account = account
        self.session = session
        self.http = http
    }

    var base: String {
        account.baseURL.hasSuffix("/") ? String(account.baseURL.dropLast()) : account.baseURL
    }

    func headers(token: String, conversationId: String = "") -> [String: String] {
        switch kind {
        // Nunca chega aqui: conta da Apple é atendida pelo AppleProvider.
        case .apple: return [:]
        case .claude: return [
                "Authorization": "Bearer \(token)",
                "anthropic-version": "2023-06-01",
                "anthropic-beta": "oauth-2025-04-20,claude-code-20250219",
            ]
        case .anthropicCompat: return ["x-api-key": token, "anthropic-version": "2023-06-01"]
        case .codex:
            var h = ["Authorization": "Bearer \(token)", "originator": "codex_cli_rs", "OpenAI-Beta": "responses=v1"]
            if let id = account.accountId {
                h["ChatGPT-Account-ID"] = id
            }
            return h
        case .grok:
            var h = [
                "Authorization": "Bearer \(token)",
                "User-Agent": "grok-pager/\(Self.grokClientVersion) grok-shell/\(Self.grokClientVersion) (ipados; aarch64)",
                "x-grok-client-identifier": "grok-pager",
                "x-grok-client-version": Self.grokClientVersion,
            ]
            if !conversationId.isEmpty {
                h["x-grok-conv-id"] = conversationId
            }
            return h
        case .openaiCompat: return ["Authorization": "Bearer \(token)"]
        }
    }

    public func stream(_ turn: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                do {
                    var token = try await session.accessToken()
                    var lines: AsyncThrowingStream<String, Error>
                    do { lines = try await open(turn, token: token) } catch AgentError.auth {
                        // 401: renova uma vez e tenta de novo
                        token = try await session.refreshNow().access
                        lines = try await open(turn, token: token)
                    }
                    let events: AsyncThrowingStream<StreamEvent, Error> = switch kind {
                    case .apple, .claude, .anthropicCompat: MessagesStream.events(lines)
                    case .grok: ResponsesStream.events(lines)
                    case .codex: ResponsesStream.events(lines)
                    case .openaiCompat: ChatCompletionsStream.events(lines)
                    }
                    for try await e in events {
                        if Task.isCancelled {
                            break
                        }; cont.yield(e)
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }

    func open(_ turn: TurnRequest, token: String) async throws -> AsyncThrowingStream<String, Error> {
        var h = headers(token: token, conversationId: turn.conversationId)
        let url: URL
        let body: [String: Any]
        switch kind {
        case .apple, .claude, .anthropicCompat:
            url = URL(string: base + "/v1/messages")!; body = MessagesStream.body(turn)
        case .grok:
            url = URL(string: base + "/responses")!; body = ResponsesStream.body(turn)
            h["x-grok-model-override"] = turn.model
        case .codex:
            // O backend do Codex só atende a API de Responses. Em /chat/completions ele
            // devolve 404 com {"detail":"Not Found"}, que era o erro que aparecia.
            url = URL(string: base + "/responses")!
            var b = ResponsesStream.body(turn)
            b["include"] = ["reasoning.encrypted_content"]
            // Esse backend recusa max_output_tokens com 400; quem manda no limite é ele.
            b.removeValue(forKey: "max_output_tokens")
            body = b
        case .openaiCompat: url = URL(string: base + "/chat/completions")!; body = ChatCompletionsStream.body(
                turn,
                maxTokensKey: "max_tokens"
            )
        }
        return try await openSSE(http, url: url, headers: h, body: body)
    }

    public func models() async throws -> [ModelInfo] {
        let token = try await session.accessToken()
        let h = headers(token: token)
        let urls: [String] = switch kind {
        case .apple, .claude, .anthropicCompat: [base + "/v1/models?limit=100"]
        case .codex: [
                "https://chatgpt.com/backend-api/codex/models?client_version=0.145.0",
                "https://chatgpt.com/backend-api/codex/models",
            ]
        case .grok: [base + "/models"]
        case .openaiCompat: [base + "/models"]
        }
        var lastStatus = 0
        for u in urls {
            var req = URLRequest(url: URL(string: u)!)
            for (k, v) in h {
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await http.data(for: req) else { continue }
            lastStatus = resp.statusCode
            guard (200 ..< 300).contains(resp.statusCode) else { continue }
            let list = ModelList.parse(data)
            if !list.isEmpty {
                return list
            }
        }
        if kind == .grok {
            return ModelList.grokCatalog
        }
        throw AgentError.http(lastStatus, tr("não devolveu modelos"))
    }
}

enum ModelList {
    static let grokCatalog: [ModelInfo] = [
        ModelInfo(id: "grok-4.6", label: "Grok 4.6", ctx: 1_000_000), ModelInfo(
            id: "grok-4.5",
            label: "Grok 4.5",
            ctx: 1_000_000
        ),
        ModelInfo(id: "grok-4.3", label: "Grok 4.3", ctx: 1_000_000), ModelInfo(
            id: "grok-build",
            label: "Grok Build",
            ctx: 500_000
        ),
        ModelInfo(id: "grok-composer-2.5-fast", label: "Grok Composer 2.5 Fast", ctx: 200_000),
    ]

    /// Aceita `data`, `models`, `items` ou `model_slugs` (lista ou dicionário).
    static func parse(_ data: Data) -> [ModelInfo] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var raw: Any? = (root as? [String: Any])
            .flatMap { $0["data"] ?? $0["models"] ?? $0["items"] ?? $0["model_slugs"] } ?? (root as? [Any])
        if let dict = raw as? [String: Any] {
            raw = dict.map { k, v in
                var d = (v as? [String: Any]) ?? [:]; d["slug"] = k; return d
            }
        }
        var out: [ModelInfo] = []
        var seen: Set<String> = []
        for item in (raw as? [Any]) ?? [] {
            if let s = item as? String {
                if seen.insert(s).inserted {
                    out.append(ModelInfo(id: s))
                }; continue
            }
            guard let m = item as? [String: Any] else { continue }
            let vis = "\(m["visibility"] ?? m["hidden"] ?? "")"
            if vis == "hidden" || vis == "1" || vis == "true" {
                continue
            }
            guard let id = ((m["slug"] ?? m["id"] ?? m["model"] ?? m["name"]) as? String)?
                .trimmingCharacters(in: .whitespaces), !id.isEmpty, seen.insert(id).inserted else { continue }
            let label = ((m["display_name"] ?? m["displayName"] ?? m["title"] ?? m["name"]) as? String) ?? id
            let cap = (m["capabilities"] as? [String: Any]) ?? [:]
            let ctxRaw = m["context_window"] ?? m["context_length"] ?? m["max_input_tokens"] ?? m[
                "input_token_limit"
            ] ??
                cap["context_window"] ?? cap["context_length"]
            let ctx = (ctxRaw as? Int) ?? Int((ctxRaw as? Double) ?? 0)
            var efforts: [String] = []
            for key in ["supported_reasoning_efforts", "reasoning_efforts", "efforts"] {
                if let l = m[key] as? [String] {
                    efforts = Effort.order.filter { l.contains($0) }
                }
            }
            out.append(ModelInfo(
                id: id,
                label: label,
                efforts: efforts.isEmpty ? nil : efforts,
                ctx: ctx > 1000 ? ctx : nil
            ))
        }
        return out.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}
