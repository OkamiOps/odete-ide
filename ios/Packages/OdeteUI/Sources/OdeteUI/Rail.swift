import OdeteCore
import SwiftUI

/// Barra de atividades vertical.
///
/// Em cima a marca, que leva de volta para a lista de projetos. No meio os painéis, com
/// o número de problemas e de arquivos alterados no próprio ícone — senão a pessoa só
/// descobre que o build quebrou quando abre o painel. Embaixo, separado por um fio, o
/// que não é painel: ajustes e o agente.
public struct Rail: View {
    @Environment(\.theme) private var theme
    @Namespace private var ns
    public var side: SidePanel
    public var sideOpen: Bool
    public var agentVisible: Bool
    public var agentBusy: Bool
    /// Problemas e arquivos alterados, para as bolinhas de contagem.
    public var problemas: Int
    public var problemasGraves: Bool
    public var alteracoes: Int
    public var onSelect: (SidePanel) -> Void
    public var onToggleAgent: () -> Void
    public var onSettings: () -> Void
    public var onProjects: () -> Void

    public init(
        side: SidePanel,
        sideOpen: Bool,
        agentVisible: Bool,
        agentBusy: Bool = false,
        problemas: Int = 0,
        problemasGraves: Bool = false,
        alteracoes: Int = 0,
        onSelect: @escaping (SidePanel) -> Void,
        onToggleAgent: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onProjects: @escaping () -> Void
    ) {
        self.side = side
        self.sideOpen = sideOpen
        self.agentVisible = agentVisible
        self.agentBusy = agentBusy
        self.problemas = problemas
        self.problemasGraves = problemasGraves
        self.alteracoes = alteracoes
        self.onSelect = onSelect
        self.onToggleAgent = onToggleAgent
        self.onSettings = onSettings
        self.onProjects = onProjects
    }

    public var body: some View {
        VStack(spacing: 2) {
            Button(action: onProjects) {
                BrandIcon(size: 28)
                    .frame(width: Metrics.railWidth, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Projetos")
            .help("Projetos")
            fio
            ForEach(SidePanel.allCases, id: \.self) { p in
                RailButton(
                    symbol: p.symbol,
                    label: p.label,
                    on: sideOpen && side == p,
                    conta: conta(p),
                    contaCor: p == .problems && problemasGraves ? theme.danger : theme.accent,
                    ns: ns
                ) { onSelect(p) }
            }
            Spacer(minLength: 0)
            fio
            RailButton(symbol: "gearshape", label: "Ajustes", on: false, ns: nil, action: onSettings)
            RailButton(
                symbol: "sparkles",
                label: "Agente",
                on: agentVisible,
                busy: agentBusy,
                destaque: true,
                ns: nil,
                action: onToggleAgent
            )
            .padding(.bottom, Metrics.s2)
        }
        .frame(width: Metrics.railWidth)
        .frame(maxHeight: .infinity)
        // Um degrau abaixo dos painéis, e uma borda de verdade: com o mesmo fundo dos
        // painéis a barra grudava na lista de arquivos e virava tudo uma coisa só.
        .background(theme.bg)
        .overlay(alignment: .trailing) { Rectangle().fill(theme.border).frame(width: 1) }
    }

    var fio: some View {
        Rectangle().fill(theme.separator)
            .frame(width: 22, height: 1)
            .padding(.vertical, Metrics.s1)
    }

    func conta(_ p: SidePanel) -> Int {
        switch p {
        case .problems: problemas
        case .git: alteracoes
        default: 0
        }
    }
}

struct RailButton: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var label: String
    var on: Bool
    var busy = false
    /// Número na bolinha do canto. Zero não desenha nada.
    var conta = 0
    var contaCor: Color?
    /// O agente é a ação principal do app: fica tingido mesmo desligado.
    var destaque = false
    var ns: Namespace.ID?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .symbolVariant(on ? .fill : .none)
                .symbolEffect(.pulse, isActive: busy)
                .foregroundStyle(on || destaque ? theme.accent : theme.fgMuted)
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
                    } else if destaque {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.accent.opacity(0.12))
                    }
                }
                .overlay(alignment: .topTrailing) { bolinha }
                .frame(width: Metrics.touch, height: Metrics.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(conta > 0 ? "\(label), \(conta)" : label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(on ? "Esconder \(label)" : "Mostrar \(label)")
        .animation(.snappy(duration: 0.22), value: on)
    }

    @ViewBuilder var bolinha: some View {
        if conta > 0 {
            Text(conta > 99 ? "99+" : "\(conta)")
                .font(.system(size: 9, weight: .bold)).monospacedDigit()
                .foregroundStyle(theme.bg)
                .padding(.horizontal, 3)
                .frame(minWidth: 15, minHeight: 15)
                .background(contaCor ?? theme.accent, in: Capsule())
                .overlay(Capsule().stroke(theme.bg, lineWidth: 1.5))
                .offset(x: 5, y: -3)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: conta)
        }
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
