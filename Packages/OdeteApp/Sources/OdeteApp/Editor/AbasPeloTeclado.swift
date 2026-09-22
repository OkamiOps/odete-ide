import OdeteCore
import OdeteEditor

/// Andar entre abas pelo teclado, e o nome pelo qual o editor conhece cada arquivo.
extension WorkspaceModel {
    /// Identificador do documento no editor — o mesmo `documentId` que o centro passa ao
    /// `CodeEditorView`. É por ele que o menu acha o editor do arquivo ativo.
    func documento(_ path: String) -> String {
        "\(project.id):\(path)"
    }

    var documentoAtivo: String? {
        active.map(documento)
    }

    /// Começo comum dos identificadores deste projeto, para soltar os editores das abas
    /// fechadas sem mexer nos de outro projeto aberto noutra janela.
    var prefixoDosDocumentos: String {
        "\(project.id):"
    }

    /// ⌃Tab e ⌃⇧Tab: a aba seguinte ou a anterior, dando a volta no fim da fila.
    func irParaAba(deslocamento: Int) {
        guard !tabs.isEmpty else { return }
        let n = tabs.count
        let atual = tabs.firstIndex { $0.path == active } ?? 0
        openFile(tabs[((atual + deslocamento) % n + n) % n].path)
    }

    /// ⌘1…⌘9: a aba de número `numero`, contando da esquerda a partir de 1.
    func irParaAba(numero: Int) {
        guard numero >= 1, numero <= tabs.count else { return }
        openFile(tabs[numero - 1].path)
    }
}
