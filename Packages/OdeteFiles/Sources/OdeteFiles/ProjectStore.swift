import CryptoKit
import Foundation
import OdeteCore
import OdeteI18n

/// Projetos em `<root>/<name>`, com um `.odete/project.json` guardando id e datas.
public struct ProjectStore: Sendable {
    public let root: URL

    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Projects", directoryHint: .isDirectory)
    }

    public init(root: URL = ProjectStore.defaultRoot()) {
        self.root = root
    }

    public func url(for project: Project) -> URL {
        root.appending(path: project.name, directoryHint: .isDirectory)
    }

    /// O projeto da raiz que mora exatamente nesta pasta, se houver.
    ///
    /// Abrir pelo app Arquivos a pasta de um projeto que já é do app registrava a mesma
    /// pasta como projeto externo: dois projetos, dois ids, e as duas cópias abertas ao
    /// mesmo tempo gravando uma por cima da outra.
    public func projeto(naPasta url: URL) -> Project? {
        let alvo = url.resolvingSymlinksInPath().standardizedFileURL.path
        let raiz = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard alvo.hasPrefix(raiz + "/") else { return nil }
        let resto = alvo.dropFirst(raiz.count + 1)
        guard !resto.isEmpty, !resto.contains("/") else { return nil }
        return (try? list())?.first { $0.name == String(resto) }
    }

    private func metaURL(_ dir: URL) -> URL {
        dir.appending(path: ".odete/project.json")
    }

    public func list() throws -> [Project] {
        try listar().projetos
    }

    /// O que a listagem achou. `aguardando` conta os projetos cujo `project.json` ainda
    /// está na nuvem: o download já foi pedido, e vale listar de novo daqui a pouco.
    public struct Listagem: Sendable {
        public var projetos: [Project]
        public var aguardando: Int
    }

    /// Lista os projetos. Um projeto com problema entra do jeito que dá (ver
    /// `provisorio`) e não derruba a lista: antes, um único erro fazia o hub vir vazio.
    public func listar() throws -> Listagem {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var out: [Project] = []
        var aguardando = 0
        for dir in items where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            switch lerMeta(dir) {
            case let .lido(p):
                out.append(p)
            case .ausente:
                // Pasta posta ali por fora (app Arquivos, outro app): o metadado nasce agora.
                let p = Project(name: dir.lastPathComponent, createdAt: criacao(dir) ?? .now)
                if (try? writeMeta(p, at: dir)) != nil {
                    out.append(p)
                } else {
                    out.append(provisorio(dir, id: nil))
                }
            case .naNuvem:
                aguardando += 1
                out.append(provisorio(dir, id: nil))
            case let .ilegivel(id):
                out.append(provisorio(dir, id: id))
            }
        }
        let ordenados = out.sorted { ($0.lastOpenedAt ?? $0.createdAt) > ($1.lastOpenedAt ?? $1.createdAt) }
        return Listagem(projetos: ordenados, aguardando: aguardando)
    }

    /// O que se sabe do `project.json` de uma pasta.
    enum LeituraDoMeta: Equatable {
        case lido(Project)
        /// Não existe, nem na nuvem.
        case ausente
        /// Existe no iCloud mas ainda não baixou — só o marcador `.project.json.icloud`.
        case naNuvem
        /// Existe e não decodifica. O id, quando dá para achar no texto, vem junto.
        case ilegivel(UUID?)
    }

    /// Lê sem nunca gravar. Quem grava decide pelo resultado: só `lido` e `ausente`
    /// podem ser escritos — por cima de `naNuvem` ou `ilegivel` o metadado de verdade,
    /// com o id que prende abas, rascunhos e conversas, seria trocado por um novo.
    func lerMeta(_ dir: URL) -> LeituraDoMeta {
        let meta = metaURL(dir)
        let fm = FileManager.default
        if let data = try? Data(contentsOf: meta) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if var p = try? dec.decode(Project.self, from: data) {
                p.name = dir.lastPathComponent
                return .lido(p)
            }
            // Um campo estragado não leva o id junto: ele está no texto, e é o que importa.
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return .ilegivel((obj?["id"] as? String).flatMap(UUID.init(uuidString:)))
        }
        let marcador = meta.deletingLastPathComponent().appending(path: ".project.json.icloud")
        let valores = try? meta.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        let naoBaixado = valores?.isUbiquitousItem == true && valores?.ubiquitousItemDownloadingStatus != .current
        if fm.fileExists(atPath: marcador.path) || naoBaixado {
            // Pede para baixar; quem listou tenta de novo depois (ver `Listagem.aguardando`).
            try? fm.startDownloadingUbiquitousItem(at: meta)
            return .naNuvem
        }
        if fm.fileExists(atPath: meta.path) {
            return .ilegivel(nil)
        }
        return .ausente
    }

    /// Um projeto cujo metadado não deu para ler: aparece no hub com um id que não muda
    /// de uma listagem para outra (tirado do nome da pasta), e nada é gravado.
    func provisorio(_ dir: URL, id: UUID?) -> Project {
        Project(
            id: id ?? Self.idDoNome(dir.lastPathComponent),
            name: dir.lastPathComponent,
            createdAt: criacao(dir) ?? Date(timeIntervalSince1970: 0)
        )
    }

    private func criacao(_ dir: URL) -> Date? {
        try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    /// Um UUID estável derivado do nome. `Hasher` não serve: muda a cada execução.
    static func idDoNome(_ nome: String) -> UUID {
        var b = Array(SHA256.hash(data: Data("odete-projeto:\(nome)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50 // versão 5 (derivado de nome)
        b[8] = (b[8] & 0x3F) | 0x80 // variante RFC 4122
        return b.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    private func writeMeta(_ p: Project, at dir: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: dir.appending(path: ".odete"), withIntermediateDirectories: true)
        try enc.encode(p).write(to: metaURL(dir), options: .atomic)
    }

    @discardableResult
    public func create(name: String, template: Template = .blank) throws -> Project {
        try Self.criar(name: name, template: template, dentroDe: root).0
    }

    /// Cria o projeto dentro da pasta indicada, que não precisa ser a raiz do app.
    ///
    /// É o mesmo trabalho da criação normal, separado para servir também a uma pasta que
    /// a pessoa escolheu no app Arquivos — iCloud, Working Copy, um SSD externo. Devolve
    /// a pasta criada junto, porque quem cria fora da raiz precisa dela para guardar o
    /// acesso depois.
    @discardableResult
    public static func criar(name: String, template: Template, dentroDe pasta: URL) throws -> (Project, URL) {
        guard PathRules.validName(name) else { throw FileError.invalidName(name) }
        let dir = pasta.appending(path: name, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: dir.path) {
            throw FileError.alreadyExists(name)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (path, contents) in template.files(projectName: name) {
            let f = dir.appending(path: path)
            try FileManager.default.createDirectory(
                at: f.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: f, atomically: true, encoding: .utf8)
        }
        let p = Project(name: name)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: dir.appending(path: ".odete"), withIntermediateDirectories: true)
        try enc.encode(p).write(to: dir.appending(path: ".odete/project.json"), options: .atomic)
        return (p, dir)
    }

    public func rename(_ project: Project, to newName: String) throws -> Project {
        guard PathRules.validName(newName) else { throw FileError.invalidName(newName) }
        let from = url(for: project)
        let to = root.appending(path: newName, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: to.path) {
            throw FileError.alreadyExists(newName)
        }
        try FileManager.default.moveItem(at: from, to: to)
        var p = project
        p.name = newName
        switch lerMeta(to) {
        case var .lido(atual):
            atual.name = newName
            try writeMeta(atual, at: to)
            return atual
        case .ausente:
            try writeMeta(p, at: to)
        case .naNuvem, .ilegivel:
            // O metadado de verdade continua lá; o nome vem da pasta, não dele.
            break
        }
        return p
    }

    @discardableResult
    public func duplicate(_ project: Project) throws -> Project {
        var candidate = tr("%1$@ cópia", "\(project.name)")
        var n = 2
        while FileManager.default.fileExists(atPath: root.appending(path: candidate).path) {
            candidate = tr("%1$@ cópia %2$@", "\(project.name)", "\(n)")
            n += 1
        }
        let to = root.appending(path: candidate, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: url(for: project), to: to)
        let p = Project(name: candidate)
        try writeMeta(p, at: to)
        return p
    }

    public func delete(_ project: Project) throws {
        let dir = url(for: project)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw FileError.notFound(project.name) }
        try FileManager.default.removeItem(at: dir)
    }

    /// Marca a hora em que o projeto foi aberto.
    ///
    /// Relê o metadado antes: se ele baixou da nuvem depois da listagem, vale o id dele,
    /// não o provisório; se ainda não dá para ler, a hora fica só na memória.
    public func touch(_ project: Project) throws -> Project {
        let dir = url(for: project)
        switch lerMeta(dir) {
        case var .lido(atual):
            atual.lastOpenedAt = .now
            try writeMeta(atual, at: dir)
            return atual
        case .ausente:
            var p = project
            p.lastOpenedAt = .now
            try writeMeta(p, at: dir)
            return p
        case .naNuvem, .ilegivel:
            var p = project
            p.lastOpenedAt = .now
            return p
        }
    }
}
