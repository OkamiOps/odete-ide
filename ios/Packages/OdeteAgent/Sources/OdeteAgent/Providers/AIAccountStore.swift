import Foundation
import Observation
import OdeteAccounts

/// Contas de IA (JSON em Application Support) com segredos no Keychain.
@MainActor
@Observable
public final class AIAccountStore {
    public private(set) var accounts: [AIAccount] = []
    private let url: URL
    public let secrets: any SecretStore
    private var sessions: [UUID: Session] = [:]

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Odete/ai-accounts.json")
    }

    public init(url: URL = AIAccountStore.defaultURL(), secrets: any SecretStore = Keychain()) {
        self.url = url
        self.secrets = secrets
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: url), let list = try? dec.decode([AIAccount].self, from: d) {
            accounts = list
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(accounts).write(to: url, options: .atomic)
    }

    /// Conta OAuth/device: guarda access e refresh no Keychain.
    public func add(_ account: AIAccount, tokens: TokenBundle) throws {
        var a = account
        a.expiresAt = tokens.expiresAt
        a.accountId = tokens.accountId ?? a.accountId
        a.needsReconnect = false
        try secrets.set(tokens.access, for: a.keychainPrefix + ":access")
        try secrets.set(tokens.refresh, for: a.keychainPrefix + ":refresh")
        upsert(a)
    }

    /// Conta por chave de API.
    public func add(_ account: AIAccount, apiKey: String) throws {
        try secrets.set(apiKey, for: account.keychainPrefix + ":key")
        upsert(account)
    }

    private func upsert(_ a: AIAccount) {
        accounts.removeAll { $0.id == a.id }
        accounts.append(a)
        sessions[a.id] = nil
        save()
    }

    public func remove(_ account: AIAccount) {
        for s in [":access", ":refresh", ":key"] {
            secrets.delete(account.keychainPrefix + s)
        }
        accounts.removeAll { $0.id == account.id }
        sessions[account.id] = nil
        save()
    }

    public func update(_ account: AIAccount) {
        accounts = accounts.map { $0.id == account.id ? account : $0 }
        save()
    }

    public func tokens(for account: AIAccount) -> TokenBundle? {
        guard let access = secrets.get(account.keychainPrefix + ":access") else { return nil }
        return TokenBundle(
            access: access,
            refresh: secrets.get(account.keychainPrefix + ":refresh") ?? "",
            expiresAt: account.expiresAt ?? .distantPast,
            accountId: account.accountId
        )
    }

    public func apiKey(for account: AIAccount) -> String? {
        secrets.get(account.keychainPrefix + ":key")
    }

    /// Sessão (com refresh) de uma conta; uma por conta.
    public func session(for account: AIAccount, http: HTTPClient = URLSessionClient()) -> Session {
        if let s = sessions[account.id] {
            return s
        }
        let s = Session(account: account, secrets: secrets, http: http) { [weak self] id, result in
            Task { @MainActor in
                guard let self, var a = self.accounts.first(where: { $0.id == id }) else { return }
                switch result {
                case let .success(t): a.expiresAt = t.expiresAt; a.accountId = t.accountId ?? a.accountId; a
                    .needsReconnect = false
                case .failure: a.needsReconnect = true
                }
                self.update(a)
            }
        }
        sessions[account.id] = s
        return s
    }

    public func accounts(of kind: ProviderKind) -> [AIAccount] {
        accounts.filter { $0.kind == kind }
    }
}

/// Token válido de uma conta, renovando com folga e uma renovação por vez.
public actor Session {
    public let account: AIAccount
    private let secrets: any SecretStore
    private let http: HTTPClient
    private let onChange: @Sendable (UUID, Result<TokenBundle, Error>) -> Void
    private var refreshing: Task<TokenBundle, Error>?
    public var leeway: TimeInterval = 300

    init(
        account: AIAccount,
        secrets: any SecretStore,
        http: HTTPClient,
        onChange: @escaping @Sendable (UUID, Result<TokenBundle, Error>) -> Void
    ) {
        self.account = account
        self.secrets = secrets
        self.http = http
        self.onChange = onChange
    }

    /// Bearer para a API: chave de API ou access token renovado.
    public func accessToken() async throws -> String {
        if account.kind.authStyle == .apiKey {
            guard let k = secrets.get(account.keychainPrefix + ":key"), !k.isEmpty else { throw AgentError.noAccount }
            return k
        }
        guard let access = secrets.get(account.keychainPrefix + ":access") else { throw AgentError.noAccount }
        let exp = account.expiresAt ?? .distantFuture
        let storedExp = secrets.get(account.keychainPrefix + ":expires").flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) } ?? exp
        if storedExp.timeIntervalSinceNow > leeway {
            return access
        }
        return try await refreshNow().access
    }

    /// Força a renovação (ex.: 401). Concorrentes esperam a mesma.
    public func refreshNow() async throws -> TokenBundle {
        if let t = refreshing {
            return try await t.value
        }
        let task = Task<TokenBundle, Error> { [account, secrets, http, onChange] in
            guard let refresh = secrets.get(account.keychainPrefix + ":refresh"),
                  !refresh.isEmpty else { throw AgentError.invalidGrant }
            do {
                let t: TokenBundle = switch account.kind {
                case .claude: try await ClaudeAuth(http: http).refresh(refresh)
                case .codex: try await OpenAIDeviceAuth(http: http).refresh(refresh)
                case .grok: try await GrokDeviceAuth(http: http).refresh(refresh)
                case .openaiCompat, .anthropicCompat: throw AgentError.noAccount
                }
                try secrets.set(t.access, for: account.keychainPrefix + ":access")
                try secrets.set(t.refresh, for: account.keychainPrefix + ":refresh")
                try secrets.set(String(t.expiresAt.timeIntervalSince1970), for: account.keychainPrefix + ":expires")
                onChange(account.id, .success(t))
                return t
            } catch {
                onChange(account.id, .failure(error))
                throw error
            }
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    public var accountId: String? {
        account.accountId
    }
}
