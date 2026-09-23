import Foundation

public struct EditorTab: Identifiable, Codable, Hashable, Sendable {
    public var path: String
    public var isDirty: Bool
    public var id: String {
        path
    }

    public init(path: String, isDirty: Bool = false) {
        self.path = path
        self.isDirty = isDirty
    }

    enum CodingKeys: String, CodingKey { case path, isDirty }

    /// Sem caminho não há aba; sem `isDirty`, a aba volta limpa.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        isDirty = c.ler(.isDirty, false)
    }
}
