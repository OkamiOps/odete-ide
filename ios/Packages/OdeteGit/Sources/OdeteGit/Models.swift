import Foundation

public struct Signature: Sendable, Hashable {
    public var name: String
    public var email: String
    public init(name: String, email: String) {
        self.name = name; self.email = email
    }
}

public enum Change: String, Sendable, Hashable {
    case added, modified, deleted, renamed, typeChange, untracked, ignored, conflicted
    public var symbol: String {
        switch self {
        case .added, .untracked: "A"
        case .modified, .typeChange: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .ignored: "I"
        case .conflicted: "!"
        }
    }
}

public struct StatusEntry: Sendable, Hashable, Identifiable {
    public var path: String
    public var staged: Change?
    public var unstaged: Change?
    public var id: String {
        path
    }

    public var isConflicted: Bool {
        unstaged == .conflicted
    }
}

public struct Commit: Sendable, Hashable, Identifiable {
    public var id: String // sha completo
    public var short: String {
        String(id.prefix(7))
    }

    public var summary: String
    public var body: String
    public var author: Signature
    public var date: Date
    public var parents: [String]
}

public struct Branch: Sendable, Hashable, Identifiable {
    public var name: String // "main" ou "origin/main"
    public var isRemote: Bool
    public var isHead: Bool
    public var target: String // sha
    public var upstream: String?
    public var id: String {
        (isRemote ? "r:" : "l:") + name
    }
}

public struct Remote: Sendable, Hashable, Identifiable {
    public var name: String
    public var url: String
    public var id: String {
        name
    }

    public var isGitHub: Bool {
        url.contains("github.com")
    }

    /// "owner/repo" quando GitHub.
    public var githubSlug: String? {
        guard isGitHub else { return nil }
        var s = url
        if let r = s.range(of: "github.com") {
            s = String(s[r.upperBound...])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
        if s.hasSuffix(".git") {
            s.removeLast(4)
        }
        return s.split(separator: "/").count == 2 ? s : nil
    }
}

public struct StashEntry: Sendable, Hashable, Identifiable {
    public var index: Int
    public var message: String
    public var id: Int {
        index
    }
}

public enum LineKind: Sendable, Hashable { case context, addition, deletion }

public struct DiffLine: Sendable, Hashable, Identifiable {
    public var kind: LineKind
    public var text: String
    public var oldLine: Int?
    public var newLine: Int?
    public var id: String {
        "\(oldLine ?? -1):\(newLine ?? -1):\(kind)"
    }
}

public struct Hunk: Sendable, Hashable, Identifiable {
    public var header: String
    public var oldStart: Int
    public var oldLines: Int
    public var newStart: Int
    public var newLines: Int
    public var lines: [DiffLine]
    public var id: String {
        header
    }
}

public struct FileDiff: Sendable, Hashable, Identifiable {
    public var path: String
    public var oldPath: String?
    public var change: Change
    public var isBinary: Bool
    public var hunks: [Hunk]
    public var id: String {
        path
    }

    public var additions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count }
    }

    public var deletions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count }
    }
}

public struct Diff: Sendable, Hashable {
    public var files: [FileDiff]
    public static let empty = Diff(files: [])
}

public enum MergeResult: Sendable, Hashable {
    case upToDate
    case fastForward(String)
    case merged(String)
    case conflicts([String])
}

public struct CloneProgress: Sendable {
    public var received: Int
    public var total: Int
    public var bytes: Int
    public var indexed: Int
    public init(received: Int, total: Int, bytes: Int, indexed: Int) {
        self.received = received
        self.total = total
        self.bytes = bytes
        self.indexed = indexed
    }

    public var fraction: Double {
        total == 0 ? 0 : Double(received + indexed) / Double(total * 2)
    }
}
