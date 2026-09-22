import Foundation
import Synchronization

public struct Patch: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, accepted, rejected, undone }
    public var id: String
    public var path: String
    /// Texto de antes. Trocar refaz o diff — uma vez, aqui.
    public var before: String {
        get { antes }
        set { antes = newValue; recalcular() }
    }

    /// Texto de depois. Idem.
    public var after: String {
        get { depois }
        set { depois = newValue; recalcular() }
    }

    public var orig: String
    public var status: Status
    public var at: Date
    /// O diff, guardado junto com o texto de que ele saiu.
    ///
    /// Eram propriedades calculadas: cada leitura rodava o LCS inteiro. O cartão do patch
    /// lia `additions`, `deletions` e `hunks` — mais uma vez por hunk — a cada redesenho,
    /// e o centro mais duas; com a tabela antiga isso chegava a dezenas de megabytes
    /// alocados por quadro. Agora o diff nasce quando o texto muda e as leituras só leem.
    public private(set) var hunks: [Hunk] = []
    public private(set) var additions = 0
    public private(set) var deletions = 0

    private var antes: String
    private var depois: String

    public init(
        id: String,
        path: String,
        before: String,
        after: String,
        orig: String,
        status: Status,
        at: Date
    ) {
        self.id = id
        self.path = path
        antes = before
        depois = after
        self.orig = orig
        self.status = status
        self.at = at
        recalcular()
    }

    /// Troca os dois textos com um diff só, em vez de um por atribuição.
    public mutating func trocar(before: String, after: String) {
        antes = before
        depois = after
        recalcular()
    }

    private mutating func recalcular() {
        hunks = LineDiff.hunks(antes, depois)
        var mais = 0, menos = 0
        for h in hunks {
            for l in h.lines {
                switch l {
                case .added: mais += 1
                case .removed: menos += 1
                case .context: break
                }
            }
        }
        additions = mais
        deletions = menos
    }

    enum CodingKeys: String, CodingKey { case id, path, before, after, orig, status, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id),
            path: c.decode(String.self, forKey: .path),
            before: c.decode(String.self, forKey: .before),
            after: c.decode(String.self, forKey: .after),
            orig: c.decode(String.self, forKey: .orig),
            status: c.decode(Status.self, forKey: .status),
            at: c.decode(Date.self, forKey: .at)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(antes, forKey: .before)
        try c.encode(depois, forKey: .after)
        try c.encode(orig, forKey: .orig)
        try c.encode(status, forKey: .status)
        try c.encode(at, forKey: .at)
    }

    /// Igualdade pelo que o patch é, não pelo diff: o diff sai do texto, e comparar os
    /// hunks de novo seria pagar duas vezes pela mesma resposta.
    public static func == (l: Patch, r: Patch) -> Bool {
        l.id == r.id && l.path == r.path && l.status == r.status && l.at == r.at && l.antes == r.antes
            && l.depois == r.depois && l.orig == r.orig
    }

    public func hash(into h: inout Hasher) {
        h.combine(id)
        h.combine(path)
        h.combine(status)
        h.combine(antes)
        h.combine(depois)
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
                list[i].trocar(before: list[i].orig, after: after)
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
        // Trocar `before` já refaz o diff; o que sobrou é o que ele diz.
        update(id) {
            $0.before = next
            if $0.hunks.isEmpty {
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
