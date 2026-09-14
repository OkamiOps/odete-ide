import Foundation

/// OAuth PKCE com o client do Claude Code: abre o navegador, o usuário cola `code#state`.
public struct ClaudeAuth: Sendable {
    public static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let redirect = "https://platform.claude.com/oauth/code/callback"
    public static let scope = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    public struct Authorize: Sendable { public let url: URL; public let verifier: String; public let state: String }

    let http: HTTPClient
    public init(http: HTTPClient = URLSessionClient()) {
        self.http = http
    }

    public func authorize() -> Authorize {
        let p = PKCE.make()
        var c = URLComponents(string: "https://claude.com/cai/oauth/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: Self.clientId), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: p.challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: p.state),
        ]
        return Authorize(url: c.url!, verifier: p.verifier, state: p.state)
    }

    /// Aceita `code#state`, `code` ou a URL de callback inteira.
    public static func parseCode(_ raw: String) -> (code: String, state: String) {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"^https?://[^\s#]+(?:[?&]code=)"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        if !t.contains("#"), let r = t.range(of: #"[?&]state="#, options: .regularExpression) {
            t.replaceSubrange(
                r,
                with: "#"
            )
        }
        let parts = t.split(separator: "#", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    public func exchange(code: String, state: String, verifier: String) async throws -> TokenBundle {
        let req = URLRequest.json(Self.tokenURL, body: [
            "grant_type": "authorization_code", "client_id": Self.clientId, "redirect_uri": Self.redirect,
            "code": code, "code_verifier": verifier, "state": state,
        ])
        return try await Self.tokens(from: http.data(for: req), fallbackRefresh: "")
    }

    public func refresh(_ refresh: String) async throws -> TokenBundle {
        let req = URLRequest.json(
            Self.tokenURL,
            body: ["grant_type": "refresh_token", "client_id": Self.clientId, "refresh_token": refresh]
        )
        return try await Self.tokens(from: http.data(for: req), fallbackRefresh: refresh)
    }

    static func tokens(from r: (Data, HTTPURLResponse), fallbackRefresh: String) throws -> TokenBundle {
        let (data, resp) = r
        let body = String(decoding: data, as: UTF8.self)
        guard (200 ..< 300).contains(resp.statusCode) else {
            if body.contains("invalid_grant") {
                throw AgentError.invalidGrant
            }
            throw AgentError.http(resp.statusCode, body)
        }
        let j = jsonObject(data)
        guard let access = j["access_token"] as? String
        else { throw AgentError.auth("Claude não devolveu access token") }
        let exp = (j["expires_in"] as? Double) ?? 3600
        return TokenBundle(
            access: access,
            refresh: (j["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackRefresh,
            expiresAt: Date(timeIntervalSinceNow: exp)
        )
    }
}
