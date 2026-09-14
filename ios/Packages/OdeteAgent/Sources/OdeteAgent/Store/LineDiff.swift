import Foundation

/// Diff por linhas (LCS) e hunks, para mostrar patches e aceitar por hunk.
public struct Hunk: Sendable, Hashable, Identifiable {
    public enum Line: Sendable, Hashable { case context(String), removed(String), added(String) }
    public var id: Int
    public var beforeStart: Int
    public var afterStart: Int
    public var lines: [Line]
}

public enum LineDiff {
    enum Op: Equatable { case keep(String), del(String), ins(String) }

    static func ops(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        if n * m > 4_000_000 { // arquivos enormes: sem LCS
            return a.map { .del($0) } + b.map { .ins($0) }
        }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                out.append(.keep(a[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                out.append(.del(a[i])); i += 1
            } else {
                out.append(.ins(b[j])); j += 1
            }
        }
        while i < n {
            out.append(.del(a[i])); i += 1
        }
        while j < m {
            out.append(.ins(b[j])); j += 1
        }
        return out
    }

    static func lines(_ s: String) -> [String] {
        s.isEmpty ? [] : s.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
    }

    /// Hunks com `context` linhas de contexto em volta.
    public static func hunks(_ before: String, _ after: String, context: Int = 3) -> [Hunk] {
        let ops = ops(lines(before), lines(after))
        var changed: [Int] = []
        for (i, op) in ops.enumerated() {
            if case .keep = op {} else {
                changed.append(i)
            }
        }
        guard !changed.isEmpty else { return [] }
        // agrupa mudanças cuja distância ≤ 2*context
        var groups: [(Int, Int)] = []
        var start = changed[0], end = changed[0]
        for c in changed.dropFirst() {
            if c - end <= context * 2 {
                end = c
            } else {
                groups.append((start, end)); start = c; end = c
            }
        }
        groups.append((start, end))
        var out: [Hunk] = []
        var bLine = 1, aLine = 1
        var pos = 0
        for (gi, g) in groups.enumerated() {
            let from = max(0, g.0 - context), to = min(ops.count - 1, g.1 + context)
            // avança contadores até `from`
            while pos <
                from
            {
                if case .del = ops[pos] {
                    bLine += 1
                } else if case .ins = ops[pos] {
                    aLine += 1
                } else {
                    bLine += 1; aLine += 1
                }; pos += 1
            }
            var lines: [Hunk.Line] = []
            let bs = bLine, as_ = aLine
            while pos <= to {
                switch ops[pos] {
                case let .keep(s): lines.append(.context(s)); bLine += 1; aLine += 1
                case let .del(s): lines.append(.removed(s)); bLine += 1
                case let .ins(s): lines.append(.added(s)); aLine += 1
                }
                pos += 1
            }
            out.append(Hunk(id: gi, beforeStart: bs, afterStart: as_, lines: lines))
        }
        return out
    }

    /// Texto com só o hunk `index` aplicado sobre `before`.
    public static func applyOnly(hunk index: Int, before: String, after: String, context: Int = 3) -> String {
        let ops = ops(lines(before), lines(after))
        var changed: [Int] = []
        for (i, op) in ops.enumerated() {
            if case .keep = op {} else {
                changed.append(i)
            }
        }
        guard !changed.isEmpty else { return before }
        var groups: [(Int, Int)] = []
        var start = changed[0], end = changed[0]
        for c in changed
            .dropFirst()
        {
            if c - end <= context * 2 {
                end = c
            } else {
                groups.append((start, end)); start = c; end = c
            }
        }
        groups.append((start, end))
        guard index < groups.count else { return before }
        let g = groups[index]
        var out: [String] = []
        for (i, op) in ops.enumerated() {
            let inHunk = i >= g.0 && i <= g.1
            switch op {
            case let .keep(s): out.append(s)
            case let .del(s): if !inHunk {
                    out.append(s)
                }
            case let .ins(s): if inHunk {
                    out.append(s)
                }
            }
        }
        return out.joined(separator: "\n")
    }
}
