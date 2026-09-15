import SwiftUI

/// A ratinha da Odete desenhada como glifo.
///
/// Onde ela aparece antes havia o `cat` do SF Symbols, emprestado do octocat. O mascote
/// da casa é uma ratinha, e o sistema não tem rato nenhum entre os símbolos — então ela
/// é desenhada aqui, e não colocada como imagem: assim herda a cor de quem a usa, como
/// um símbolo do sistema, e fica nítida em qualquer tamanho.
///
/// A primeira versão tinha a orelha vazada, com um furo no meio, e a 20 pt era só isso
/// que se via: um anel grande em cima de um borrão — parecia uma orelha, não um rato.
/// A orelha agora é cheia, o focinho é mais comprido e o rabo enrola até embaixo. Só o
/// olho continua recortado, como um símbolo do sistema deixa buraco em vez de pintar.
///
/// O traçado vive numa caixa de 100×100 e é escalado na hora de desenhar.
public struct Ratinha: View {
    public var size: CGFloat

    public init(size: CGFloat = 15) {
        self.size = size
    }

    public var body: some View {
        Canvas { ctx, caixa in
            let k = min(caixa.width, caixa.height) / 100
            ctx.scaleBy(x: k, y: k)
            ctx.stroke(Self.rabo, with: .foreground, style: StrokeStyle(lineWidth: 8, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: 29, y: 11, width: 30, height: 30)), with: .foreground)
            ctx.fill(Self.corpo, with: .foreground)
            ctx.blendMode = .destinationOut
            ctx.fill(Path(ellipseIn: CGRect(x: 69.4, y: 47.4, width: 7.2, height: 7.2)), with: .foreground)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Anca, costas, nuca, focinho e barriga, nessa ordem.
    static let corpo: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 20, y: 60))
        p.addCurve(to: CGPoint(x: 52, y: 32), control1: CGPoint(x: 20, y: 40), control2: CGPoint(x: 34, y: 30))
        p.addCurve(to: CGPoint(x: 84, y: 50), control1: CGPoint(x: 66, y: 34), control2: CGPoint(x: 74, y: 42))
        p.addCurve(to: CGPoint(x: 95, y: 62), control1: CGPoint(x: 92, y: 55), control2: CGPoint(x: 96, y: 58))
        p.addCurve(to: CGPoint(x: 76, y: 66), control1: CGPoint(x: 93, y: 66), control2: CGPoint(x: 85, y: 67))
        p.addCurve(to: CGPoint(x: 40, y: 80), control1: CGPoint(x: 62, y: 72), control2: CGPoint(x: 52, y: 80))
        p.addCurve(to: CGPoint(x: 20, y: 60), control1: CGPoint(x: 28, y: 80), control2: CGPoint(x: 20, y: 74))
        p.closeSubpath()
        return p
    }()

    /// Desenhado antes do corpo, para sair de trás da anca em vez de grudar por cima.
    static let rabo: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 21, y: 68))
        p.addCurve(to: CGPoint(x: 22, y: 98), control1: CGPoint(x: 4, y: 76), control2: CGPoint(x: 2, y: 94))
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
