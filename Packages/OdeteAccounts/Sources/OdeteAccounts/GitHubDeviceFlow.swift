import Foundation
import OdeteI18n

/// Device flow do GitHub. `clientId` é público (OAuth App da Odete); sem client secret.
public struct GitHubDeviceFlow: Sendable {
    /// Client ID do OAuth App "Odete" (github.com/settings/developers → Device flow), lido de
    /// `OdeteGitHubClientId` no Info.plist. Vazio = botão "Entrar com GitHub" escondido.
    public static var defaultClientId: String {
        (Bundle.main.object(forInfoDictionaryKey: "OdeteGitHubClientId") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public static let scopes = "repo read:org workflow read:user user:email"

    public struct DeviceCode: Codable, Sendable, Equatable {
        public var deviceCode: String
        public var userCode: String
        public var verificationUri: String
        public var expiresIn: Int
        public var interval: Int
        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code", userCode = "user_code", verificationUri = "verification_uri",
                 expiresIn = "expires_in",
                 interval
        }
    }

    public enum Poll: Sendable, Equatable {
        case pending
        case slowDown
        case token(String)
        case failed(String)
    }

    public var clientId: String
    public var session: URLSession

    public init(clientId: String = GitHubDeviceFlow.defaultClientId, session: URLSession = .shared) {
        self.clientId = clientId
        self.session = session
    }

    public var isConfigured: Bool {
        !clientId.isEmpty
    }

    static func form(_ items: [String: String]) -> Data {
        Data(items.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").utf8)
    }

    public func requestCode() async throws -> DeviceCode {
        var req = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(["client_id": clientId, "scope": Self.scopes])
        let (data, _) = try await session.data(for: req)
        return try Self.parseCode(data)
    }

    public static func parseCode(_ data: Data) throws -> DeviceCode {
        try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    public func poll(_ code: DeviceCode) async throws -> Poll {
        var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form([
            "client_id": clientId,
            "device_code": code.deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
        let (data, _) = try await session.data(for: req)
        return Self.parsePoll(data)
    }

    public static func parsePoll(_ data: Data) -> Poll {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failed(tr("resposta inválida")) }
        if let t = j["access_token"] as? String {
            return .token(t)
        }
        switch j["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case let e?: return .failed((j["error_description"] as? String) ?? e)
        default: return .failed(tr("resposta inválida"))
        }
    }

    /// Faz o polling até conseguir o token, respeitando `interval` e `slow_down`.
    public func waitForToken(_ code: DeviceCode) async throws -> String {
        var interval = max(code.interval, 5)
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()
            switch try await poll(code) {
            case .pending: continue
            case .slowDown: interval += 5
            case let .token(t): return t
            case let .failed(m): throw GitHubError.auth(m)
            }
        }
        throw GitHubError.auth(tr("código expirou"))
    }
}

public enum GitHubError: LocalizedError, Sendable {
    case auth(String), http(Int, String), invalid
    public var errorDescription: String? {
        switch self {
        case let .auth(m): "GitHub: \(m)"
        case let .http(c, m): "GitHub \(c): \(m)"
        case .invalid: tr("GitHub: resposta inválida")
        }
    }
}
