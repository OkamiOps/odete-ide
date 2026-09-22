import Foundation
import OdeteCore

/// Operações sobre caminhos relativos à raiz do projeto.
public struct FileOps: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func url(_ rel: String) throws -> URL {
        guard rel.isEmpty || PathRules.validRelativePath(rel) else { throw FileError.outsideRoot(rel) }
        return rel.isEmpty ? root : root.appending(path: rel)
    }

    public func exists(_ rel: String) -> Bool {
        guard let u = try? url(rel) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    public func read(_ rel: String) throws -> String {
        let u = try url(rel)
        guard FileManager.default.fileExists(atPath: u.path) else { throw FileError.notFound(rel) }
        let data = try Data(contentsOf: u)
        // `String(decoding:as:)` não falha: byte inválido vira `\u{FFFD}`. Abrir um PNG
        // assim enchia o editor de losangos e, ao salvar, gravava os losangos por cima —
        // o arquivo original ia embora. Melhor dizer que não é texto.
        guard !Self.pareceBinario(data), let texto = String(data: data, encoding: .utf8) else {
            throw FileError.naoEhTexto(rel)
        }
        return texto
    }

    /// Byte zero é o sinal clássico de binário, e nenhum texto de verdade tem um. Olha só
    /// o começo: arquivo grande não precisa ser lido inteiro para se saber isso.
    public static func pareceBinario(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    public func write(_ rel: String, _ text: String) throws {
        let u = try url(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    public func createFile(_ rel: String, contents: String = "") throws {
        if exists(rel) {
            throw FileError.alreadyExists(rel)
        }
        try write(rel, contents)
    }

    public func createDirectory(_ rel: String) throws {
        if exists(rel) {
            throw FileError.alreadyExists(rel)
        }
        try FileManager.default.createDirectory(at: url(rel), withIntermediateDirectories: true)
    }

    /// Renomeia o último componente, mantendo a pasta.
    public func rename(_ rel: String, to newName: String) throws -> String {
        guard PathRules.validName(newName) else { throw FileError.invalidName(newName) }
        let parent = rel.split(separator: "/").dropLast().joined(separator: "/")
        let dest = parent.isEmpty ? newName : "\(parent)/\(newName)"
        try move(rel, to: dest)
        return dest
    }

    public func move(_ rel: String, to dest: String) throws {
        guard exists(rel) else { throw FileError.notFound(rel) }
        if exists(dest) {
            throw FileError.alreadyExists(dest)
        }
        if dest.hasPrefix(rel + "/") {
            throw FileError.outsideRoot(dest)
        }
        let to = try url(dest)
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url(rel), to: to)
    }

    /// Manda para a lixeira e devolve onde foi parar, para dar para desfazer.
    ///
    /// `removeItem` apagava de vez: arquivo que o git não rastreia sumia sem volta, e o
    /// apagar mora num menu de toque longo, fácil de acertar sem querer.
    @discardableResult
    public func delete(_ rel: String) throws -> URL? {
        guard exists(rel) else { throw FileError.notFound(rel) }
        let alvo = try url(rel)
        var lixo: NSURL?
        do {
            try FileManager.default.trashItem(at: alvo, resultingItemURL: &lixo)
            return lixo as URL?
        } catch {
            // No sandbox do iOS `trashItem` não funciona; na prática é sempre por aqui.
            // A lixeira do projeto faz o mesmo papel, e o desfazer traz de volta.
            try? FileManager.default.createDirectory(at: lixeira, withIntermediateDirectories: true)
            let destino = lixeira.appending(path: Self.nomeNaLixeira(rel, agora: Date()))
            do {
                try FileManager.default.moveItem(at: alvo, to: destino)
                podarLixeira()
                return destino
            } catch {
                try FileManager.default.removeItem(at: alvo)
                return nil
            }
        }
    }

    /// Nome do item dentro da lixeira: a hora, para não colidir, e o nome original.
    ///
    /// O que vem de `node_modules` (ou de `node_modules.nosync`) ganha `.nosync` no fim.
    /// A lixeira mora em `.odete/`, dentro do projeto, e num projeto do iCloud ela
    /// sincroniza: um pacote apagado pela árvore viraria centenas de arquivos subindo
    /// para a nuvem, para guardar o que um `npm install` refaz. O desfazer não sente a
    /// diferença, porque devolve para o caminho de origem, não para o nome da lixeira.
    static func nomeNaLixeira(_ rel: String, agora: Date) -> String {
        let nome = rel.split(separator: "/").last.map(String.init) ?? rel
        let base = "\(Int(agora.timeIntervalSince1970))-\(nome)"
        let deModulos = rel.split(separator: "/").contains {
            $0 == PastaDeModulos.nome || $0 == PastaDeModulos.nomeForaDaNuvem
        }
        return deModulos && !base.hasSuffix(".nosync") ? base + ".nosync" : base
    }

    /// Pasta da lixeira do projeto. Fica em `.odete/`, que o git já ignora por
    /// `.git/info/exclude`, então o que foi apagado não reaparece como arquivo novo.
    public var lixeira: URL {
        root.appending(path: ".odete/lixeira", directoryHint: .isDirectory)
    }

    /// Quanto a lixeira ocupa, para dar para decidir se vale esvaziar.
    public func tamanhoDaLixeira() -> Int {
        var total = 0
        let fm = FileManager.default
        guard let e = fm.enumerator(at: lixeira, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        for case let u as URL in e {
            total += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    public func esvaziarLixeira() {
        try? FileManager.default.removeItem(at: lixeira)
    }

    /// Guarda os mais novos e joga fora o resto: sem isto a lixeira só cresce, e num iPad
    /// espaço é o que falta primeiro.
    func podarLixeira(manter: Int = 50, dias: Int = 7) {
        let fm = FileManager.default
        guard let itens = try? fm.contentsOfDirectory(
            at: lixeira,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let limite = Date().addingTimeInterval(-Double(dias) * 86400)
        let ordenados = itens.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ??
                .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ??
                .distantPast
            return a > b
        }
        for (i, u) in ordenados.enumerated() {
            let data = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ??
                .distantPast
            if i >= manter || data < limite {
                try? fm.removeItem(at: u)
            }
        }
    }

    /// Traz de volta o que foi para a lixeira.
    public func restore(from lixo: URL, to rel: String) throws {
        let destino = try url(rel)
        try FileManager.default.createDirectory(
            at: destino.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: lixo, to: destino)
    }

    /// Data de modificação, para saber quando um arquivo aberto mudou por fora.
    public func modifiedAt(_ rel: String) -> Date? {
        guard let u = try? url(rel) else { return nil }
        return try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    public func isDirectory(_ rel: String) -> Bool {
        guard let u = try? url(rel) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Nome livre para "novo arquivo" dentro de uma pasta: `sem-titulo.txt`, `sem-titulo-2.txt`...
    public func freeName(in dir: String, base: String, ext: String) -> String {
        var n = 1
        while true {
            let name = n == 1 ? "\(base).\(ext)" : "\(base)-\(n).\(ext)"
            let rel = dir.isEmpty ? name : "\(dir)/\(name)"
            if !exists(rel) {
                return rel
            }
            n += 1
        }
    }
}
