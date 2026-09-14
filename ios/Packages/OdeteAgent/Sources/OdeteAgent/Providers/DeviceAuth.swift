import Foundation

/// Início de um device flow: o que mostrar ao usuário e o handle para o poll.
public struct DeviceStart: Sendable, Equatable {
    public var userCode: String
    public var verificationURL: URL
    public var interval: Int
    public var expiresIn: Int
    public var handle: String
}

public enum PollResult: Sendable, Equatable { case pending, slowDown, tokens(TokenBundle) }

public protocol DeviceAuth: Sendable {
    func start() async throws -> DeviceStart
    func poll(_ start: DeviceStart) async throws -> PollResult
    func refresh(_ refresh: String) async throws -> TokenBundle
}

/// Device connection da conta ChatGPT (o mesmo do Codex CLI).
public struct OpenAIDeviceAuth: DeviceAuth {
    public static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let userCodeURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
    static let pollURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let redirect = "https://auth.openai.com/deviceauth/callback"
    public static let verifyURL = URL(string: "https://auth.openai.com/codex/device")!

    let http: HTTPClient
    public init(http: HTTPClient = URLSessionClient()) {
        self.http = http
    }

    public func start() async throws -> DeviceStart {
        let (data, resp) = try await http.data(for: .json(Self.userCodeURL, body: ["client_id": Self.clientId]))
        guard (200 ..< 300).contains(resp.statusCode) else {
            throw AgentError.auth("device \(resp.statusCode). Ative \"Device code\" em ChatGPT → Ajustes → Segurança.")
        }
        let j = jsonObject(data)
        guard let code = (j["user_code"] as? String) ?? (j["usercode"] as? String),
              let id = j["device_auth_id"] as? String
        else {
            throw AgentError.auth("resposta incompleta do device auth")
        }
        return DeviceStart(
            userCode: code,
            verificationURL: Self.verifyURL,
            interval: max(2, (j["interval"] as? Int) ?? 5),
            expiresIn: (j["expires_in"] as? Int) ?? 900,
            handle: id
        )
    }

    public func poll(_ s: DeviceStart) async throws -> PollResult {
        let (data, resp) = try await http.data(for: .json(
            Self.pollURL,
            body: ["device_auth_id": s.handle, "user_code": s.userCode]
        ))
        if resp.statusCode == 403 || resp.statusCode == 404 {
            return .pending
        }
        guard (200 ..< 300).contains(resp.statusCode) else { throw AgentError.http(
            resp.statusCode,
            String(decoding: data, as: UTF8.self)
        ) }
        let j = jsonObject(data)
        guard let code = j["authorization_code"] as? String,
              let verifier = j["code_verifier"] as? String else { return .pending }
        let (td, tr) = try await http.data(for: .form(Self.tokenURL, body: [
            "grant_type": "authorization_code", "client_id": Self.clientId, "code": code, "code_verifier": verifier,
            "redirect_uri": Self.redirect,
        ]))
        return try .tokens(Self.tokens(td, tr, fallbackRefresh: ""))
    }

    public func refresh(_ refresh: String) async throws -> TokenBundle {
        let (d, r) = try await http.data(for: .form(
            Self.tokenURL,
            body: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": Self.clientId]
        ))
        return try Self.tokens(d, r, fallbackRefresh: refresh)
    }

    static func tokens(_ data: Data, _ resp: HTTPURLResponse, fallbackRefresh: String) throws -> TokenBundle {
        let body = String(decoding: data, as: UTF8.self)
        guard (200 ..< 300).contains(resp.statusCode) else {
            if body.contains("invalid_grant") {
                throw AgentError.invalidGrant
            }
            throw AgentError.http(resp.statusCode, body)
        }
        let j = jsonObject(data)
        guard let access = j["access_token"] as? String else { throw AgentError.auth("ChatGPT não devolveu token") }
        let exp = (j["expires_in"] as? Double) ?? 3600
        return TokenBundle(
            access: access,
            refresh: (j["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackRefresh,
            expiresAt: Date(timeIntervalSinceNow: exp),
            accountId: accountId(access: access, idToken: j["id_token"] as? String)
        )
    }

    /// `chatgpt_account_id` do claim `https://api.openai.com/auth`.
    static func accountId(access: String, idToken: String?) -> String? {
        for t in [idToken, access].compactMap(\.self) {
            let c = PKCE.jwtClaims(t)
            if let a = c["https://api.openai.com/auth"] as? [String: Any], let id = a["chatgpt_account_id"] as? String,
               !id.isEmpty
            {
                return id
            }
            if let id = c["chatgpt_account_id"] as? String, !id.isEmpty {
                return id
            }
        }
        return nil
    }
}

/// Device code RFC 8628 em auth.x.ai com o client público do Grok CLI.
public struct GrokDeviceAuth: DeviceAuth {
    public static let clientId = "b1a00492-073a-47ea-816f-4c329264a828"
    public static let scope = "openid profile email offline_access grok-cli:access api:access"
    static let deviceURL = URL(string: "https://auth.x.ai/oauth2/device/code")!
    static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!

    let http: HTTPClient
    public init(http: HTTPClient = URLSessionClient()) {
        self.http = http
    }

    public func start() async throws -> DeviceStart {
        let (data, resp) = try await http.data(for: .form(
            Self.deviceURL,
            body: ["client_id": Self.clientId, "scope": Self.scope]
        ))
        guard (200 ..< 300).contains(resp.statusCode) else { throw AgentError.http(
            resp.statusCode,
            String(decoding: data, as: UTF8.self)
        ) }
        let j = jsonObject(data)
        guard let dc = j["device_code"] as? String, let uc = j["user_code"] as? String,
              let v = (j["verification_uri_complete"] as? String) ?? (j["verification_uri"] as? String),
              let url = URL(string: v)
        else { throw AgentError.auth("xAI não devolveu device_code, user_code e verification_uri") }
        return DeviceStart(
            userCode: uc,
            verificationURL: url,
            interval: max(2, (j["interval"] as? Int) ?? 5),
            expiresIn: (j["expires_in"] as? Int) ?? 600,
            handle: dc
        )
    }

    public func poll(_ s: DeviceStart) async throws -> PollResult {
        let (data, resp) = try await http.data(for: .form(Self.tokenURL, body: [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": s.handle,
            "client_id": Self.clientId,
        ]))
        let j = jsonObject(data)
        if let err = j["error"] as? String {
            switch err {
            case "authorization_pending": return .pending
            case "slow_down": return .slowDown
            case "expired_token": throw AgentError.auth("o código expirou; comece de novo")
            case "access_denied": throw AgentError.auth("acesso negado na xAI")
            default: throw AgentError.auth("xAI: \(err)")
            }
        }
        guard (200 ..< 300).contains(resp.statusCode) else { throw AgentError.http(
            resp.statusCode,
            String(decoding: data, as: UTF8.self)
        ) }
        return try .tokens(Self.tokens(j, fallbackRefresh: ""))
    }

    public func refresh(_ refresh: String) async throws -> TokenBundle {
        let (data, resp) = try await http.data(for: .form(
            Self.tokenURL,
            body: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": Self.clientId]
        ))
        let j = jsonObject(data)
        if (j["error"] as? String) == "invalid_grant" {
            throw AgentError.invalidGrant
        }
        guard (200 ..< 300).contains(resp.statusCode) else { throw AgentError.http(
            resp.statusCode,
            String(decoding: data, as: UTF8.self)
        ) }
        return try Self.tokens(j, fallbackRefresh: refresh)
    }

    static func tokens(_ j: [String: Any], fallbackRefresh: String) throws -> TokenBundle {
        guard let access = j["access_token"] as? String else { throw AgentError.auth("xAI não devolveu access token") }
        let exp = (j["expires_in"] as? Double) ?? 3600
        let claims = PKCE.jwtClaims((j["id_token"] as? String) ?? access)
        return TokenBundle(
            access: access,
            refresh: (j["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackRefresh,
            expiresAt: Date(timeIntervalSinceNow: exp),
            accountId: (claims["email"] as? String) ?? (claims["sub"] as? String)
        )
    }
}
