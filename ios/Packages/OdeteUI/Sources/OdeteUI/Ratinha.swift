import SwiftUI

/// A ratinha da Odete desenhada como glifo.
///
/// Onde ela aparece antes havia o `cat` do SF Symbols, emprestado do octocat. O mascote
/// da casa é uma ratinha, e o sistema não tem rato nenhum entre os símbolos — então ela
/// é desenhada aqui, e não colocada como imagem: assim herda a cor de quem a usa, como
/// um símbolo do sistema, e fica nítida em qualquer tamanho.
///
/// O traçado vive numa caixa de 100×100 e é escalado na hora de desenhar; o furo da
/// orelha e o olho são recortados com `destinationOut`, do mesmo jeito que um símbolo do
/// sistema deixa buraco em vez de pintar o fundo.
public struct Ratinha: View {
    public var size: CGFloat

    public init(size: CGFloat = 15) {
        self.size = size
    }

    public var body: some View {
        Canvas { ctx, caixa in
            let k = min(caixa.width, caixa.height) / 100
            ctx.scaleBy(x: k, y: k)
            ctx.fill(Self.corpo, with: .foreground)
            ctx.fill(Path(ellipseIn: CGRect(x: 35, y: 13, width: 34, height: 34)), with: .foreground)
            ctx.stroke(
                Self.rabo,
                with: .foreground,
                style: StrokeStyle(lineWidth: 6, lineCap: .round)
            )
            ctx.blendMode = .destinationOut
            ctx.fill(Path(ellipseIn: CGRect(x: 43, y: 21, width: 18, height: 18)), with: .foreground)
            ctx.fill(Path(ellipseIn: CGRect(x: 72, y: 48, width: 8, height: 8)), with: .foreground)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Anca, costas, nuca, focinho e barriga, nessa ordem.
    static let corpo: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 22, y: 58))
        p.addCurve(to: CGPoint(x: 56, y: 32), control1: CGPoint(x: 22, y: 38), control2: CGPoint(x: 38, y: 30))
        p.addCurve(to: CGPoint(x: 88, y: 54), control1: CGPoint(x: 72, y: 34), control2: CGPoint(x: 80, y: 44))
        p.addCurve(to: CGPoint(x: 95, y: 64), control1: CGPoint(x: 94, y: 58), control2: CGPoint(x: 96, y: 60))
        p.addCurve(to: CGPoint(x: 78, y: 68), control1: CGPoint(x: 93, y: 68), control2: CGPoint(x: 86, y: 68))
        p.addCurve(to: CGPoint(x: 44, y: 82), control1: CGPoint(x: 66, y: 72), control2: CGPoint(x: 58, y: 80))
        p.addCurve(to: CGPoint(x: 22, y: 58), control1: CGPoint(x: 32, y: 83), control2: CGPoint(x: 22, y: 74))
        p.closeSubpath()
        return p
    }()

    static let rabo: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 24, y: 70))
        p.addCurve(to: CGPoint(x: 20, y: 96), control1: CGPoint(x: 10, y: 78), control2: CGPoint(x: 6, y: 92))
        return p
    }()
}

/// Botão de cabeçalho com a ratinha no lugar do símbolo do sistema.
public struct RatinhaButton: View {
    @Environment(\.theme) private var theme
    var label: String
    var action: () -> Void
    @State private var hover = false

    public init(label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Ratinha(size: 20)
                .foregroundStyle(hover ? theme.fg : theme.fgMuted)
                .frame(width: 32, height: 32)
                .background(
                    hover ? theme.fg.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: Metrics.rControl, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: Metrics.rControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
        .help(label)
    }
}
