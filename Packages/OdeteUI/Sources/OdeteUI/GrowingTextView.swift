import SwiftUI
import UIKit

/// Campo de texto que cresce com o conteúdo e separa Enter de shift+Enter.
///
/// O `TextField` do SwiftUI não sabe fazer essa separação: `onSubmit` dispara com
/// qualquer Enter e `onKeyPress` devolvendo `.ignored` não chega a inserir a quebra.
/// Aqui é um `UITextView` que decide o que fazer com o "\n" quando ele chega ao delegate,
/// na ordem das outras teclas — ver `SendingTextView`.
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
        // Aqui se digita caminho e identificador no meio da frase, e a correção do iOS
        // troca em silêncio: "src/dados.ts" virou "sic/dados.ts" e o pedido foi para o
        // agente com o caminho errado. As aspas e os travessões espertos estragam código
        // e flag de linha de comando do mesmo jeito. O corretor ortográfico fica: ele
        // sublinha e não mexe.
        v.autocorrectionType = .no
        v.smartQuotesType = .no
        v.smartDashesType = .no
        v.smartInsertDeleteType = .no
        v.spellCheckingType = .yes
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
        context.coordinator.pai = self
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

        public func textViewDidEndEditing(_ v: UITextView) {
            pai.focused = false
            (v as? SendingTextView)?.esquecerReturns()
        }

        /// Todo "\n" passa por aqui, na fila do sistema de texto: as teclas de antes do Enter
        /// já foram inseridas e já passaram por `textViewDidChange`.
        public func textView(
            _ tv: UITextView,
            shouldChangeTextInRanges _: [NSValue],
            replacementText texto: String
        ) -> Bool {
            guard let v = tv as? SendingTextView, v.onSend != nil,
                  SendingTextView.ehQuebraDeLinha(texto) else { return true }
            let marcado = v.markedTextRange != nil
            guard let modificadores = v.retirarReturn() else {
                // Nenhum Return físico na fila: é o Return do teclado virtual, ou uma quebra
                // colada, e quebra a linha. Com o Enter físico ainda apertado é a repetição da
                // tecla, e essa não quebra: o envio já foi.
                return !v.segurandoReturn
            }
            guard SendingTextView.deveEnviar(
                texto: texto,
                returnDeHardware: true,
                modificadores: modificadores,
                marcado: marcado
            ) else { return true }
            enviar(v)
            return false
        }

        func enviar(_ v: SendingTextView) {
            // `textViewDidChange` já levou as teclas de antes para o binding; isto só garante.
            if pai.text != v.text {
                pai.text = v.text
            }
            v.onSend?()
            // O envio costuma limpar o rascunho. O campo acompanha já, e não no próximo
            // `updateUIView`: uma tecla digitada logo depois do Enter, ainda na fila, entraria
            // no texto velho, e o `textViewDidChange` dela devolveria o rascunho inteiro.
            let depois = pai.text
            if v.text != depois {
                v.text = depois
                v.dica.isHidden = !depois.isEmpty
            }
        }
    }
}

/// `UITextView` que trata o Enter sem modificador do teclado físico como "enviar".
///
/// O Enter não é um `UIKeyCommand`, e isto é de propósito. O atalho dispara no instante em
/// que a tecla desce, fora da fila em que o sistema de texto insere as teclas (a do teclado,
/// do corretor). Digitando rápido, as últimas letras antes do Enter ainda estavam nessa fila:
/// "turno um" + Enter enviava "Turno", e o "um" caía depois no campo já limpo.
///
/// Agora a tecla só é anotada quando desce (`pressesBegan`, antes do `super`), e quem decide
/// é o delegate quando o "\n" dela chega (`shouldChangeTextInRanges`), na mesma fila e
/// depois de todas as teclas de antes. As anotações ficam em fila, como as teclas:
/// shift+Enter e logo depois Enter dão quebra e depois envio, nessa ordem.
///
/// - Enter sem modificador envia; shift e option+Enter quebram a linha.
/// - control e command+Enter nem são anotados: ficam com o que o sistema fizer.
/// - O Return do teclado virtual não passa por `pressesBegan` e quebra a linha (o envio ali
///   é o botão).
/// - Com texto marcado (IME, ditado) o Enter confirma a composição e não envia.
///
/// O Esc não insere nada no texto, então não tem corrida e continua `UIKeyCommand`.
public final class SendingTextView: UITextView {
    var onSend: (() -> Void)?
    var onEscape: (() -> Void)?
    let dica = UILabel()

    /// Um Return físico que já desceu e cujo "\n" ainda não chegou ao delegate.
    struct ReturnNaFila {
        var modificadores: UIKeyModifierFlags
        var desceuEm: TimeInterval
    }

    private(set) var returnsNaFila: [ReturnNaFila] = []
    /// Enter sem modificador apertado agora.
    private(set) var segurandoReturn = false
    var relogio: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Anotação mais velha que isto não é mais da fila de teclas, que anda em milissegundos:
    /// é de um Return que confirmou texto marcado sem inserir "\n". Sem prazo ela ficaria
    /// para sempre, e o próximo shift+Enter a tomaria por sua e enviaria.
    nonisolated static let validadeDaAnotacao: TimeInterval = 3

    /// Os modificadores que mudam o que o Enter faz. Caps lock e o "numérico" do Enter do
    /// teclado numérico não mudam.
    nonisolated static let modificadoresDoEnter: UIKeyModifierFlags = [.shift, .alternate, .control, .command]

    /// Envia? Só o "\n" de um Return físico sem modificador, fora de composição.
    nonisolated static func deveEnviar(
        texto: String,
        returnDeHardware: Bool,
        modificadores: UIKeyModifierFlags,
        marcado: Bool
    ) -> Bool {
        guard ehQuebraDeLinha(texto), returnDeHardware, !marcado else { return false }
        return modificadores.isDisjoint(with: modificadoresDoEnter)
    }

    nonisolated static func ehQuebraDeLinha(_ texto: String) -> Bool {
        texto.count == 1 && texto.first?.isNewline == true
    }

    static func ehReturn(_ k: UIKey) -> Bool {
        k.keyCode == .keyboardReturnOrEnter || k.keyCode == .keyboardReturn || k.keyCode == .keypadEnter
    }

    override public var keyCommands: [UIKeyCommand]? {
        guard onEscape != nil else { return [] }
        return [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapar))]
    }

    override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Antes do `super`: com a fila vazia o sistema insere o "\n" ali dentro mesmo.
        for p in presses {
            if let k = p.key, Self.ehReturn(k) {
                anotarReturn(modificadores: k.modifierFlags)
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override public func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key.map(Self.ehReturn) == true }) {
            soltouReturn()
        }
        super.pressesEnded(presses, with: event)
    }

    override public func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key.map(Self.ehReturn) == true }) {
            soltouReturn()
        }
        super.pressesCancelled(presses, with: event)
    }

    func anotarReturn(modificadores: UIKeyModifierFlags) {
        guard onSend != nil, markedTextRange == nil else { return }
        let m = modificadores.intersection(Self.modificadoresDoEnter)
        // Não se sabe se o sistema insere "\n" com control ou command; se não inserir, a
        // anotação ficaria à espera de um "\n" que é de outra tecla.
        guard m.isDisjoint(with: [.control, .command]) else { return }
        descartarVencidas()
        returnsNaFila.append(ReturnNaFila(modificadores: m, desceuEm: relogio()))
        if m.isEmpty {
            segurandoReturn = true
        }
    }

    func soltouReturn() {
        segurandoReturn = false
    }

    /// Os modificadores do Return mais antigo ainda na fila, que sai dela; nil se não há.
    func retirarReturn() -> UIKeyModifierFlags? {
        descartarVencidas()
        return returnsNaFila.isEmpty ? nil : returnsNaFila.removeFirst().modificadores
    }

    func esquecerReturns() {
        returnsNaFila = []
        segurandoReturn = false
    }

    private func descartarVencidas() {
        let agora = relogio()
        returnsNaFila.removeAll { agora - $0.desceuEm > Self.validadeDaAnotacao }
    }

    @objc private func escapar() {
        onEscape?()
    }
}
