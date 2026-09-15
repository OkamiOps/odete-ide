import SwiftUI

// Formato de seção que veio das capturas em docs/design: título em negrito fora do cartão,
// cartão com raio 14 embaixo, e linhas com um quadrado de ícone colorido à esquerda,
// separador que começa onde o texto começa e chevron quando a linha leva a algum lugar.

/// Título de seção fora do cartão, com detalhe, números opcionais e um menu de reticências.
public struct SectionTitle<MenuContent: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.paneWidth) private var paneWidth
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
        // `ViewThatFits` em vez de largura medida: o título e o par +/− são rígidos, e
        // somados ao menu passavam de 230 pt. Numa coluna de 200 o cartão não conseguia
        // encolher, empurrava a barra lateral inteira e ela acabava em cima do rail. Aqui
        // a decisão é tomada contra a largura que o pai oferece, não contra a que sobrou.
        ViewThatFits(in: .horizontal) {
            linha(detalhe: true, numeros: true)
            linha(detalhe: false, numeros: true)
            linha(detalhe: false, numeros: false)
            linha(detalhe: false, numeros: false, tituloFixo: false)
        }
        .padding(.horizontal, 4)
    }

    func linha(detalhe: Bool, numeros: Bool, tituloFixo: Bool = true) -> some View {
        HStack(spacing: 8) {
            // O título não quebra em duas linhas: era ele que virava "Pull\nrequests" na
            // coluna estreita. Na última tentativa ele corta, que é melhor que estourar.
            Text(title).font(.headline).foregroundStyle(theme.fg)
                .lineLimit(1)
                .fixedSize(horizontal: tituloFixo, vertical: false)
            if let detail, detalhe {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            if let stat, numeros {
                HStack(spacing: 6) {
                    Text("+\(stat.added)").foregroundStyle(theme.ok)
                    Text("−\(stat.removed)").foregroundStyle(theme.danger)
                }
                .font(.caption.weight(.medium)).monospacedDigit()
                .lineLimit(1)
                .fixedSize()
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
                .fixedSize()
                .accessibilityLabel("Mais ações em \(title)")
            }
        }
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
    /// No lugar do símbolo, quando o que identifica a linha é uma figura e não um ícone
    /// do sistema — a bandeira do idioma, por exemplo. O quadrado colorido some junto.
    var emoji: String?
    var color: Color?
    var label: String
    var detail: String?
    var first: Bool
    /// Quantas linhas o rótulo pode ocupar. Uma para linha de ajuste, duas para frase.
    var lines: Int
    @ViewBuilder var trailing: Trailing

    public init(
        _ label: String,
        symbol: String = "",
        emoji: String? = nil,
        color: Color? = nil,
        detail: String? = nil,
        first: Bool = false,
        lines: Int = 1,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.label = label
        self.symbol = symbol
        self.emoji = emoji
        self.color = color
        self.detail = detail
        self.first = first
        self.lines = lines
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 10) {
            if let emoji {
                Text(emoji).font(.system(size: 17)).frame(width: 22, height: 22)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(color ?? theme.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.subheadline).foregroundStyle(theme.fg).lineLimit(lines)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, lines > 1 ? 8 : 0)
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
