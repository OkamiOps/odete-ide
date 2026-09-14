import OdeteCore
import SwiftUI

/// Barra de abas do editor. Toque seleciona; o "x" fecha; ponto indica alteração.
public struct EditorTabs: View {
    @Environment(\.theme) private var theme
    public var tabs: [EditorTab]
    public var active: String?
    public var onSelect: (String) -> Void
    public var onClose: (String) -> Void

    public init(
        tabs: [EditorTab],
        active: String?,
        onSelect: @escaping (String) -> Void,
        onClose: @escaping (String) -> Void
    ) {
        self.tabs = tabs
        self.active = active
        self.onSelect = onSelect
        self.onClose = onClose
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
                            onClose: { onClose(tab.path) }
                        )
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

struct TabItem: View {
    @Environment(\.theme) private var theme
    var tab: EditorTab
    var on: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    @State private var hover = false

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
            .accessibilityLabel(tab.isDirty ? "Fechar (não salvo)" : "Fechar")
            .padding(.trailing, 4)
        }
        // Aba ativa é uma cápsula preenchida. O traço no topo ficava solto, começando e
        // terminando fora da aba.
        .background(
            on ? theme.fg.opacity(theme.dark ? 0.12 : 0.08) : (hover ? theme.fg.opacity(0.05) : .clear),
            in: Capsule()
        )
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
