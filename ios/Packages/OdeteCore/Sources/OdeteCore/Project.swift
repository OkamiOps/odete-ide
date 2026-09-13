import Foundation

/// Um projeto da Odete: uma pasta em `Documents/Projects/<name>`.
public struct Project: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var lastOpenedAt: Date?

    public init(id: UUID = UUID(), name: String, createdAt: Date = .now, lastOpenedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}
