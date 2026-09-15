import Foundation
import OdeteCore
import Synchronization

public struct Checkpoint: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var at: Date
    public var paths: [String]
    public var saved: [String]
}

/// Snapshot dos arquivos antes de cada turno, em `.odete/checkpoints/<id>/`.
public final class CheckpointStore: @unchecked Sendable {
    public let root: URL
    public let host: ToolHost
    private var dir: URL {
        root.appending(path: ".odete/checkpoints")
    }

    public var limit = 8
    private static let counter = Mutex(0)

    public init(root: URL, host: ToolHost) {
        self.root = root; self.host = host
    }

    public func list() -> [Checkpoint] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return ids
            .compactMap { id in
                (try? Data(contentsOf: dir.appending(path: "\(id)/manifest.json"))).flatMap { try? dec.decode(
                    Checkpoint.self,
                    from: $0
                ) }
            }.sorted { $0.id > $1.id }
    }

    public var last: Checkpoint? {
        list().first
    }

    /// Copia os arquivos (sem ruído, < 200 kB, até 220) e grava o manifesto.
    @discardableResult
    public func take(title: String) -> Checkpoint {
        let id = String(
            format: "%013ld-%06ld",
            Int(Date().timeIntervalSince1970 * 1000),
            Self.counter.withLock { $0 += 1; return $0 }
        )
        let paths = host.allPaths()
        var saved: [String] = []
        let fm = FileManager.default
        for p in paths.prefix(220) {
            let src = root.appending(path: p)
            guard let size = (try? fm.attributesOfItem(atPath: src.path)[.size]) as? Int,
                  size < 200_000 else { continue }
            let dst = dir.appending(path: "\(id)/files/\(p)")
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: src, to: dst)) != nil {
                saved.append(p)
            }
        }
        let cp = Checkpoint(id: id, title: title, at: .now, paths: paths, saved: saved)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? fm.createDirectory(at: dir.appending(path: id), withIntermediateDirectories: true)
        try? enc.encode(cp).write(to: dir.appending(path: "\(id)/manifest.json"), options: .atomic)
        for old in list().dropFirst(limit) {
            try? fm.removeItem(at: dir.appending(path: old.id))
        }
        return cp
    }

    /// Volta os arquivos ao snapshot: reescreve os salvos e apaga os que não existiam.
    public func restore(_ id: String) -> String {
        guard let cp = list().first(where: { $0.id == id }) else { return "checkpoint sumiu" }
        let fm = FileManager.default
        for p in host.allPaths() where !cp.paths.contains(p) {
            try? fm.removeItem(at: root.appending(path: p))
        }
        for p in cp.saved {
            let src = dir.appending(path: "\(cp.id)/files/\(p)"), dst = root.appending(path: p)
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
        return "voltou: \(cp.title)"
    }
}
