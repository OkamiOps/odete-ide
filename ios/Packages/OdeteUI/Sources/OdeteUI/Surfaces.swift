import SwiftUI

/// Card padrão: superfície com raio 14, sem borda dura; `selected` ganha vidro tingido.
public struct OdeteCard<Content: View>: View {
    @Environment(\.theme) private var theme
    var selected: Bool
    var padding: CGFloat
    var floating: Bool
    @ViewBuilder var content: Content

    public init(
        selected: Bool = false,
        padding: CGFloat = Metrics.s3,
        floating: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.selected = selected
        self.padding = padding
        self.floating = floating
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                theme.bg.opacity(theme.dark ? 0.55 : 0.7),
                in: RoundedRectangle(cornerRadius: Metrics.rCard, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: Metrics.rCard, style: .continuous).stroke(
                selected ? theme.accent.opacity(0.7) : theme.separator,
                lineWidth: selected ? 1.5 : 0.5
            ))
            .shadow(color: floating ? .black.opacity(theme.dark ? 0.35 : 0.12) : .clear, radius: 14, y: 6)
    }
}

/// Título de seção dentro de um painel ou card: 11 pt, caixa alta, espaçado.
public struct SectionLabel: View {
    @Environment(\.theme) private var theme
    var text: String
    var trailing: String?
    public init(_ text: String, trailing: String? = nil) {
        self.text = text; self.trailing = trailing
    }

    public var body: some View {
        HStack {
            Text(text.uppercased()).font(OdeteFont.label).tracking(1.2).foregroundStyle(theme.fgSubtle)
            Spacer()
            if let trailing {
                Text(trailing).font(OdeteFont.mono(11)).foregroundStyle(theme.fgMuted)
                    .contentTransition(.numericText())
            }
        }
    }
}

/// Estado vazio: símbolo, título, texto e ação primária.
public struct EmptyState<Actions: View>: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var title: String
    var text: String
    @ViewBuilder var actions: Actions

    public init(_ symbol: String, title: String, text: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.text = text
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: Metrics.s3) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.fgMuted)
                .padding(.bottom, 2)
            Text(title).font(OdeteFont.ui(15, weight: .semibold)).foregroundStyle(theme.fg)
            Text(text).font(OdeteFont.ui(13)).foregroundStyle(theme.fgMuted).multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: Metrics.s2) { actions }.padding(.top, Metrics.s1)
        }
        .padding(Metrics.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Barra flutuante em vidro (cápsula) para controles: modo, ações, composer.
public struct GlassBar<Content: View>: View {
    var padding: CGFloat
    @ViewBuilder var content: Content
    public init(padding: CGFloat = 4, @ViewBuilder content: () -> Content) {
        self.padding = padding; self.content = content()
    }

    public var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 4) { content }
                .padding(padding)
                .glassEffect(.regular, in: Capsule())
        }
    }
}

/// Cápsula pequena de contagem/estado.
public struct Pill: View {
    @Environment(\.theme) private var theme
    var text: String
    var on: Bool
    var color: Color?
    public init(_ text: String, on: Bool = false, color: Color? = nil) {
        self.text = text; self.on = on; self.color = color
    }

    public var body: some View {
        Text(text).font(OdeteFont.mono(10.5, weight: on ? .medium : .regular))
            .foregroundStyle(on ? (color ?? theme.accent) : theme.fgMuted)
            .padding(.horizontal, 8).frame(height: 22)
            .background((on ? (color ?? theme.accent) : theme.fgSubtle).opacity(on ? 0.16 : 0.10), in: Capsule())
            .contentTransition(.numericText())
    }
}

/// Botão largo de painel: `.glass` ou `.glassProminent`, altura 38, ocupa a largura.
public struct WideButton: View {
    var title: String
    var symbol: String?
    var prominent: Bool
    var role: ButtonRole?
    var action: () -> Void

    public init(
        _ title: String,
        symbol: String? = nil,
        prominent: Bool = false,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title; self.symbol = symbol; self.prominent = prominent; self.role = role; self.action = action
    }

    public var body: some View {
        Group {
            if prominent {
                Button(role: role, action: action) { label }.buttonStyle(.glassProminent)
            } else {
                Button(role: role, action: action) { label }.buttonStyle(.glass)
            }
        }
        .controlSize(.small)
    }

    var label: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            }
            Text(title).font(.footnote.weight(.medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 18)
    }
}
