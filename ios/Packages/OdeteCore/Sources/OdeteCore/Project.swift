import Foundation

/// Um projeto da Odete: uma pasta em `Documents/Projects/<name>`.
public struct Project: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var lastOpenedAt: Date?
    /// Pasta de fora do app (bookmark), não em `Documents/Projects`.
    public var external: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        lastOpenedAt: Date? = nil,
        external: Bool = false
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.external = external
    }

    enum CodingKeys: String, CodingKey { case id, name, createdAt, lastOpenedAt, external }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        external = try c.decodeIfPresent(Bool.self, forKey: .external) ?? false
    }
}
