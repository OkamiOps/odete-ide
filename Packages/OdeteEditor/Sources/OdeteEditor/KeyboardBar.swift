import OdeteI18n
import Runestone
import UIKit

/// Barra acessória do teclado: Tab, pares, setas, desfazer/refazer, buscar e salvar.
final class KeyboardBar: UIInputView {
    private weak var textView: TextView?
    var onSave: () -> Void
    var onFind: () -> Void
    /// Ir para onde o nome sob o cursor é declarado. Sem teclado físico não há ⌘⌃J, e
    /// esta barra é onde a mão já está enquanto se escreve.
    var onDefinition: () -> Void
    /// Manda a seleção (ou a linha do cursor) para o compositor do agente.
    var onSendSelection: () -> Void

    init(
        textView: TextView,
        onSave: @escaping () -> Void,
        onFind: @escaping () -> Void,
        onDefinition: @escaping () -> Void,
        onSendSelection: @escaping () -> Void
    ) {
        self.textView = textView
        self.onSave = onSave
        self.onFind = onFind
        self.onDefinition = onDefinition
        self.onSendSelection = onSendSelection
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        // Recolher o teclado fica fora da rolagem, encostado na borda. Dentro dela era o
        // último de dezesseis: no iPhone quem quisesse fechar o teclado tinha que arrastar
        // a barra inteira até o fim para achar o botão.
        let recolher = botao(title: "", symbol: "keyboard.chevron.compact.down") { [weak self] in
            self?.textView?.resignFirstResponder()
        }
        recolher.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recolher)
        NSLayoutConstraint.activate([
            recolher.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -8),
            recolher.centerYAnchor.constraint(equalTo: centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: recolher.leadingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -5),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -10),
        ])
        let items: [(String, String?, () -> Void)] = [
            ("⇥", nil, { [weak self] in self?.textView?.insertText("  ") }),
            ("{ }", nil, { [weak self] in self?.wrap("{", "}") }),
            ("( )", nil, { [weak self] in self?.wrap("(", ")") }),
            ("[ ]", nil, { [weak self] in self?.wrap("[", "]") }),
            ("< >", nil, { [weak self] in self?.wrap("<", ">") }),
            ("\" \"", nil, { [weak self] in self?.wrap("\"", "\"") }),
            ("=>", nil, { [weak self] in self?.textView?.insertText("=>") }),
            ("", "arrow.left", { [weak self] in self?.move(-1) }),
            ("", "arrow.right", { [weak self] in self?.move(1) }),
            ("", "arrow.uturn.backward", { [weak self] in self?.textView?.undoManager?.undo() }),
            ("", "arrow.uturn.forward", { [weak self] in self?.textView?.undoManager?.redo() }),
            ("", "magnifyingglass", { [weak self] in self?.onFind() }),
            ("", "f.cursive", { [weak self] in self?.onDefinition() }),
            ("", "sparkles", { [weak self] in self?.onSendSelection() }),
            ("", "square.and.arrow.down", { [weak self] in self?.onSave() }),
        ]
        for (title, symbol, action) in items {
            stack.addArrangedSubview(botao(title: title, symbol: symbol, action: action))
        }
    }

    private func botao(title: String, symbol: String?, action: @escaping () -> Void) -> UIButton {
        var cfg = UIButton.Configuration.glass()
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        if let symbol {
            cfg.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            )
        } else {
            cfg.attributedTitle = AttributedString(
                title,
                attributes: AttributeContainer().font(.monospacedSystemFont(ofSize: 14, weight: .medium))
            )
        }
        let b = UIButton(configuration: cfg, primaryAction: UIAction { _ in action() })
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        if symbol == "keyboard.chevron.compact.down" {
            b.accessibilityLabel = tr("Esconder o teclado")
        }
        return b
    }

    private func wrap(_ l: String, _ r: String) {
        guard let tv = textView else { return }
        if let range = tv.selectedTextRange, !range.isEmpty, let sel = tv.text(in: range) {
            tv.replace(range, withText: l + sel + r)
        } else {
            tv.insertText(l + r)
            move(-1)
        }
    }

    private func move(_ delta: Int) {
        guard let tv = textView, let range = tv.selectedTextRange else { return }
        if let pos = tv.position(from: range.start, offset: delta) {
            tv.selectedTextRange = tv.textRange(from: pos, to: pos)
        }
    }
}
