import Foundation
import Synchronization

/// Saída de um comando: linhas que a sessão mostra.
public enum StreamKind: Sendable { case out, err }

/// Contexto de execução de um comando dentro de um pipeline.
public final class CommandIO: @unchecked Sendable {
    public let stdin: String?
    private let outSink: @Sendable (StreamKind, String) -> Void
    private let capture = Mutex<String>("")
    public let capturing: Bool
    public var stderrToStdout = false

    public init(stdin: String?, capturing: Bool, sink: @escaping @Sendable (StreamKind, String) -> Void) {
        self.stdin = stdin; self.capturing = capturing; outSink = sink
    }

    /// Escreve em stdout (vai para o próximo comando do pipe ou para a tela).
    public func out(_ text: String) {
        if capturing {
            capture.withLock { $0 += text + "\n" }
        } else {
            outSink(.out, text)
        }
    }

    public func err(_ text: String) {
        if stderrToStdout {
            out(text)
        } else {
            outSink(.err, text)
        }
    }

    public var captured: String {
        capture.withLock { $0 }
    }
}

public struct CommandContext: Sendable {
    public var cwd: URL
    public var root: URL
    public var env: [String: String]
    public var io: CommandIO
    public var shell: Shell
    public var isCancelled: @Sendable () -> Bool

    public func resolve(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return root.appending(path: String(path.dropFirst()))
        }
        if path == "~" || path
            .hasPrefix("~/")
        {
            return root.appending(path: String(path.dropFirst(path == "~" ? 1 : 2)))
        }
        return cwd.appending(path: path).standardizedFileURL
    }

    /// Caminho relativo à raiz do projeto, para exibir.
    public func display(_ url: URL) -> String {
        let r = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        if r == base {
            return "~"
        }
        return r.hasPrefix(base + "/") ? "~/" + String(r.dropFirst(base.count + 1)) : r
    }
}

public protocol ShellCommand: Sendable {
    var name: String { get }
    var help: String { get }
    func run(_ args: [String], _ ctx: CommandContext) async -> Int32
}
