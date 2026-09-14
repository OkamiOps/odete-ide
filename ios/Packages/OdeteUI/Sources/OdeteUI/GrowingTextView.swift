import SwiftUI
import UIKit

/// Campo de texto que cresce com o conteúdo e separa Enter de shift+Enter.
///
/// O `TextField` do SwiftUI não sabe fazer essa separação: `onSubmit` dispara com
/// qualquer Enter e `onKeyPress` devolvendo `.ignored` não chega a inserir a quebra.
/// Aqui é um `UITextView` com um atalho de teclado registrado só para o Enter sem
/// modificador; shift+Enter não casa com o atalho e cai no caminho normal do texto,
/// que insere a quebra de linha na posição do cursor.
public struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat
    var maxHeight: CGFloat
    /// Muda de valor quando alguém pede o foco de fora.
    var focusRequest: Int
    @Binding var focused: Bool
    var onSend: (() -> Void)?
    var onEscape: (() -> Void)?

    public init(
        text: Binding<String>,
        placeholder: String,
        minHeight: CGFloat = 22,
        maxHeight: CGFloat = 220,
        focusRequest: Int = 0,
        focused: Binding<Bool>,
        onSend: (() -> Void)? = nil,
        onEscape: (() -> Void)? = nil
    ) {
        _text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.focusRequest = focusRequest
        _focused = focused
        self.onSend = onSend
        self.onEscape = onEscape
    }

    public func makeUIView(context: Context) -> SendingTextView {
        let v = SendingTextView()
        v.delegate = context.coordinator
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.isScrollEnabled = false
        v.adjustsFontForContentSizeCategory = true
        v.keyboardDismissMode = .interactive
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.dica.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(v.dica)
        NSLayoutConstraint.activate([
            v.dica.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            v.dica.topAnchor.constraint(equalTo: v.topAnchor),
            v.dica.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor),
        ])
        return v
    }

    public func updateUIView(_ v: SendingTextView, context: Context) {
        if v.text != text {
            v.text = text
        }
        let fonte = UIFont.preferredFont(forTextStyle: .subheadline)
        v.font = fonte
        v.dica.font = fonte
        v.textColor = UIColor(context.environment.theme.fg)
        v.tintColor = UIColor(context.environment.theme.accent)
        v.dica.text = placeholder
        v.dica.textColor = UIColor(context.environment.theme.fgSubtle)
        v.dica.isHidden = !text.isEmpty
        v.onSend = onSend
        v.onEscape = onEscape
        if context.coordinator.ultimoPedido != focusRequest {
            context.coordinator.ultimoPedido = focusRequest
            if focusRequest > 0 {
                DispatchQueue.main.async { v.becomeFirstResponder() }
            }
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, uiView v: SendingTextView, context _: Context) -> CGSize? {
        let largura = proposal.width ?? v.bounds.width
        guard largura > 0 else { return nil }
        let cabe = v.sizeThatFits(CGSize(width: largura, height: .greatestFiniteMagnitude)).height
        v.isScrollEnabled = cabe > maxHeight
        return CGSize(width: largura, height: min(max(cabe, minHeight), maxHeight))
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public final class Coordinator: NSObject, UITextViewDelegate {
        var pai: GrowingTextView
        var ultimoPedido = 0

        init(_ pai: GrowingTextView) {
            self.pai = pai
        }

        public func textViewDidChange(_ v: UITextView) {
            pai.text = v.text
            (v as? SendingTextView)?.dica.isHidden = !v.text.isEmpty
        }

        public func textViewDidBeginEditing(_: UITextView) {
            pai.focused = true
        }

        public func textViewDidEndEditing(_: UITextView) {
            pai.focused = false
        }
    }
}

/// `UITextView` que trata o Enter sem modificador como "enviar". Shift+Enter, option
/// e control não casam com o atalho e quebram a linha normalmente.
public final class SendingTextView: UITextView {
    var onSend: (() -> Void)?
    var onEscape: (() -> Void)?
    let dica = UILabel()

    override public var keyCommands: [UIKeyCommand]? {
        var cmds: [UIKeyCommand] = []
        if onSend != nil {
            let enviar = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(enviar))
            enviar.wantsPriorityOverSystemBehavior = true
            cmds.append(enviar)
        }
        if onEscape != nil {
            cmds.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapar)))
        }
        return cmds
    }

    @objc private func enviar() {
        onSend?()
    }

    @objc private func escapar() {
        onEscape?()
    }
}
