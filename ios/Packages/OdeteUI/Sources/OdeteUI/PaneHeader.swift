import SwiftUI

/// Cabeçalho de painel: rótulo em caixa alta à esquerda, detalhe e ações à direita.
public struct PaneHeader<Trailing: View>: View {
    @Environment(\.theme) private var theme
    var label: String
    var detail: String?
    var trailing: Trailing

    public init(_ label: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.label = label
        self.detail = detail
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(OdeteFont.label)
                .tracking(1)
                .foregroundStyle(theme.fgSubtle)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(2)
            if let detail {
                Text(detail)
                    .font(OdeteFont.ui(11))
                    .foregroundStyle(theme.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: Metrics.paneHeader)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

/// Botão pequeno de cabeçalho (ícone só), 44 pt de toque.
public struct HeaderButton: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var label: String
    var action: () -> Void

    public init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.fgMuted)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}
