import Foundation
import OdeteI18n

public struct GitHubUser: Codable, Sendable, Equatable {
    /// Id numérico da conta: entra no e-mail noreply (`ID+login@users.noreply.github.com`).
    public var id: Int?
    public var login: String
    public var name: String?
    public var email: String?
    public var avatarUrl: String?
    enum CodingKeys: String, CodingKey { case id, login, name, email, avatarUrl = "avatar_url" }
}

public struct GitHubRepo: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var fullName: String
    public var name: String
    public var isPrivate: Bool
    public var cloneUrl: String
    public var defaultBranch: String
    public var description: String?
    public var updatedAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, name, description
        case fullName = "full_name", isPrivate = "private", cloneUrl = "clone_url", defaultBranch = "default_branch",
             updatedAt = "updated_at"
    }
}

public struct GitHubPull: Codable, Sendable, Identifiable, Equatable {
    public struct Ref: Codable, Sendable, Equatable { public var ref: String; public var sha: String }
    public var id: Int
    public var number: Int
    public var title: String
    public var body: String?
    public var state: String
    public var htmlUrl: String
    public var head: Ref
    public var base: Ref
    public var user: GitHubUser?
    public var draft: Bool?
    public var merged: Bool?
    public var mergeable: Bool?
    public var createdAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, number, title, body, state, head, base, user, draft, merged, mergeable
        case htmlUrl = "html_url", createdAt = "created_at"
    }
}

public struct GitHubIssue: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var number: Int
    public var title: String
    public var body: String?
    public var state: String
    public var htmlUrl: String
    public var user: GitHubUser?
    public var createdAt: Date?
    public var pullRequest: [String: String?]?
    public var isPull: Bool {
        pullRequest != nil
    }

    enum CodingKeys: String, CodingKey {
        case id, number, title, body, state, user
        case htmlUrl = "html_url", createdAt = "created_at", pullRequest = "pull_request"
    }
}

public struct GitHubRun: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var name: String?
    public var status: String
    public var conclusion: String?
    public var headBranch: String?
    public var htmlUrl: String
    public var createdAt: Date?
    public var event: String?
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, event
        case headBranch = "head_branch", htmlUrl = "html_url", createdAt = "created_at"
    }
}

public struct GitHubPullFile: Codable, Sendable, Identifiable, Equatable {
    public var filename: String
    public var status: String
    public var additions: Int
    public var deletions: Int
    public var patch: String?
    public var id: String {
        filename
    }
}

public struct GitHubComment: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var body: String
    public var user: GitHubUser?
    public var createdAt: Date?
    enum CodingKeys: String, CodingKey { case id, body, user, createdAt = "created_at" }
}

public struct GitHubCheckRun: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var name: String
    public var status: String
    public var conclusion: String?
    public var htmlUrl: String?
    enum CodingKeys: String, CodingKey { case id, name, status, conclusion, htmlUrl = "html_url" }
}

/// Cliente REST do GitHub. `token` opcional para leitura pública.
public struct GitHubAPI: Sendable {
    public var token: String?
    public var session: URLSession
    public var base = URL(string: "https://api.github.com")!

    public init(token: String?, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func request(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: [String: Any]? = nil
    ) async throws -> Data {
        var comps = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
            if code == 401 || code == 403 {
                throw GitHubError.auth(msg.isEmpty ? tr("sem permissão") : msg)
            }
            throw GitHubError.http(code, msg)
        }
        return data
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await Self.decoder.decode(T.self, from: request("GET", path, query: query))
    }

    public func user() async throws -> GitHubUser {
        try await get("/user")
    }

    public func repos(page: Int = 1) async throws -> [GitHubRepo] {
        try await get(
            "/user/repos",
            query: [
                "sort": "updated",
                "per_page": "100",
                "page": "\(page)",
                "affiliation": "owner,collaborator,organization_member",
            ]
        )
    }

    public func pulls(_ slug: String, state: String = "open") async throws -> [GitHubPull] {
        try await get("/repos/\(slug)/pulls", query: ["state": state, "per_page": "50"])
    }

    public func pullFiles(_ slug: String, number: Int) async throws -> [GitHubPullFile] {
        try await get("/repos/\(slug)/pulls/\(number)/files", query: ["per_page": "100"])
    }

    public func pull(_ slug: String, number: Int) async throws -> GitHubPull {
        try await get("/repos/\(slug)/pulls/\(number)")
    }

    /// Checks do commit (Actions e apps) — `ref` é um sha ou branch.
    public func checkRuns(_ slug: String, ref: String) async throws -> [GitHubCheckRun] {
        struct Wrap: Decodable { var checkRuns: [GitHubCheckRun]; enum CodingKeys: String,
                                     CodingKey { case checkRuns = "check_runs" }
        }
        let w: Wrap = try await get("/repos/\(slug)/commits/\(ref)/check-runs", query: ["per_page": "50"])
        return w.checkRuns
    }

    public func pullComments(_ slug: String, number: Int) async throws -> [GitHubComment] {
        try await get("/repos/\(slug)/issues/\(number)/comments", query: ["per_page": "100"])
    }

    public func createPull(
        _ slug: String,
        title: String,
        body: String,
        head: String,
        base: String,
        draft: Bool = false
    ) async throws -> GitHubPull {
        let data = try await request(
            "POST",
            "/repos/\(slug)/pulls",
            body: ["title": title, "body": body, "head": head, "base": base, "draft": draft]
        )
        return try Self.decoder.decode(GitHubPull.self, from: data)
    }

    /// Fecha sem mergear. Faltava: nem a interface sabia fazer isso.
    public func closePull(_ slug: String, number: Int) async throws {
        _ = try await request("PATCH", "/repos/\(slug)/pulls/\(number)", body: ["state": "closed"])
    }

    public func mergePull(_ slug: String, number: Int, method: String = "squash") async throws {
        _ = try await request("PUT", "/repos/\(slug)/pulls/\(number)/merge", body: ["merge_method": method])
    }

    public func comment(_ slug: String, number: Int, body: String) async throws {
        _ = try await request("POST", "/repos/\(slug)/issues/\(number)/comments", body: ["body": body])
    }

    public func issues(_ slug: String, state: String = "open") async throws -> [GitHubIssue] {
        let all: [GitHubIssue] = try await get("/repos/\(slug)/issues", query: ["state": state, "per_page": "50"])
        return all.filter { !$0.isPull }
    }

    public func createIssue(_ slug: String, title: String, body: String) async throws -> GitHubIssue {
        let data = try await request("POST", "/repos/\(slug)/issues", body: ["title": title, "body": body])
        return try Self.decoder.decode(GitHubIssue.self, from: data)
    }

    public func runs(_ slug: String) async throws -> [GitHubRun] {
        struct Wrap: Decodable { var workflow_runs: [GitHubRun] }
        let w: Wrap = try await get("/repos/\(slug)/actions/runs", query: ["per_page": "30"])
        return w.workflow_runs
    }

    public func createRepo(name: String, isPrivate: Bool, org: String? = nil) async throws -> GitHubRepo {
        let path = org.map { "/orgs/\($0)/repos" } ?? "/user/repos"
        let data = try await request("POST", path, body: ["name": name, "private": isPrivate])
        return try Self.decoder.decode(GitHubRepo.self, from: data)
    }
}
