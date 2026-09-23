import Foundation
import OdeteI18n

/// Os tipos de conta de IA. `apple` é o modelo do próprio sistema e não tem conta.
public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case apple, claude, codex, grok, openaiCompat, anthropicCompat
    public var id: String {
        rawValue
    }

    public enum AuthStyle: Sendable { case oauthPaste, deviceCode, apiKey, builtIn }

    public var label: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        case .openaiCompat: "OpenAI-compatível"
        case .anthropicCompat: "Anthropic-compatível"
        }
    }

    /// A linha de baixo da conta nos Ajustes e no seletor — texto de tela, traduzido.
    public var vendor: String {
        switch self {
        case .apple: tr("no aparelho")
        case .claude: tr("Anthropic · assinatura Pro/Max")
        case .codex: tr("OpenAI · conta ChatGPT")
        case .grok: "xAI · SuperGrok / X Premium"
        case .openaiCompat: tr("chave de API e URL base")
        case .anthropicCompat: tr("chave de API e URL base")
        }
    }

    public var authStyle: AuthStyle {
        switch self {
        case .apple: .builtIn
        case .claude: .oauthPaste
        case .codex, .grok: .deviceCode
        case .openaiCompat, .anthropicCompat: .apiKey
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .apple: ""
        case .claude, .anthropicCompat: "https://api.anthropic.com"
        case .codex: "https://chatgpt.com/backend-api/codex"
        case .grok: "https://cli-chat-proxy.grok.com/v1"
        case .openaiCompat: "https://api.openai.com/v1"
        }
    }

    public var symbol: String {
        switch self {
        case .apple: "apple.logo"
        case .claude: "sparkle"
        case .codex: "circle.hexagongrid"
        case .grok: "xmark.circle"
        case .openaiCompat, .anthropicCompat: "key"
        }
    }

    public var defaultModel: String {
        switch self {
        case .apple: "apple-on-device"
        case .claude, .anthropicCompat: "claude-sonnet-5"
        case .codex: "gpt-5.4-codex"
        case .grok: "grok-4.6"
        case .openaiCompat: "gpt-5.4"
        }
    }
}

/// Tokens de uma conta OAuth. Só vivem no Keychain.
public struct TokenBundle: Sendable, Equatable, Codable {
    public var access: String
    public var refresh: String
    public var expiresAt: Date
    public var accountId: String?
    public init(access: String, refresh: String, expiresAt: Date, accountId: String? = nil) {
        self.access = access; self.refresh = refresh; self.expiresAt = expiresAt; self.accountId = accountId
    }
}

/// Uma conta de IA. Segredos ficam no Keychain sob `keychainPrefix`.
public struct AIAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ProviderKind
    public var label: String
    public var baseURL: String
    public var login: String
    public var accountId: String?
    public var expiresAt: Date?
    public var needsReconnect: Bool
    public var addedAt: Date

    public init(
        id: UUID = UUID(),
        kind: ProviderKind,
        label: String? = nil,
        baseURL: String? = nil,
        login: String = "",
        accountId: String? = nil,
        expiresAt: Date? = nil,
        needsReconnect: Bool = false,
        addedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.label = label ?? kind.label
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.login = login
        self.accountId = accountId
        self.expiresAt = expiresAt
        self.needsReconnect = needsReconnect
        self.addedAt = addedAt
    }

    public var keychainPrefix: String {
        "ai:\(id.uuidString)"
    }
}
