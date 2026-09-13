import SwiftUI

/// Painel casca: usado enquanto a funcionalidade real não chega.
public struct ShellPanel: View {
    @Environment(\.theme) private var theme
    var title: String
    var symbol: String
    var phase: Int
    var blurb: String

    public init(_ title: String, symbol: String, phase: Int, blurb: String) {
        self.title = title
        self.symbol = symbol
        self.phase = phase
        self.blurb = blurb
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(theme.fgSubtle)
            Text(title)
                .font(OdeteFont.ui(15, weight: .medium))
                .foregroundStyle(theme.fg)
            Text(blurb)
                .font(OdeteFont.ui(12))
                .foregroundStyle(theme.fgMuted)
                .multilineTextAlignment(.center)
            Text("chega na Fase \(phase)")
                .font(OdeteFont.mono(11))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(theme.accent.opacity(0.12), in: Capsule())
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
