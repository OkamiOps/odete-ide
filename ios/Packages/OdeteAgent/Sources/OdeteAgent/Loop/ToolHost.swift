import Foundation
import OdeteCore

/// O que as ferramentas precisam do app: arquivos, terminal e shell.
public protocol ToolHost: Sendable {
    var root: URL { get }
    func read(_ path: String) -> String?
    func write(_ path: String, _ text: String) throws
    func exists(_ path: String) -> Bool
    func list(_ path: String) -> [String]
    /// Todos os caminhos relativos (sem ruído), para a lista do sistema e o checkpoint.
    func allPaths() -> [String]
    func grep(_ pattern: String, in path: String?) -> String
    func terminalTail(_ n: Int) -> String
    func runShell(_ command: String) async -> String
    /// Abre o arquivo no editor (após patch); pode ser no-op.
    func reveal(_ path: String)
}

/// Implementação direta sobre FileManager. Serve para testes e como base para o app.
open class FileToolHost: ToolHost, @unchecked Sendable {
    public let root: URL
    public init(root: URL) {
        self.root = root
    }

    public func url(_ path: String) -> URL {
        root.appending(path: path).standardizedFileURL
    }

    public func inside(_ path: String) -> Bool {
        url(path).path.hasPrefix(root.standardizedFileURL.path)
    }

    public func read(_ path: String) -> String? {
        inside(path) ? try? String(contentsOf: url(path), encoding: .utf8) :
            nil
    }

    open func write(_ path: String, _ text: String) throws {
        guard inside(path) else { throw AgentError.transport("fora do projeto") }
        try FileManager.default.createDirectory(
            at: url(path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url(path), atomically: true, encoding: .utf8)
    }

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(path).path)
    }

    public func list(_ path: String) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: url(path).path) else { return [] }
        return items.filter { !Ignore.isNoisePath($0) }.sorted().map { n in
            var d: ObjCBool = false
            FileManager.default.fileExists(atPath: url(path).appending(path: n).path, isDirectory: &d)
            return n + (d.boolValue ? "/" : "")
        }
    }

    public func allPaths() -> [String] {
        var out: [String] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return out }
        let base = root.standardizedFileURL.path + "/"
        while let u = e.nextObject() as? URL {
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count))
            if Ignore.isNoisePath(rel) || rel == ".odete" || rel.hasPrefix(".odete/") || rel == ".git" || rel
                .hasPrefix(".git/")
            {
                e.skipDescendants(); continue
            }
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(rel)
            }
        }
        return out.sorted()
    }

    public func grep(_ pattern: String, in path: String?) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return "regex inválida" }
        var lines: [String] = []
        let paths = (path?.isEmpty == false ? allPaths().filter { $0.hasPrefix(path!) } : allPaths())
        for p in paths {
            guard let text = read(p) else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let s = String(line)
                if re
                    .firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) !=
                    nil
                {
                    lines.append("\(p):\(i + 1):\(s.prefix(200))")
                }
                if lines.count >= 200 {
                    return lines.joined(separator: "\n") + "\n… (limite de 200)"
                }
            }
        }
        return lines.isEmpty ? "(nada encontrado)" : lines.joined(separator: "\n")
    }

    open func terminalTail(_ n: Int) -> String {
        "(terminal vazio)"
    }

    open func runShell(_ command: String) async -> String {
        "shell indisponível"
    }

    open func reveal(_ path: String) {}
}
