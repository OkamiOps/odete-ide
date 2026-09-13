import Foundation

public struct EditorTab: Identifiable, Codable, Hashable, Sendable {
    public var path: String
    public var isDirty: Bool
    public var id: String { path }

    public init(path: String, isDirty: Bool = false) {
        self.path = path
        self.isDirty = isDirty
    }
}
