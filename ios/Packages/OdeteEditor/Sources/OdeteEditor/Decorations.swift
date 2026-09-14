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
    public var path: String
    public init(files: [String], path: String) {
        self.files = files
        self.path = path
    }
}

/// Desenha as marcas do git sobre o gutter do Runestone. Vive dentro do `TextView` (que é um
/// `UIScrollView`), então acompanha o conteúdo; o `x` segue o `contentOffset` para ficar colado à esquerda.
@MainActor
final class GutterOverlay: UIView {
    struct Placed { let y: CGFloat; let h: CGFloat; let mark: EditorGutterMark }
    var placed: [Placed] = []
    var onTap: ((Int) -> Void)?
    var addedColor = UIColor.systemGreen
    var modifiedColor = UIColor.systemBlue
    var deletedColor = UIColor.systemRed

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        nil
    }

    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        // Só engole toques em cima de uma marca; o resto passa para o editor.
        placed.contains { point.y >= $0.y - 2 && point.y <= $0.y + $0.h + 2 } && point.x >= bounds.width - 14
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        if let hit = placed.first(where: { p.y >= $0.y - 2 && p.y <= $0.y + $0.h + 2 }) {
            onTap?(hit.mark.line)
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
