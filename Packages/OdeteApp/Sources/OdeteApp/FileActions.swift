import Foundation

/// Desfazer de ação de arquivo: mover, renomear e apagar deixam de ser definitivos.
public extension WorkspaceModel {
    /// O que dá para desfazer em arquivo. Só a última ação: mais que isso, com o disco
    /// mudando por fora, vira promessa que não dá para cumprir.
    enum AcaoArquivo {
        case movido(de: String, para: String)
        case renomeado(de: String, para: String)
        case apagado(path: String, lixo: URL?)

        public var descricao: String {
            switch self {
            case let .movido(de, _): "mover \(nome(de))"
            case let .renomeado(de, _): "renomear \(nome(de))"
            case let .apagado(path, _): "apagar \(nome(path))"
            }
        }

        public var podeDesfazer: Bool {
            if case let .apagado(_, lixo) = self {
                return lixo != nil
            }
            return true
        }

        private func nome(_ p: String) -> String {
            p.split(separator: "/").last.map(String.init) ?? p
        }
    }

    /// Joga fora o que estava guardado para o desfazer. A ação de desfazer que apontava
    /// para lá deixa de valer junto — senão o menu oferece restaurar um arquivo que não
    /// existe mais.
    func esvaziarLixeira() {
        ops.esvaziarLixeira()
        lixeira = 0
        if case .apagado = ultimaAcao {
            ultimaAcao = nil
        }
    }

    /// Desfaz a última ação de arquivo: tirar do lugar por engano, ou apagar sem querer,
    /// deixa de ser definitivo.
    func desfazerArquivo() {
        guard let a = ultimaAcao else { return }
        ultimaAcao = nil
        switch a {
        case let .movido(de, para):
            let pasta = de.split(separator: "/").dropLast().joined(separator: "/")
            move(para, into: pasta, registrando: false)
        case let .renomeado(de, para):
            rename(para, to: de.split(separator: "/").last.map(String.init) ?? de, registrando: false)
        case let .apagado(path, lixo):
            guard let lixo else { return }
            do {
                try ops.restore(from: lixo, to: path)
                reload()
            } catch { self.error = error.localizedDescription }
        }
    }
}
