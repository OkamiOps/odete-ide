import OdeteI18n
import Runestone
import UIKit

/// O balão com a mensagem do problema sublinhado.
///
/// A onda dizia que havia algo errado e não dizia o quê: `EditorIssue.message` chegava
/// até o editor e não aparecia em lugar nenhum dele. Um toque na onda (ou ⌘' com o
/// cursor na linha) abre isto logo abaixo do trecho, com a mensagem e de onde ela veio.
/// Não é popover de propósito: popover tira o foco do editor e o teclado desce.
@MainActor
final class BalaoDeProblema: UIView {
    private let pilha = UIStackView()
    private let vidro = UIVisualEffectView(effect: UIGlassEffect())
    private(set) var mensagens: [EditorIssue] = []
    var corErro = UIColor.systemRed
    var corAviso = UIColor.systemOrange
    var corInfo = UIColor.secondaryLabel
    var corTexto = UIColor.label
    var corApagada = UIColor.secondaryLabel

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)
        vidro.layer.cornerRadius = 12
        vidro.layer.cornerCurve = .continuous
        vidro.clipsToBounds = true
        vidro.frame = bounds
        vidro.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(vidro)
        pilha.axis = .vertical
        pilha.spacing = 8
        pilha.translatesAutoresizingMaskIntoConstraints = false
        vidro.contentView.addSubview(pilha)
        NSLayoutConstraint.activate([
            pilha.leadingAnchor.constraint(equalTo: vidro.contentView.leadingAnchor, constant: 12),
            pilha.trailingAnchor.constraint(equalTo: vidro.contentView.trailingAnchor, constant: -12),
            pilha.topAnchor.constraint(equalTo: vidro.contentView.topAnchor, constant: 10),
            pilha.bottomAnchor.constraint(equalTo: vidro.contentView.bottomAnchor, constant: -10),
        ])
        // Tocar no balão fecha; segurar oferece copiar, para colar a mensagem numa busca
        // ou no chat do agente.
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(fechar)))
        addInteraction(UIContextMenuInteraction(delegate: self))
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    @objc private func fechar() {
        isHidden = true
    }

    /// Monta as linhas e devolve o tamanho que o balão precisa, até `larguraMaxima`.
    func mostrar(_ lista: [EditorIssue], larguraMaxima: CGFloat) -> CGSize {
        mensagens = lista
        for v in pilha.arrangedSubviews {
            v.removeFromSuperview()
        }
        let larguraTexto = max(larguraMaxima - 24 - 22, 80)
        for issue in lista.prefix(4) {
            pilha.addArrangedSubview(linha(issue, larguraTexto: larguraTexto))
        }
        if lista.count > 4 {
            let mais = UILabel()
            mais.font = .systemFont(ofSize: 11)
            mais.textColor = corApagada
            mais.text = tr("e mais %1$@", "\(lista.count - 4)")
            pilha.addArrangedSubview(mais)
        }
        accessibilityLabel = lista.map(\.message).joined(separator: ". ")
        let alvo = pilha.systemLayoutSizeFitting(
            CGSize(width: larguraTexto + 22, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: min(alvo.width + 24, larguraMaxima), height: alvo.height + 20)
    }

    private func linha(_ issue: EditorIssue, larguraTexto: CGFloat) -> UIView {
        let (simbolo, cor) = switch issue.severity {
        case .error: ("xmark.octagon.fill", corErro)
        case .warning: ("exclamationmark.triangle.fill", corAviso)
        case .info: ("info.circle.fill", corInfo)
        }
        let icone = UIImageView(image: UIImage(
            systemName: simbolo,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        ))
        icone.tintColor = cor
        icone.setContentHuggingPriority(.required, for: .horizontal)
        icone.setContentCompressionResistancePriority(.required, for: .horizontal)
        let mensagem = UILabel()
        mensagem.numberOfLines = 0
        mensagem.font = .systemFont(ofSize: 12.5, weight: .medium)
        mensagem.textColor = corTexto
        mensagem.text = issue.message
        mensagem.preferredMaxLayoutWidth = larguraTexto
        let textos = UIStackView(arrangedSubviews: [mensagem])
        textos.axis = .vertical
        textos.spacing = 2
        if let fonte = issue.fonte, !fonte.isEmpty {
            let origem = UILabel()
            origem.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            origem.textColor = corApagada
            origem.text = tr("%1$@ · linha %2$@", fonte, "\(issue.line)")
            textos.addArrangedSubview(origem)
        }
        let h = UIStackView(arrangedSubviews: [icone, textos])
        h.axis = .horizontal
        h.alignment = .firstBaseline
        h.spacing = 8
        return h
    }
}

extension BalaoDeProblema: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _: UIContextMenuInteraction,
        configurationForMenuAtLocation _: CGPoint
    ) -> UIContextMenuConfiguration? {
        let texto = mensagens.map(\.message).joined(separator: "\n")
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [
                UIAction(title: tr("Copiar mensagem"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = texto
                },
            ])
        })
    }
}

extension CodeEditorView.Coordinator {
    var problemaVisivel: Bool {
        !balao.isHidden && balao.superview != nil
    }

    /// Onde cada problema está desenhado, em coordenadas do conteúdo do editor.
    ///
    /// Mesma conta de `marcarProblemas`, que desenha a onda: a área vai do topo da linha
    /// até um pouco abaixo da onda, para o dedo acertar tanto o código quanto o risco.
    func areasDosProblemas(_ tv: TextView) -> [(issue: EditorIssue, area: CGRect)] {
        let mapa = linhas()
        let ns = mapa.ns
        let starts = mapa.starts
        var out: [(issue: EditorIssue, area: CGRect)] = []
        for i in issues where i.line >= 1 && i.line <= starts.count {
            let inicioLinha = starts[i.line - 1]
            let fimLinha = i.line < starts.count ? starts[i.line] - 1 : ns.length
            let de = min(inicioLinha + max(i.column - 1, 0), fimLinha)
            let ate = max(min(de + max(i.length, 1), fimLinha), de + 1)
            guard let p1 = tv.position(from: tv.beginningOfDocument, offset: de),
                  let p2 = tv.position(from: tv.beginningOfDocument, offset: min(max(ate, fimLinha), ns.length))
            else { continue }
            let r1 = tv.caretRect(for: p1)
            let r2 = tv.caretRect(for: p2)
            let base = min(r1.minY + fontSize * 1.35, r1.maxY - 1)
            let mesmaLinha = abs(r2.minY - r1.minY) < 1
            let largura = mesmaLinha ? max(r2.minX - r1.minX, 12) : max(tv.bounds.width - r1.minX - 40, 12)
            out.append((i, CGRect(x: r1.minX - 4, y: r1.minY - 2, width: largura + 8, height: base - r1.minY + 8)))
        }
        return out
    }

    /// Toque no texto: se caiu numa onda, mostra a mensagem; fora dela, fecha o balão.
    @discardableResult
    func tocouEmProblema(_ ponto: CGPoint) -> Bool {
        guard let tv = textView, !issues.isEmpty else {
            esconderProblema()
            return false
        }
        let achados = areasDosProblemas(tv).filter { $0.area.contains(ponto) }
        guard let primeiro = achados.first else {
            esconderProblema()
            return false
        }
        mostrarProblemas(achados.map(\.issue), junto: primeiro.area, em: tv)
        return true
    }

    /// ⌘': o problema da linha do cursor. Sem problema nela, vai ao próximo do arquivo
    /// (e dá a volta), como o "próximo problema" do Xcode — com o teclado, é assim que se
    /// anda de erro em erro.
    func mostrarProblemaNoCursor() {
        guard let tv = textView, !issues.isEmpty else { return }
        let linha = linhaDe(tv.selectedRange.location) + 1
        var daLinha = issues.filter { $0.line == linha }
        if daLinha.isEmpty {
            let ordem = issues.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
            guard let proximo = ordem.first(where: { $0.line > linha }) ?? ordem.first else { return }
            irPara(AlvoDeLinha(linha: proximo.line, coluna: proximo.column))
            daLinha = issues.filter { $0.line == proximo.line }
        }
        let areas = areasDosProblemas(tv).filter { a in daLinha.contains(a.issue) }
        guard let area = areas.first?.area else { return }
        mostrarProblemas(daLinha, junto: area, em: tv)
        UIAccessibility.post(notification: .announcement, argument: balao.accessibilityLabel)
    }

    func mostrarProblemas(_ lista: [EditorIssue], junto area: CGRect, em tv: TextView) {
        let cores = palette ?? parent.palette
        balao.corErro = UIColor(hex: cores.danger)
        balao.corAviso = UIColor(hex: cores.syntax.keyword)
        balao.corInfo = UIColor(hex: cores.fgMuted)
        balao.corTexto = UIColor(hex: cores.fg)
        balao.corApagada = UIColor(hex: cores.fgMuted)
        let larguraMaxima = min(440, max(tv.bounds.width - tv.gutterWidth - 24, 160))
        let tamanho = balao.mostrar(lista, larguraMaxima: larguraMaxima)
        let esquerda = tv.contentOffset.x + tv.gutterWidth + 4
        let direita = tv.contentOffset.x + tv.bounds.width - tamanho.width - 12
        let x = max(min(area.minX, direita), esquerda)
        var y = area.maxY + 2
        // Sem espaço embaixo (linha perto do teclado ou do fim da tela), vai para cima.
        let fimVisivel = tv.contentOffset.y + tv.bounds.height - tv.adjustedContentInset.bottom
        if y + tamanho.height > fimVisivel, area.minY - tamanho.height - 4 > tv.contentOffset.y {
            y = area.minY - tamanho.height - 4
        }
        balao.frame = CGRect(origin: CGPoint(x: x, y: y), size: tamanho)
        if balao.superview !== tv {
            tv.addSubview(balao)
        }
        balao.isHidden = false
        tv.bringSubviewToFront(balao)
        versaoDoBalao = versaoDoTexto
    }

    func esconderProblema() {
        balao.isHidden = true
    }

    /// O texto mudou desde que o balão abriu: a mensagem pode já não valer, e a posição
    /// com certeza não vale mais.
    func conferirBalao() {
        if !balao.isHidden, versaoDoBalao != versaoDoTexto {
            esconderProblema()
        }
    }
}
