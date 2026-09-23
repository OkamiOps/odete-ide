import OdeteCore
import OdeteI18n
import SwiftUI

/// Barra de abas do editor. Toque seleciona; o "x" fecha; ponto indica alteração.
public struct EditorTabs: View {
    @Environment(\.theme) private var theme
    public var tabs: [EditorTab]
    public var active: String?
    public var onSelect: (String) -> Void
    public var onClose: (String) -> Void
    /// Menu de toque longo de cada aba, montado por quem conhece o app. Sem ele, não há.
    public var menu: (@MainActor (String) -> AnyView)?

    public init(
        tabs: [EditorTab],
        active: String?,
        onSelect: @escaping (String) -> Void,
        onClose: @escaping (String) -> Void,
        menu: (@MainActor (String) -> AnyView)? = nil
    ) {
        self.tabs = tabs
        self.active = active
        self.onSelect = onSelect
        self.onClose = onClose
        self.menu = menu
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        TabItem(
                            tab: tab,
                            on: tab.path == active,
                            onSelect: { onSelect(tab.path) },
                            onClose: { onClose(tab.path) },
                            menu: menu.map { m in { m(tab.path) } }
                        )
                        .equatable()
                        .id(tab.path)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .onChange(of: active) { _, new in
                if let new {
                    withAnimation { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
        .frame(height: Metrics.tab)
        .background(theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 0.5) }
    }
}

/// Uma aba.
///
/// `Equatable` pela aba e por estar ativa, sem os fechamentos. Os fechamentos são novos a
/// cada vez que o centro se refaz — e ele se refaz a cada pausa na digitação, quando a
/// análise do arquivo chega —, e o SwiftUI, que não sabe comparar fechamento, refazia
/// todas as abas junto. Medido digitando, as abas eram a segunda view mais cara depois da
/// barra de status. Agora só a aba cujo ponto de alteração mudou se refaz.
struct TabItem: View, Equatable {
    @Environment(\.theme) private var theme
    var tab: EditorTab
    var on: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    /// Fica fora da comparação, como os outros fechamentos: o menu é montado na hora do
    /// toque longo, com o estado de então.
    var menu: (@MainActor () -> AnyView)?
    @State private var hover = false

    nonisolated static func == (a: TabItem, b: TabItem) -> Bool {
        a.tab == b.tab && a.on == b.on
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    FileGlyph(path: tab.path, size: 13)
                    Text(tab.path.split(separator: "/").last.map(String.init) ?? tab.path)
                        .font(OdeteFont.ui(12.5, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? theme.fg : theme.fgMuted)
                        .lineLimit(1)
                }
                .padding(.leading, 12)
                .frame(height: Metrics.tab - 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onClose) {
                ZStack {
                    if tab.isDirty, !hover {
                        Circle().fill(theme.accent).frame(width: 7, height: 7)
                    } else {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundStyle(theme.fgSubtle)
                .frame(width: 26, height: Metrics.tab - 6)
                .contentShape(Rectangle())
                .opacity(on || hover || tab.isDirty ? 1 : 0.35)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.isDirty ? tr("Fechar (não salvo)") : "Fechar")
            .padding(.trailing, 4)
        }
        // Aba ativa é uma cápsula preenchida. O traço no topo ficava solto, começando e
        // terminando fora da aba.
        .background(
            on ? theme.fg.opacity(theme.dark ? 0.12 : 0.08) : (hover ? theme.fg.opacity(0.05) : .clear),
            in: Capsule()
        )
        .onHover { hover = $0 }
        .modifier(MenuDaAba(menu: menu))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Pendura o menu de toque longo só quando há um: `contextMenu` vazio ainda faz a aba
/// reagir ao toque longo, sem nada para mostrar.
private struct MenuDaAba: ViewModifier {
    var menu: (@MainActor () -> AnyView)?

    func body(content: Content) -> some View {
        if let menu {
            content.contextMenu { menu() }
        } else {
            content
        }
    }
}
