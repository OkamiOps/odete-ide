import OdeteCore
import Runestone
import UIKit

/// Marca de git no gutter (linha 1-based).
public struct EditorGutterMark: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case added, modified, deleted }
    public var line: Int
    public var kind: Kind
    public var id: String {
        "\(line):\(kind)"
    }

    public init(line: Int, kind: Kind) {
        self.line = line
        self.kind = kind
    }
}

/// Linha que o agente mexeu, para o patch pendente aparecer dentro do código.
/// `.added` é uma linha que está no texto; `.removed` é o lugar onde linhas sumiram.
public struct EditorLineChange: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case added, removed }
    public var line: Int
    public var kind: Kind
    public var id: String {
        "\(line):\(kind)"
    }

    public init(line: Int, kind: Kind) {
        self.line = line
        self.kind = kind
    }
}

/// Problema a sublinhar (linha/coluna 1-based, em Characters).
public struct EditorIssue: Sendable, Hashable, Identifiable {
    public enum Severity: Sendable, Hashable { case error, warning, info }
    public var line: Int
    public var column: Int
    public var length: Int
    public var severity: Severity
    public var message: String
    public var id: String {
        "\(line):\(column):\(message)"
    }

    public init(line: Int, column: Int, length: Int, severity: Severity, message: String) {
        self.line = line
        self.column = column
        self.length = length
        self.severity = severity
        self.message = message
    }
}

/// Fonte do autocompletar: caminhos do projeto e o arquivo aberto.
public struct CompletionSource: Sendable, Hashable {
    public var files: [String]
    /// Pacotes instalados, para completar `from "…"`.
    public var packages: [String]
    public var path: String
    public init(files: [String], packages: [String] = [], path: String) {
        self.files = files
        self.packages = packages
        self.path = path
    }
}

/// Desenha as marcas do git sobre o gutter do Runestone. Vive dentro do `TextView` (que é um
/// `UIScrollView`), então acompanha o conteúdo; o `x` segue o `contentOffset` para ficar colado à esquerda.
@MainActor
final class GutterOverlay: UIView {
    struct Placed { let y: CGFloat; let h: CGFloat; let mark: EditorGutterMark }
    var placed: [Placed] = []
    /// Toque longo, não toque simples: com marca em quase toda linha, o toque simples
    /// roubava o toque que devia levar o cursor para a linha e o editor parecia travado.
    var onLongPress: ((Int) -> Void)?
    var addedColor = UIColor.systemGreen
    var modifiedColor = UIColor.systemBlue
    var deletedColor = UIColor.systemRed

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        let g = UILongPressGestureRecognizer(target: self, action: #selector(pressionado(_:)))
        g.minimumPressDuration = 0.45
        addGestureRecognizer(g)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        nil
    }

    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        // A tira das marcas e nada mais. O limite da direita é o que faltava: sem ele
        // `x >= bounds.width - 10` aceitava qualquer ponto do editor à direita do gutter,
        // e esta view, que tem 42 pt de largura e a altura inteira do arquivo, engolia o
        // toque no meio do código em toda linha que tivesse marca do git. Era isso que
        // deixava o cursor preso: "só vai em determinadas linhas" eram as linhas sem marca.
        guard point.x >= bounds.width - 12, point.x <= bounds.width else { return false }
        return placed.contains { point.y >= $0.y && point.y <= $0.y + $0.h }
    }

    @objc private func pressionado(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let p = g.location(in: self)
        if let hit = placed.first(where: { p.y >= $0.y - 2 && p.y <= $0.y + $0.h + 2 }) {
            onLongPress?(hit.mark.line)
        }
    }

    override func draw(_: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let x = bounds.width - 6
        for p in placed {
            switch p.mark.kind {
            case .added, .modified:
                ctx.setFillColor((p.mark.kind == .added ? addedColor : modifiedColor).cgColor)
                ctx.addPath(UIBezierPath(
                    roundedRect: CGRect(x: x, y: p.y + 1, width: 3, height: max(p.h - 2, 4)),
                    cornerRadius: 1.5
                ).cgPath)
                ctx.fillPath()
            case .deleted:
                ctx.setFillColor(deletedColor.cgColor)
                ctx.move(to: CGPoint(x: x - 1, y: p.y - 4))
                ctx.addLine(to: CGPoint(x: x + 5, y: p.y))
                ctx.addLine(to: CGPoint(x: x - 1, y: p.y + 4))
                ctx.closePath()
                ctx.fillPath()
            }
        }
    }
}

/// Guias de indentação desenhadas atrás do texto (uma por nível); a do bloco do cursor fica em destaque.
@MainActor
final class IndentGuides: UIView {
    struct Segment { let x: CGFloat; let y: CGFloat; let h: CGFloat; let active: Bool }
    var segments: [Segment] = []
    var color = UIColor.gray.withAlphaComponent(0.1)
    var activeColor = UIColor.systemOrange.withAlphaComponent(0.4)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        nil
    }

    override func draw(_: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setLineWidth(1)
        for s in segments {
            ctx.setStrokeColor((s.active ? activeColor : color).cgColor)
            ctx.move(to: CGPoint(x: s.x + 0.5, y: s.y))
            ctx.addLine(to: CGPoint(x: s.x + 0.5, y: s.y + s.h))
            ctx.strokePath()
        }
    }
}

/// Marca de linha apagada pelo agente: um fio vermelho na altura em que o texto sumiu.
/// A linha adicionada é pintada pelo próprio `highlightedRanges` do Runestone, mas a que
/// foi embora não está no texto e não tem onde ser pintada.
@MainActor
final class ChangeMarks: UIView {
    /// Onde linhas foram apagadas pelo agente.
    var ys: [CGFloat] = []
    /// Sublinhado ondulado de problema: começo, largura, base e cor.
    struct Onda { let x: CGFloat; let w: CGFloat; let y: CGFloat; let cor: UIColor }
    var ondas: [Onda] = []
    var cor = UIColor.systemRed

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        nil
    }

    override func draw(_: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(cor.withAlphaComponent(0.55).cgColor)
        for y in ys {
            ctx.fill(CGRect(x: 0, y: y - 1, width: bounds.width, height: 2))
            ctx.move(to: CGPoint(x: 0, y: y - 5))
            ctx.addLine(to: CGPoint(x: 8, y: y))
            ctx.addLine(to: CGPoint(x: 0, y: y + 5))
            ctx.closePath()
            ctx.fillPath()
        }
        // Onda embaixo do trecho com problema. Um fundo colorido de um caractere só,
        // que era o que existia, não se vê no meio do código.
        ctx.setLineWidth(1.6)
        ctx.setLineJoin(.round)
        for o in ondas {
            ctx.setStrokeColor(o.cor.cgColor)
            var x = o.x
            var cima = true
            ctx.move(to: CGPoint(x: x, y: o.y))
            while x < o.x + o.w {
                x += 2.5
                ctx.addLine(to: CGPoint(x: min(x, o.x + o.w), y: o.y + (cima ? -2 : 2)))
                cima.toggle()
            }
            ctx.strokePath()
        }
    }
}

/// Lista flutuante de sugestões, ancorada abaixo do cursor.
@MainActor
final class CompletionPopup: UIView {
    var items: [Completion] = [] {
        didSet { rebuild() }
    }

    var onPick: ((Completion) -> Void)?
    var fg = UIColor.label
    var muted = UIColor.secondaryLabel
    var accent = UIColor.tintColor
    private let stack = UIStackView()
    private let glass = UIVisualEffectView(effect: UIGlassEffect())

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)
        stack.axis = .vertical
        stack.spacing = 0
        stack.frame = bounds
        stack.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.contentView.addSubview(stack)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        nil
    }

    private func rebuild() {
        for v in stack.arrangedSubviews {
            v.removeFromSuperview()
        }
        for (i, item) in items.enumerated() {
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: item.kind.symbol)?.applyingSymbolConfiguration(.init(
                pointSize: 11,
                weight: .medium
            ))
            cfg.imagePadding = 8
            cfg.baseForegroundColor = i == 0 ? accent : fg
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            let title = NSMutableAttributedString(string: item.label, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 12.5, weight: i == 0 ? .semibold : .regular),
                .foregroundColor: i == 0 ? accent : fg,
            ])
            if let d = item.detail {
                title.append(NSAttributedString(string: "  \(d)", attributes: [
                    .font: UIFont.systemFont(ofSize: 11), .foregroundColor: muted,
                ]))
            }
            cfg.attributedTitle = AttributedString(title)
            let b = UIButton(configuration: cfg)
            b.contentHorizontalAlignment = .leading
            b.addAction(UIAction { [weak self] _ in self?.onPick?(item) }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
    }

    var preferredHeight: CGFloat {
        CGFloat(items.count) * 30
    }
}
