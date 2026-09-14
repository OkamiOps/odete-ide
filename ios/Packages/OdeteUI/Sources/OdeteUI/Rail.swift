import OdeteCore
import SwiftUI

/// Barra de atividades vertical: marca, painéis laterais e o botão do agente embaixo.
public struct Rail: View {
    @Environment(\.theme) private var theme
    @Namespace private var ns
    public var side: SidePanel
    public var sideOpen: Bool
    public var agentVisible: Bool
    public var agentBusy: Bool
    public var onSelect: (SidePanel) -> Void
    public var onToggleAgent: () -> Void

    public init(
        side: SidePanel,
        sideOpen: Bool,
        agentVisible: Bool,
        agentBusy: Bool = false,
        onSelect: @escaping (SidePanel) -> Void,
        onToggleAgent: @escaping () -> Void
    ) {
        self.side = side
        self.sideOpen = sideOpen
        self.agentVisible = agentVisible
        self.agentBusy = agentBusy
        self.onSelect = onSelect
        self.onToggleAgent = onToggleAgent
    }

    public var body: some View {
        VStack(spacing: Metrics.s1) {
            BrandIcon(size: 30)
                .frame(width: Metrics.railWidth, height: 56)
                .padding(.bottom, Metrics.s1)
            ForEach(SidePanel.allCases, id: \.self) { p in
                RailButton(symbol: p.symbol, label: p.label, on: sideOpen && side == p, ns: ns) { onSelect(p) }
            }
            Spacer(minLength: 0)
            RailButton(
                symbol: "sparkles",
                label: "Agente",
                on: agentVisible,
                busy: agentBusy,
                ns: nil,
                action: onToggleAgent
            )
            .padding(.bottom, Metrics.s2)
        }
        .frame(width: Metrics.railWidth)
        .frame(maxHeight: .infinity)
        .background(theme.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(theme.separator).frame(width: 0.5) }
    }
}

struct RailButton: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var label: String
    var on: Bool
    var busy = false
    var ns: Namespace.ID?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .symbolVariant(on ? .fill : .none)
                .symbolEffect(.pulse, isActive: busy)
                .foregroundStyle(on ? theme.accent : theme.fgMuted)
                .frame(width: 40, height: 40)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.glassTint)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(
                                theme.accent.opacity(0.25),
                                lineWidth: 0.5
                            ))
                            .modifier(MatchedIfPossible(ns: ns))
                    }
                }
                .frame(width: Metrics.touch, height: Metrics.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(on ? "Esconder \(label)" : "Mostrar \(label)")
        .animation(.snappy(duration: 0.22), value: on)
    }
}

struct MatchedIfPossible: ViewModifier {
    var ns: Namespace.ID?
    func body(content: Content) -> some View {
        if let ns {
            content.matchedGeometryEffect(id: "rail-on", in: ns)
        } else {
            content
        }
    }
}
