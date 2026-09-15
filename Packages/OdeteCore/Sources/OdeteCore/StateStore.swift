import Foundation
import Synchronization

/// Lê e grava `ChromeSnapshot` como JSON, com gravação debounced.
public final class StateStore: Sendable {
    public let url: URL
    private let debounce: Duration
    private let pending = Mutex<Task<Void, Never>?>(nil)

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Odete", directoryHint: .isDirectory).appending(path: "state.json")
    }

    public init(url: URL = StateStore.defaultURL(), debounce: Duration = .milliseconds(300)) {
        self.url = url
        self.debounce = debounce
    }

    public func load() -> ChromeSnapshot {
        guard let data = try? Data(contentsOf: url) else { return ChromeSnapshot() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(ChromeSnapshot.self, from: data)) ?? ChromeSnapshot()
    }

    public func saveNow(_ snapshot: ChromeSnapshot) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Agenda a gravação; chamadas seguidas dentro da janela coalescem numa só.
    public func scheduleSave(_ snapshot: ChromeSnapshot) {
        let wait = debounce
        let task = Task { [self] in
            try? await Task.sleep(for: wait)
            if Task.isCancelled {
                return
            }
            try? saveNow(snapshot)
        }
        pending.withLock { old in
            old?.cancel()
            old = task
        }
    }

    /// Espera a gravação pendente terminar (para testes e para encerrar o app).
    public func flush() async {
        let task = pending.withLock { $0 }
        await task?.value
    }
}
