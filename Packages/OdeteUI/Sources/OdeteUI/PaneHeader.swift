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
        // O detalhe cabe inteiro ou não aparece. Antes ele encolhia até sobrar só a
        // reticência, e o cabeçalho ficava "FILES …" — o rótulo traduzido é mais curto
        // que "ARQUIVOS", sobrou um naco de espaço, e o nome do projeto coube nele
        // sem caber. A decisão é contra a largura que o pai oferece, não contra a que
        // sobrou depois de espremer.
        ViewThatFits(in: .horizontal) {
            linha(comDetalhe: true)
            linha(comDetalhe: false)
        }
        .padding(.leading, Metrics.s3)
        .padding(.trailing, Metrics.s2)
        .frame(height: Metrics.paneHeader)
    }

    func linha(comDetalhe: Bool) -> some View {
        HStack(spacing: Metrics.s2) {
            Text(label.uppercased())
                .font(OdeteFont.label)
                .tracking(1.2)
                .foregroundStyle(theme.fgSubtle)
                .lineLimit(1)
                .fixedSize()
            if let detail, comDetalhe {
                Text(detail)
                    .font(OdeteFont.ui(11.5))
                    .foregroundStyle(theme.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fixedSize()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) { trailing }
        }
    }
}

/// Botão de ícone: 32 pt, vidro só no hover/press; `prominent` para a ação principal.
public struct HeaderButton: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var label: String
    var prominent: Bool
    var action: () -> Void
    @State private var hover = false

    public init(_ symbol: String, label: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.prominent = prominent
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(prominent ? theme.accent : (hover ? theme.fg : theme.fgMuted))
                .frame(width: 32, height: 32)
                .background(
                    hover ? theme.fg.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: Metrics.rControl, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: Metrics.rControl, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
        .help(label)
    }
}
