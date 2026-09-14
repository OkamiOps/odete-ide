import Foundation
import Synchronization

public struct Patch: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, accepted, rejected, undone }
    public var id: String
    public var path: String
    public var before: String
    public var after: String
    public var orig: String
    public var status: Status
    public var at: Date
    public var hunks: [Hunk] {
        LineDiff.hunks(before, after)
    }

    public var additions: Int {
        hunks.flatMap(\.lines).filter {
            if case .added = $0 {
                true
            } else {
                false
            }
        }.count
    }

    public var deletions: Int {
        hunks.flatMap(\.lines).filter {
            if case .removed = $0 {
                true
            } else {
                false
            }
        }.count
    }
}

/// Patches do agente: pendentes em `.odete/patches.json`, aceitar/rejeitar/desfazer.
public final class PatchStore: @unchecked Sendable {
    public let root: URL
    private let items = Mutex<[Patch]>([])
    public var onChange: (@Sendable () -> Void)?
    private var file: URL {
        root.appending(path: ".odete/patches.json")
    }

    public init(root: URL) {
        self.root = root
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: file),
           let list = try? dec.decode([Patch].self, from: d)
        {
            items.withLock { $0 = list }
        }
    }

    public var all: [Patch] {
        items.withLock { $0 }
    }

    public var pending: [Patch] {
        all.filter { $0.status == .pending }
    }

    public func get(_ id: String) -> Patch? {
        all.first { $0.id == id }
    }

    public func pending(for path: String) -> Patch? {
        pending.first { $0.path == path }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let keep = all.filter { $0.status == .pending && $0.before.count + $0.after.count < 80000 }.suffix(16)
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? enc.encode(Array(keep)).write(to: file, options: .atomic)
        onChange?()
    }

    private func update(_ id: String, _ f: (inout Patch) -> Void) {
        items.withLock {
            list in if let i = list.firstIndex(where: { $0.id == id }) {
                f(&list[i])
            }
        }
        save()
    }

    /// Enfileira (ou funde com o pendente do mesmo caminho). O arquivo já foi escrito com `after`.
    @discardableResult
    public func queue(path: String, before: String, after: String) -> Patch {
        let result: Patch = items.withLock { list in
            if let i = list.firstIndex(where: { $0.status == .pending && $0.path == path }) {
                list[i].after = after
                list[i].before = list[i].orig
                return list[i]
            }
            let p = Patch(
                id: UUID().uuidString,
                path: path,
                before: before,
                after: after,
                orig: before,
                status: .pending,
                at: .now
            )
            let done = list.filter { $0.status != .pending }.suffix(24)
            let pend = list.filter { $0.status == .pending }.suffix(11)
            list = Array(done) + Array(pend) + [p]
            return p
        }
        save()
        return result
    }

    private func current(_ path: String) -> String? {
        try? String(
            contentsOf: root.appending(path: path),
            encoding: .utf8
        )
    }

    private func write(_ path: String, _ text: String) {
        let u = root.appending(path: path)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: u, atomically: true, encoding: .utf8)
    }

    public func accept(_ id: String) {
        guard let p = get(id), p.status == .pending else { return }
        let cur = current(p.path)
        if cur == nil || cur == p.before || cur == p.orig {
            write(p.path, p.after)
        }
        update(id) { $0.status = .accepted }
    }

    public func acceptHunk(_ id: String, index: Int) {
        guard let p = get(id), p.status == .pending else { return }
        let hunks = p.hunks
        if hunks.count <= 1 {
            accept(id); return
        }
        let next = LineDiff.applyOnly(hunk: index, before: p.before, after: p.after)
        write(p.path, next)
        let left = LineDiff.hunks(next, p.after)
        update(id) {
            $0.before = next; if left.isEmpty {
                $0.status = .accepted
            }
        }
    }

    public func reject(_ id: String) {
        guard let p = get(id), p.status == .pending else { return }
        let cur = current(p.path)
        if cur == nil || cur == p.after {
            restore(p)
        }
        update(id) { $0.status = .rejected }
    }

    public func undo(_ id: String) {
        guard let p = get(id) else { return }
        restore(p)
        update(id) { $0.status = .undone }
    }

    private func restore(_ p: Patch) {
        if p.orig.isEmpty, !FileManager.default.fileExists(atPath: root.appending(path: p.path).path) {
            return
        }
        if p.orig.isEmpty,
           p.before.isEmpty
        {
            try? FileManager.default.removeItem(at: root.appending(path: p.path)); return
        }
        write(p.path, p.orig)
    }

    public func acceptAll() {
        for p in pending {
            accept(p.id)
        }
    }

    public func rejectAll() {
        for p in pending.reversed() {
            reject(p.id)
        }
    }
}
