import Foundation
import Observation
import OdeteBundler
import OdeteGit
import OdeteNpm
import OdeteShell

/// Um shell por projeto, com as abas de terminal, os servidores abertos e os diagnósticos do build.
@MainActor
@Observable
public final class RunModel {
    public let root: URL
    public private(set) var sessions: [TerminalSession] = []
    public var activeSession: UUID?
    /// Portas abertas por jobs (servidor de dev, node) e o comando que abriu.
    public private(set) var servers: [(port: Int, command: String)] = []
    public var diagnostics: [Diagnostic] = []
    /// Última porta aberta; o preview segue essa URL.
    public var previewURL: URL?
    private let authorBox: SendBox<Void, Signature>
    private let credBox: SendBox<String, Credentials?>

    init(root: URL, git: GitModel) {
        self.root = root
        authorBox = SendBox { git.author }
        credBox = SendBox { (url: String) in git.credentials(for: Remote(name: "origin", url: url)) }
        newSession()
    }

    private var services: ShellServices {
        var s = ShellServices()
        let a = authorBox, c = credBox
        s.author = { a.value() }
        s.credentials = { c.value($0) }
        s.onServer = { [weak self] port, cmd in Task { @MainActor in self?.serverOpened(port, cmd) } }
        s.onDiagnostics = { [weak self] d in Task { @MainActor in self?.diagnostics = d } }
        return s
    }

    @discardableResult
    public func newSession() -> TerminalSession {
        let shell = Shell(root: root, services: services)
        let s = TerminalSession(shell: shell, banner: sessions.isEmpty)
        sessions.append(s)
        activeSession = s.id
        return s
    }

    public var active: TerminalSession? {
        sessions.first { $0.id == activeSession } ?? sessions.first
    }

    public func close(_ s: TerminalSession) {
        s.shell.killAll()
        sessions.removeAll { $0.id == s.id }
        pruneServers()
        if sessions.isEmpty {
            newSession()
        } else if activeSession == s.id {
            activeSession = sessions.last?.id
        }
    }

    /// Roda um comando na aba ativa.
    public func run(_ line: String) {
        let s = active ?? newSession()
        s.append(.input, "\(s.prompt) \(line)")
        s.run(line)
    }

    public var jobs: [Job] {
        sessions.flatMap(\.jobs)
    }

    public func stopAll() {
        for s in sessions {
            s.shell.killAll()
        }
        servers.removeAll()
        previewURL = nil
    }

    private func serverOpened(_ port: Int, _ cmd: String) {
        if !servers.contains(where: { $0.port == port }) {
            servers.append((port, cmd))
        }
        previewURL = URL(string: "http://127.0.0.1:\(port)/")
    }

    /// Tira as portas cujos jobs morreram.
    public func pruneServers() {
        let live = Set(jobs.flatMap(\.ports))
        servers.removeAll { !live.contains($0.port) }
        if let u = previewURL, let p = u.port, !live.contains(p) {
            previewURL = servers.last.flatMap { URL(string: "http://127.0.0.1:\($0.port)/") }
        }
    }
}

/// Executa uma closure do MainActor de forma síncrona a partir de qualquer fila.
final class SendBox<In: Sendable, Out: Sendable>: @unchecked Sendable {
    private nonisolated(unsafe) let body: @MainActor (In) -> Out
    init(_ body: @escaping @MainActor (In) -> Out) {
        self.body = body
    }

    func value(_ input: In) -> Out {
        let b = body
        if Thread.isMainThread {
            return MainActor.assumeIsolated { b(input) }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { b(input) } }
    }
}

extension SendBox where In == Void {
    convenience init(_ body: @escaping @MainActor () -> Out) {
        self.init { _ in body() }
    }

    func value() -> Out {
        value(())
    }
}
