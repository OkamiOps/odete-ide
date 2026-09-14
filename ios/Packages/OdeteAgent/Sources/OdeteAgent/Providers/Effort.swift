import Foundation

/// Níveis de esforço por modelo, portado do web.
public enum Effort {
    public static let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
    public static let labels = [
        "none": "None",
        "minimal": "Min",
        "low": "Low",
        "medium": "Mid",
        "high": "High",
        "xhigh": "Extra",
        "max": "Max",
    ]

    public static func options(kind: ProviderKind, model: String, fromAPI: [String]? = nil) -> [String] {
        if let f = fromAPI, !f.isEmpty {
            return order.filter { f.contains($0) }
        }
        let id = model.lowercased()
        guard !id.isEmpty else { return [] }
        func has(_ p: String) -> Bool {
            id.range(of: p, options: .regularExpression) != nil
        }
        switch kind {
        // O modelo do sistema não tem nível de esforço.
        case .apple: return []
        case .grok:
            if has("non[-_]?reasoning|imagine|image|tts|video|composer") {
                return []
            }
            if has("4\\.6|4-6|4\\.20|4-20|multi-agent|grok-build") {
                return ["low", "medium", "high", "xhigh"]
            }
            if has("4\\.5|4-5") {
                return ["low", "medium", "high"]
            }
            if has("4\\.3|4-3") {
                return ["none", "low", "medium", "high"]
            }
            if has("reasoning") {
                return ["low", "high"]
            }
            if has("grok-4|grok-3-mini|grok-code") {
                return ["low", "medium", "high"]
            }
            return []
        case .claude, .anthropicCompat:
            if has("haiku|instant") {
                return []
            }
            if has("opus-5|fable|mythos|sonnet-5|opus-4\\.[678]|sonnet-4\\.6|opus-4-[678]|sonnet-4-6") {
                return [
                    "low",
                    "medium",
                    "high",
                    "xhigh",
                    "max",
                ]
            }
            if has("sonnet-4|opus-4|claude-4") {
                return ["low", "medium", "high"]
            }
            return []
        case .codex, .openaiCompat:
            if has("chat-latest"), !has("codex") {
                return []
            }
            if has("gpt-5\\.2-pro|gpt-5-pro") {
                return has("5\\.2") ? ["medium", "high", "xhigh"] : ["high"]
            }
            if has("gpt-5\\.2|gpt-5\\.6|gpt-6|gpt-5\\.5|gpt-5\\.4") {
                return has("codex") ? [
                    "low",
                    "medium",
                    "high",
                    "xhigh",
                ] : ["none", "low", "medium", "high", "xhigh"]
            }
            if has("gpt-5\\.1") {
                return has("codex-max") ? ["low", "medium", "high", "xhigh"] : has("codex") ? [
                    "low",
                    "medium",
                    "high",
                ] : ["none", "low", "medium", "high"]
            }
            if has("gpt-5") {
                return has("codex") ? ["low", "medium", "high"] : ["minimal", "low", "medium", "high"]
            }
            if has("(^|[^a-z])o[1-4]([^0-9]|$)") {
                return ["low", "medium", "high"]
            }
            return []
        }
    }

    public static func defaultOption(_ options: [String]) -> String {
        if options.isEmpty {
            return ""
        }
        if options.contains("medium") {
            return "medium"
        }
        if options.contains("high") {
            return "high"
        }
        return options[(options.count - 1) / 2]
    }

    /// Esforço para a API OpenAI (`reasoning_effort` / `reasoning.effort`).
    static func openai(_ e: String) -> String? {
        let x = e.lowercased().trimmingCharacters(in: .whitespaces)
        if x.isEmpty || x == "none" {
            return nil
        }
        return x == "minimal" ? "low" : x == "max" ? "xhigh" : x
    }

    /// Esforço para Anthropic: budget de thinking, max_tokens e nível.
    static func anthropic(_ e: String) -> (budget: Int, maxTokens: Int, level: String)? {
        switch e.lowercased().trimmingCharacters(in: .whitespaces) {
        case "", "none": nil
        case "minimal", "low": (1024, 4000, "low")
        case "medium": (4096, 9000, "medium")
        case "high": (8192, 14000, "high")
        default: (16000, 24000, "max")
        }
    }
}
