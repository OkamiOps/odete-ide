import Runestone
import UIKit

/// O que o teclado físico e o menu Editar pedem ao editor.
public enum AcaoDoEditor: String, Sendable, CaseIterable {
    case indentar
    case desindentar
    case subirLinhas
    case descerLinhas
    case alternarComentario
    case duplicarLinhas
    case apagarLinhas
    case mostrarProblema
}

/// Porta de entrada dos comandos que vêm de fora do editor: a barra de menus e a paleta.
///
/// O menu não conhece `TextView` nenhum — ele sabe só qual documento está ativo. O
/// comando vai para o editor que está com o foco e, sem foco em nenhum (o clique veio
/// do menu com o cursor em outro painel), para o que mostra o documento ativo.
@MainActor
public enum ComandosDoEditor {
    /// `mesmoComOutroFoco` é para quem já tirou o foco do lugar de propósito (a paleta,
    /// que acabou de fechar). Vindo do menu, um atalho apertado com o cursor em outro
    /// campo de texto — o chat do agente, o terminal — não mexe no código.
    @discardableResult
    public static func executar(_ acao: AcaoDoEditor, documento: String?, mesmoComOutroFoco: Bool = false) -> Bool {
        guard let c = SessoesDoEditor.shared.alvo(documento: documento) else { return false }
        if !mesmoComOutroFoco, c.textView?.isEditing != true, UIResponder.primeiroRespondedor is UITextInput {
            return false
        }
        c.executar(acao)
        return true
    }

    /// Leva o cursor para a linha (e coluna) do documento. Devolve falso quando não há
    /// editor na tela para ele — aí quem chamou abre o arquivo pelo caminho de sempre.
    @discardableResult
    public static func irPara(_ alvo: AlvoDeLinha, documento: String?) -> Bool {
        guard let c = SessoesDoEditor.shared.alvo(documento: documento) else { return false }
        c.irPara(alvo)
        return true
    }
}

extension UIResponder {
    @MainActor private weak static var achado: UIResponder?

    /// Quem tem o foco do teclado agora. O UIKit não diz; mandar uma ação para "quem
    /// estiver com o foco" e ver quem responde é o jeito de descobrir.
    @MainActor static var primeiroRespondedor: UIResponder? {
        achado = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.odeteAcharPrimeiroRespondedor(_:)),
            to: nil,
            from: nil,
            for: nil
        )
        return achado
    }

    @objc private func odeteAcharPrimeiroRespondedor(_: Any) {
        UIResponder.achado = self
    }
}

extension CodeEditorView.Coordinator {
    func executar(_ acao: AcaoDoEditor) {
        guard let tv = textView else { return }
        hidePopup()
        switch acao {
        case .indentar:
            umPasso(tv) { tv.shiftRight() }
        case .desindentar:
            umPasso(tv) { tv.shiftLeft() }
        case .subirLinhas:
            // O Runestone já agrupa a remoção e a reinserção num passo só.
            tv.moveSelectedLinesUp()
        case .descerLinhas:
            tv.moveSelectedLinesDown()
        case .alternarComentario:
            let ns = linhas().ns
            let selecao = tv.selectedRange
            guard let estilo = LanguageMode.comentario(para: parent.language, em: ns, local: selecao.location)
            else { return }
            aplicar(EdicaoDeLinhas.alternarComentario(ns, selecao: selecao, estilo: estilo), em: tv)
        case .duplicarLinhas:
            aplicar(EdicaoDeLinhas.duplicar(linhas().ns, selecao: tv.selectedRange), em: tv)
        case .apagarLinhas:
            if let e = EdicaoDeLinhas.apagar(linhas().ns, selecao: tv.selectedRange) {
                aplicar(e, em: tv)
            }
        case .mostrarProblema:
            mostrarProblemaNoCursor()
        }
    }

    /// Faz de `corpo` um passo só no desfazer.
    ///
    /// O Runestone junta num grupo tudo o que é digitado dentro de um segundo. Sem fechar
    /// o grupo antes, um ⌘/ logo depois de digitar iria embora junto com a digitação no
    /// primeiro ⌘Z; sem fechar depois, a próxima tecla entraria no grupo do comando.
    func umPasso(_ tv: TextView, _ corpo: () -> Void) {
        let desfazer = tv.undoManager
        desfazer?.endUndoGrouping()
        desfazer?.beginUndoGrouping()
        corpo()
        desfazer?.endUndoGrouping()
    }

    /// Aplica uma troca calculada por `EdicaoDeLinhas` como um passo só.
    func aplicar(_ e: EdicaoDeTexto, em tv: TextView) {
        let ns = linhas().ns
        guard NSMaxRange(e.faixa) <= ns.length else { return }
        if ns.substring(with: e.faixa) == e.texto {
            tv.selectedRange = e.selecao
            return
        }
        editarPorDentro(tv, avisar: true) {
            trocarTrecho(tv, e.faixa, por: e.texto)
            let total = tamanhoDoDocumento(tv)
            let de = min(max(e.selecao.location, 0), total)
            tv.selectedRange = NSRange(location: de, length: min(e.selecao.length, total - de))
        }
    }

    /// Cursor na linha e coluna pedidas, com a linha a um terço do topo.
    func irPara(_ alvo: AlvoDeLinha) {
        guard let tv = textView else { return }
        let mapa = linhas()
        let linha = alvo.linhaPresa(total: mapa.quantidade)
        let destino = alvo.deslocamento(em: mapa)
        // `goToLine` monta o layout até a linha e devolve o foco ao editor; a coluna
        // vem depois, porque ele só sabe pôr o cursor no começo ou no fim.
        tv.goToLine(linha - 1, select: .beginning)
        tv.selectedRange = NSRange(location: destino, length: 0)
        centralizar(tv, linha: linha)
    }
}
