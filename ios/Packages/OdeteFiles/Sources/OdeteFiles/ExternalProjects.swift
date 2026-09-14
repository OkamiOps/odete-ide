import Foundation
import OdeteCore

/// Pastas de fora do app (Arquivos, iCloud, outros apps) abertas como projeto, guardadas
/// como bookmarks de segurança em `Documents/external.json`.
public final class ExternalProjects: @unchecked Sendable {
    struct Entry: Codable {
        var id: UUID
        var name: String
        var bookmark: Data
        var createdAt: Date
        var lastOpenedAt: Date?
    }

    public let file: URL
    private var entries: [Entry] = []
    private var resolved: [UUID: URL] = [:]
    private let lock = NSLock()

    public init(file: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appending(path: "external.json"))
    {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            entries = (try? dec.decode([Entry].self, from: data)) ?? []
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(entries).write(to: file, options: .atomic)
    }

    /// Registra uma pasta escolhida no `fileImporter` (que já veio com acesso concedido).
    @discardableResult
    public func add(_ url: URL) throws -> Project {
        lock.lock(); defer { lock.unlock() }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let bm = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        if let i = entries
            .firstIndex(where: { $0.bookmark == bm || resolved[$0.id]?.standardizedFileURL == url.standardizedFileURL
            })
        {
            return project(entries[i])
        }
        let e = Entry(id: UUID(), name: url.lastPathComponent, bookmark: bm, createdAt: .now, lastOpenedAt: nil)
        entries.append(e)
        save()
        return project(e)
    }

    public func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let u = resolved[id] {
            u.stopAccessingSecurityScopedResource()
        }
        resolved[id] = nil
        entries.removeAll { $0.id == id }
        save()
    }

    /// Projetos externos; pastas cujo bookmark não resolve mais ficam de fora.
    public func list() -> [Project] {
        lock.lock(); defer { lock.unlock() }
        return entries.compactMap { resolve($0) != nil ? project($0) : nil }
    }

    public func url(for id: UUID) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries.first(where: { $0.id == id }) else { return nil }
        return resolve(e)
    }

    public func touch(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].lastOpenedAt = .now
            save()
        }
    }

    /// Resolve o bookmark e mantém o acesso aberto enquanto o app viver (fecha em `remove`).
    private func resolve(_ e: Entry) -> URL? {
        if let u = resolved[e.id] {
            return u
        }
        var stale = false
        guard let u = try? URL(
            resolvingBookmarkData: e.bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        _ = u.startAccessingSecurityScopedResource()
        if stale, let fresh = try? u.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ),
            let i = entries.firstIndex(where: { $0.id == e.id })
        {
            entries[i].bookmark = fresh
            save()
        }
        resolved[e.id] = u
        return u
    }

    private func project(_ e: Entry) -> Project {
        Project(id: e.id, name: e.name, createdAt: e.createdAt, lastOpenedAt: e.lastOpenedAt, external: true)
    }
}
