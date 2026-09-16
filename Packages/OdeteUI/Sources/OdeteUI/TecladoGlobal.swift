import GameController
import OdeteI18n
import UIKit

/// Recolher o teclado, em qualquer campo do app.
///
/// No iPhone o teclado cobre a barra de abas, e num app assim se digita em toda parte:
/// busca, renomear arquivo, mensagem de commit, URL do remoto, célula do banco, comando
/// do terminal. Pôr um botão dentro de cada uma dessas telas seria quarenta botões em
/// quarenta lugares diferentes — e no dia seguinte alguém acrescenta o quadragésimo
/// primeiro campo sem botão nenhum.
///
/// O jeito que fecha é pelo próprio teclado: todo campo que entra em edição ganha uma
/// barra acessória com o botão de recolher. `UITextField` e `UITextView` avisam quando
/// começam a ser editados, e é só nesse momento que a barra é pendurada — não há
/// varredura de hierarquia nem troca de método de sistema.
@MainActor
public enum Teclado {
    /// Tira o foco de quem estiver com ele, seja `@FocusState` ou primeiro respondedor
    /// do UIKit.
    public static func recolhe() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Se há teclado físico ligado. É ponto de troca porque o simulador enxerga o
    /// teclado do Mac: sem isso o mesmo teste passa numa máquina e falha na outra.
    static var temTecladoFisico: () -> Bool = { GCKeyboard.coalesced != nil }

    private static var ouvinte: Ouvinte?

    /// Liga a barra para o app inteiro. Chamar mais de uma vez não faz nada.
    public static func instalaBarra() {
        guard ouvinte == nil else { return }
        let o = Ouvinte()
        ouvinte = o
        for nome in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            NotificationCenter.default.addObserver(o, selector: #selector(Ouvinte.comecou(_:)), name: nome, object: nil)
        }
    }

    /// `Notification` não é `Sendable`, então o aviso chega por seletor do ObjC — que o
    /// UIKit posta na main thread — em vez de um bloco que teria de atravessar isolamento.
    @MainActor
    private final class Ouvinte: NSObject {
        @objc func comecou(_ nota: Notification) {
            Teclado.pendura(nota.object)
        }
    }

    static func pendura(_ alvo: Any?) {
        guard let campo = alvo as? UIResponder, let view = alvo as? UIView else { return }
        // Já tem barra própria: o editor de código traz a dele, com parênteses, setas e
        // o próprio botão de recolher. Duas barras empilhadas seria pior que nenhuma.
        //
        // A checagem é por `UIInputView` e não por "tem alguma coisa pendurada": o
        // SwiftUI deixa um acessório vazio em campo que nem pediu barra, e com a regra
        // larga a barra não aparecia em lugar nenhum.
        if campo.inputAccessoryView is UIInputView {
            return
        }
        // O compositor do agente tem o botão ao lado do de enviar, onde a mão já está.
        if view is SendingTextView {
            return
        }
        // Com teclado físico o teclado de software não aparece, e a barra viraria uma
        // faixa flutuante no rodapé atrapalhando quem só queria digitar.
        if temTecladoFisico() {
            return
        }
        let barra = BarraDeRecolher()
        if let tf = view as? UITextField {
            tf.inputAccessoryView = barra
            tf.reloadInputViews()
        } else if let tv = view as? UITextView {
            tv.inputAccessoryView = barra
            tv.reloadInputViews()
        }
    }
}

/// A barra em si: um botão só, encostado na borda de fechar a leitura.
final class BarraDeRecolher: UIInputView {
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        var cfg = UIButton.Configuration.glass()
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        cfg.image = UIImage(
            systemName: "keyboard.chevron.compact.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        )
        let botao = UIButton(configuration: cfg, primaryAction: UIAction { _ in Teclado.recolhe() })
        botao.accessibilityLabel = tr("Esconder o teclado")
        botao.translatesAutoresizingMaskIntoConstraints = false
        addSubview(botao)
        NSLayoutConstraint.activate([
            botao.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            botao.centerYAnchor.constraint(equalTo: centerYAnchor),
            botao.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            botao.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
