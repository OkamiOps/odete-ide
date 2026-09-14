import SwiftUI

// Formato de seção que veio das capturas em docs/design: título em negrito fora do cartão,
// cartão com raio 14 embaixo, e linhas com um quadrado de ícone colorido à esquerda,
// separador que começa onde o texto começa e chevron quando a linha leva a algum lugar.

/// Título de seção fora do cartão, com detalhe, números opcionais e um menu de reticências.
public struct SectionTitle<MenuContent: View>: View {
    @Environment(\.theme) private var theme
    var title: String
    var detail: String?
    /// Total de linhas que entraram e saíram, mostrado à direita do título.
    var stat: (added: Int, removed: Int)?
    @ViewBuilder var menu: MenuContent

    public init(
        _ title: String,
        detail: String? = nil,
        stat: (added: Int, removed: Int)? = nil,
        @ViewBuilder menu: () -> MenuContent = { EmptyView() }
    ) {
        self.title = title
        self.detail = detail
        self.stat = stat
        self.menu = menu()
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline).foregroundStyle(theme.fg)
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            if let stat {
                HStack(spacing: 6) {
                    Text("+\(stat.added)").foregroundStyle(theme.ok)
                    Text("−\(stat.removed)").foregroundStyle(theme.danger)
                }
                .font(.caption.weight(.medium)).monospacedDigit()
                .contentTransition(.numericText())
            }
            if !(menu is EmptyView) {
                Menu {
                    menu
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.fgMuted)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Cartão que envolve um grupo de linhas.
public struct CardList<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) { content }
            .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Linha de cartão: quadrado de ícone colorido, rótulo e o que vier à direita.
/// `first` desliga o separador de cima, que sempre começa alinhado ao texto.
public struct CardRow<Trailing: View>: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var color: Color?
    var label: String
    var detail: String?
    var first: Bool
    @ViewBuilder var trailing: Trailing

    public init(
        _ label: String,
        symbol: String,
        color: Color? = nil,
        detail: String? = nil,
        first: Bool = false,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.label = label
        self.symbol = symbol
        self.color = color
        self.detail = detail
        self.first = first
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(color ?? theme.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.subheadline).foregroundStyle(theme.fg).lineLimit(1)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(minHeight: detail == nil ? 44 : 50)
        .overlay(alignment: .top) {
            if !first {
                Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 44)
            }
        }
    }
}

/// Texto de apoio embaixo de um cartão, como as explicações dos Ajustes do sistema.
public struct CardNote: View {
    @Environment(\.theme) private var theme
    var text: String
    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}
