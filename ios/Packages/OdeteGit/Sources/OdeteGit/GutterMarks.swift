import Foundation

/// Marca do gutter do editor: uma linha (1-based, no workdir) adicionada, alterada, ou o ponto
/// onde linhas foram removidas (a marca fica na linha seguinte à remoção).
public struct GutterMark: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case added, modified, deleted }
    public var line: Int
    public var kind: Kind
    /// Índice do hunk de origem no `FileDiff`.
    public var hunk: Int
    public var id: String {
        "\(line):\(kind.rawValue)"
    }

    public init(line: Int, kind: Kind, hunk: Int) {
        self.line = line
        self.kind = kind
        self.hunk = hunk
    }
}

public enum GutterMarks {
    /// Converte os hunks de um arquivo em marcas por linha.
    /// Adições pareadas com remoções no mesmo hunk viram `modified`; sobras viram `added`;
    /// remoções sem par viram um `deleted` na linha onde estariam.
    public static func from(_ file: FileDiff) -> [GutterMark] {
        var out: [GutterMark] = []
        for (hi, h) in file.hunks.enumerated() {
            var pendingDeletes = 0
            // Hunk só de remoção: o git aponta a linha anterior; a marca vai na seguinte.
            var nextNew = h.newLines == 0 ? h.newStart + 1 : h.newStart
            for l in h.lines {
                switch l.kind {
                case .context:
                    if pendingDeletes > 0 {
                        out.append(GutterMark(line: max(nextNew, 1), kind: .deleted, hunk: hi))
                        pendingDeletes = 0
                    }
                    nextNew += 1
                case .deletion:
                    pendingDeletes += 1
                case .addition:
                    let kind: GutterMark.Kind = pendingDeletes > 0 ? .modified : .added
                    if pendingDeletes > 0 {
                        pendingDeletes -= 1
                    }
                    out.append(GutterMark(line: l.newLine ?? nextNew, kind: kind, hunk: hi))
                    nextNew += 1
                }
            }
            if pendingDeletes > 0 {
                out.append(GutterMark(line: max(nextNew, 1), kind: .deleted, hunk: hi))
            }
        }
        return out
    }
}

public extension Repository {
    /// Marcas do gutter para um arquivo (HEAD → workdir, sem contexto).
    func gutterMarks(path: String) throws -> (marks: [GutterMark], file: FileDiff?) {
        let d = try diff(.headToWorkdir, path: path, context: 0)
        guard let f = d.files.first(where: { $0.path == path }) else { return ([], nil) }
        if f.change == .added || f.change == .untracked {
            let n = f.hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count }
            return ((1 ... max(n, 1)).map { GutterMark(line: $0, kind: .added, hunk: 0) }, f)
        }
        return (GutterMarks.from(f), f)
    }
}
