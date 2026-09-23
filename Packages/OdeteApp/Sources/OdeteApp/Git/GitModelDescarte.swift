import Foundation
import OdeteFiles
import OdeteGit
import OdeteI18n

// Descarte com lixeira e desfazer. Mora fora de `GitModel.swift` só pelo tamanho.

public extension GitModel {
    /// Um arquivo mandado para a lixeira do projeto por um descarte, para o desfazer.
    struct DiscardedFile: Sendable, Hashable {
        public var path: String
        /// Onde a versão descartada foi parar; `nil` quando não havia arquivo (apagado).
        public var trashed: URL?
        public var tracked: Bool
    }
}

extension GitModel {
    /// Quantos dos caminhos o git rastreia e quantos não: a confirmação do descarte diz
    /// os dois, porque o destino de cada um é diferente.
    public func discardCount(_ paths: [String]) -> (tracked: Int, untracked: Int) {
        let naoRastreados = paths.filter { p in status.first { $0.path == p }?.unstaged == .untracked }.count
        return (paths.count - naoRastreados, naoRastreados)
    }

    /// Descarta as alterações fora do stage, com volta.
    ///
    /// Era sem confirmação e o não rastreado era apagado de vez. Agora a tela confirma
    /// antes, e cada arquivo vai primeiro para a lixeira do projeto: o não rastreado
    /// sai assim, e o rastreado deixa lá a versão que o checkout troca pela do índice.
    /// "Desfazer" traz os dois de volta.
    public func discard(_ paths: [String]) {
        let naoRastreados = Set(paths.filter { p in status.first { $0.path == p }?.unstaged == .untracked })
        let root = root
        run("descartando…") { repo in
            let lote = Self.discardFolder(root)
            var guardados: [DiscardedFile] = []
            do {
                for p in paths {
                    let lixo = try Self.moveToTrash(p, root: root, folder: lote)
                    guardados.append(DiscardedFile(path: p, trashed: lixo, tracked: !naoRastreados.contains(p)))
                }
                try await repo.discard(paths.filter { !naoRastreados.contains($0) })
            } catch {
                // Nada pela metade: o que já foi para a lixeira volta para o lugar.
                Self.bringBack(guardados, root: root)
                throw error
            }
            await self.remember(guardados)
            return paths.count == 1 ? tr("1 arquivo descartado") : tr("%1$@ arquivos descartados", "\(paths.count)")
        }
    }

    /// Traz de volta o último descarte. O que estiver no lugar agora também vai para a
    /// lixeira antes, para o desfazer não virar outra perda.
    public func undoDiscard() {
        let itens = discarded
        guard !itens.isEmpty else { return }
        let root = root
        run("desfazendo…") { _ in
            let lote = Self.discardFolder(root)
            for item in itens {
                _ = try Self.moveToTrash(item.path, root: root, folder: lote)
            }
            Self.bringBack(itens, root: root)
            return tr("descarte desfeito")
        }
    }

    func remember(_ itens: [DiscardedFile]) {
        discarded = itens
    }

    /// Uma pasta por descarte dentro da lixeira do projeto (`FileOps.lixeira`), com o
    /// caminho inteiro do arquivo: dois `index.js` de pastas diferentes não disputam o
    /// mesmo nome lá dentro.
    nonisolated static func discardFolder(_ root: URL) -> URL {
        let carimbo = Int(Date().timeIntervalSince1970 * 1000)
        return FileOps(root: root).lixeira.appending(path: "\(carimbo)-descarte-git", directoryHint: .isDirectory)
    }

    /// Move o arquivo para a pasta do descarte; `nil` quando ele não existe no disco.
    nonisolated static func moveToTrash(_ path: String, root: URL, folder: URL) throws -> URL? {
        let origem = root.appending(path: path)
        guard FileManager.default.fileExists(atPath: origem.path) else { return nil }
        let destino = folder.appending(path: path)
        try FileManager.default.createDirectory(
            at: destino.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: origem, to: destino)
        return destino
    }

    nonisolated static func bringBack(_ itens: [DiscardedFile], root: URL) {
        for item in itens {
            let destino = root.appending(path: item.path)
            try? FileManager.default.removeItem(at: destino)
            guard let lixo = item.trashed else { continue }
            try? FileManager.default.createDirectory(
                at: destino.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.moveItem(at: lixo, to: destino)
        }
    }
}
