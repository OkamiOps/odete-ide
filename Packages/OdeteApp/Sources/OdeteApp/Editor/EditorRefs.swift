import Foundation

struct PathRef: Identifiable, Hashable {
    var path: String
    var id: String {
        path
    }
}

struct HunkRef: Identifiable, Hashable {
    var path: String
    var line: Int
    var id: String {
        "\(path):\(line)"
    }
}
