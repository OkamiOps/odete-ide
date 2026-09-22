import Foundation
import OdeteCore

/// Pastas de fora do app (Arquivos, iCloud, outros apps) abertas como projeto, guardadas
/// como bookmarks de segurança em `Documents/external.json`.
///
/// O acesso a uma pasta de fora é contado pelo sistema: cada `startAccessing…` precisa do
/// seu `stopAccessing…`. Antes, resolver um bookmark já abria o acesso, e ele nunca era
/// fechado — listar o hub abria todas as pastas externas, e cada consulta dos Atalhos,
/// que monta um registro novo, abria de novo sem fechar. Agora listar só resolve; o
/// acesso longo abre uma vez por projeto em `url(for:)` e fecha em `liberar` ou ao
/// remover; leituras curtas usam `comAcesso`, que abre e fecha em volta delas.
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
    /// Projetos com o acesso aberto por `url(for:)`.
    private var acessando: Set<UUID> = []
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

    deinit {
        for id in acessando {
            resolved[id]?.stopAccessingSecurityScopedResource()
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
        if acessando.remove(id) != nil {
            resolved[id]?.stopAccessingSecurityScopedResource()
        }
        resolved[id] = nil
        entries.removeAll { $0.id == id }
        save()
    }

    /// Projetos externos; pastas cujo bookmark não resolve mais ficam de fora. Só resolve:
    /// listar não abre acesso a pasta nenhuma.
    public func list() -> [Project] {
        lock.lock(); defer { lock.unlock() }
        return entries.compactMap { resolve($0) != nil ? project($0) : nil }
    }

    /// A pasta do projeto, com o acesso aberto — uma vez por projeto, até `liberar(_:)`.
    ///
    /// É para o projeto aberto no workspace, que lê e grava a pasta o tempo todo. Chamar de
    /// novo não abre de novo.
    public func url(for id: UUID) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries.first(where: { $0.id == id }), let u = resolve(e) else { return nil }
        if !acessando.contains(id), u.startAccessingSecurityScopedResource() {
            acessando.insert(id)
        }
        return u
    }

    /// Fecha o acesso que `url(for:)` abriu.
    public func liberar(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if acessando.remove(id) != nil {
            resolved[id]?.stopAccessingSecurityScopedResource()
        }
    }

    /// Fecha o acesso de todos os projetos, menos o de `exceto` — o que está aberto.
    public func liberarTodos(exceto: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        for id in acessando where id != exceto {
            resolved[id]?.stopAccessingSecurityScopedResource()
            acessando.remove(id)
        }
    }

    /// Quantos projetos estão com o acesso aberto agora.
    public var abertos: Int {
        lock.lock(); defer { lock.unlock() }
        return acessando.count
    }

    /// Roda `corpo` com a pasta acessível só enquanto ele roda — para ler a pasta (o
    /// cartão do hub, o zip de compartilhar) sem deixá-la aberta depois.
    public func comAcesso<T>(_ id: UUID, _ corpo: (URL) throws -> T) rethrows -> T? {
        lock.lock()
        let u = entries.first(where: { $0.id == id }).flatMap { resolve($0) }
        lock.unlock()
        guard let u else { return nil }
        let abriu = u.startAccessingSecurityScopedResource()
        defer {
            if abriu {
                u.stopAccessingSecurityScopedResource()
            }
        }
        return try corpo(u)
    }

    public func touch(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].lastOpenedAt = .now
            save()
        }
    }

    /// Resolve o bookmark e guarda a URL. Não abre acesso — ver `url(for:)`.
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
        if stale {
            // Refazer o bookmark pede a pasta acessível: abre só para isso e fecha.
            let abriu = u.startAccessingSecurityScopedResource()
            if let fresh = try? u.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ),
                let i = entries.firstIndex(where: { $0.id == e.id })
            {
                entries[i].bookmark = fresh
                save()
            }
            if abriu {
                u.stopAccessingSecurityScopedResource()
            }
        }
        resolved[e.id] = u
        return u
    }

    private func project(_ e: Entry) -> Project {
        Project(id: e.id, name: e.name, createdAt: e.createdAt, lastOpenedAt: e.lastOpenedAt, external: true)
    }
}
