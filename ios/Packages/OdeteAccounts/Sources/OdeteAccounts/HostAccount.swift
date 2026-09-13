import Foundation

public enum HostKind: String, Codable, CaseIterable, Sendable {
    case github, gitlab, gitea, bitbucket, other
    public var label: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .gitea: "Gitea / Forgejo"
        case .bitbucket: "Bitbucket"
        case .other: "Outro"
        }
    }

    public var defaultHost: String {
        switch self {
        case .github: "github.com"
        case .gitlab: "gitlab.com"
        case .bitbucket: "bitbucket.org"
        case .gitea, .other: ""
        }
    }

    /// Usuário que o libgit2 manda junto com o token no HTTPS.
    public var gitUsername: String {
        switch self {
        case .github: "x-access-token"
        case .gitlab: "oauth2"
        default: "git"
        }
    }

    public static func detect(host: String) -> HostKind {
        let h = host.lowercased()
        if h.contains("github") {
            return .github
        }
        if h.contains("gitlab") {
            return .gitlab
        }
        if h.contains("bitbucket") {
            return .bitbucket
        }
        if h.contains("gitea") || h.contains("codeberg") || h.contains("forgejo") {
            return .gitea
        }
        return .other
    }
}

/// Uma conta por host. O token fica no Keychain, não neste struct.
public struct HostAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: HostKind
    public var host: String // "github.com"
    public var login: String // usuário exibido
    public var name: String?
    public var email: String?
    public var avatarURL: String?
    public var addedAt: Date

    public init(
        id: UUID = UUID(),
        kind: HostKind,
        host: String,
        login: String,
        name: String? = nil,
        email: String? = nil,
        avatarURL: String? = nil,
        addedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.host = host
        self.login = login
        self.name = name
        self.email = email
        self.avatarURL = avatarURL
        self.addedAt = addedAt
    }

    public var keychainKey: String {
        "token:\(host):\(login)"
    }

    /// Host de uma URL de remoto ("https://github.com/a/b.git" → "github.com").
    public static func host(ofRemote url: String) -> String? {
        if let u = URL(string: url), let h = u.host() {
            return h.lowercased()
        }
        if let at = url.firstIndex(of: "@"), let colon = url[at...].firstIndex(of: ":") {
            return String(url[url.index(after: at) ..< colon]).lowercased()
        }
        return nil
    }
}
