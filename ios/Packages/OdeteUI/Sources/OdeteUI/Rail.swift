import OdeteCore
import SwiftUI

/// Barra de atividades vertical: marca, painéis laterais e o botão do agente embaixo.
public struct Rail: View {
    @Environment(\.theme) private var theme
    public var side: SidePanel
    public var sideOpen: Bool
    public var agentVisible: Bool
    public var onSelect: (SidePanel) -> Void
    public var onToggleAgent: () -> Void

    public init(
        side: SidePanel,
        sideOpen: Bool,
        agentVisible: Bool,
        onSelect: @escaping (SidePanel) -> Void,
        onToggleAgent: @escaping () -> Void
    ) {
        self.side = side
        self.sideOpen = sideOpen
        self.agentVisible = agentVisible
        self.onSelect = onSelect
        self.onToggleAgent = onToggleAgent
    }

    public var body: some View {
        VStack(spacing: 2) {
            BrandIcon(size: 30)
                .frame(width: Metrics.railWidth, height: 56)
                .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
                .padding(.bottom, 6)
            ForEach(SidePanel.allCases, id: \.self) { p in
                RailButton(symbol: p.symbol, label: p.label, on: sideOpen && side == p) { onSelect(p) }
            }
            Spacer(minLength: 0)
            RailButton(symbol: "sparkles", label: "Agente", on: agentVisible, action: onToggleAgent)
                .padding(.bottom, 8)
        }
        .frame(width: Metrics.railWidth)
        .frame(maxHeight: .infinity)
        .background(theme.bgElevated)
        .overlay(alignment: .trailing) { Rectangle().fill(theme.border).frame(width: 1) }
    }
}

struct RailButton: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var label: String
    var on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .symbolVariant(on ? .fill : .none)
                .foregroundStyle(on ? theme.fg : theme.fgMuted)
                .frame(width: 40, height: 40)
                .background(on ? theme.bgSubtle : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(width: Metrics.touch, height: Metrics.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(on ? "Esconder \(label)" : "Mostrar \(label)")
    }
}
