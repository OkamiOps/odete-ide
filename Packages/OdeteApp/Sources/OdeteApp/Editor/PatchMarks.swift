import OdeteAgent
import OdeteEditor

/// De onde saem as linhas verdes e o fio vermelho do patch pendente dentro do editor.
enum PatchMarks {
    /// Compara o texto de antes do agente com o que está na tela agora.
    ///
    /// A comparação é com o texto de antes, e não com o que o agente escreveu, para a
    /// marcação continuar certa depois de a pessoa editar por cima da alteração.
    static func linhas(antes: String, agora: String) -> [EditorLineChange] {
        var out: [EditorLineChange] = []
        for h in LineDiff.hunks(antes, agora, context: 0) {
            var linha = h.afterStart
            for l in h.lines {
                switch l {
                case .context:
                    linha += 1
                case .added:
                    out.append(EditorLineChange(line: linha, kind: .added))
                    linha += 1
                case .removed:
                    // Uma marca só por ponto de remoção, não uma por linha sumida.
                    if out.last != EditorLineChange(line: linha, kind: .removed) {
                        out.append(EditorLineChange(line: linha, kind: .removed))
                    }
                }
            }
        }
        return out
    }
}
