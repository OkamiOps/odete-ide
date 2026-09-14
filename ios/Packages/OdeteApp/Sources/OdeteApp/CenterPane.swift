import OdeteCore
import OdeteEditor
import OdeteUI
import SwiftUI

/// Abas, seletor de modo e o editor real.
struct CenterPane: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(WorkspaceModel.self) private var ws
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var chrome = chrome
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { app.closeWorkspace() } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.fgMuted)
                        .frame(width: Metrics.touch, height: Metrics.tab)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Projetos")
                .overlay(alignment: .trailing) { Rectangle().fill(theme.border).frame(width: 1) }
                EditorTabs(
                    tabs: ws.tabs,
                    active: ws.active,
                    onSelect: { ws.openFile($0) },
                    onClose: { ws.closeTab($0) }
                )
            }
            .background(theme.bgElevated)
            HStack {
                ModePicker(mode: $chrome.snapshot.center)
                Spacer()
                if let t = ws.activeTab {
                    Text(t.isDirty ? "não salvo" : "salvo")
                        .font(OdeteFont.mono(10))
                        .foregroundStyle(t.isDirty ? theme.accent : theme.fgSubtle)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.trailing, 6)
                }
                HeaderButton("command", label: "Paleta") { ws.paletteOpen = true }
                HeaderButton("square.and.arrow.down", label: "Salvar") { ws.save() }
                HeaderButton("sidebar.left", label: "Sidebar") { chrome.toggleSide() }
                HeaderButton("terminal", label: "Terminal") { chrome.toggleTerm() }
                HeaderButton("sidebar.right", label: "Agente") { chrome.toggleAgent() }
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
            content
        }
        .background(theme.bg)
    }

    @ViewBuilder var content: some View {
        switch chrome.snapshot.center {
        case .code: editor(ws.active)
        case .diff: DiffPane()
        case .dual:
            HStack(spacing: 0) {
                editor(ws.active)
                Rectangle().fill(theme.border).frame(width: 1)
                editor(ws.tabs.first { $0.path != ws.active }?.path)
            }
        case .split:
            HStack(spacing: 0) {
                editor(ws.active)
                Rectangle().fill(theme.border).frame(width: 1)
                PreviewPane()
            }
        case .preview: PreviewPane()
        }
    }

    @ViewBuilder func editor(_ path: String?) -> some View {
        if let path, ws.git.conflicts.contains(path), !ws.forceTextEdit.contains(path),
           ConflictParser.hasMarkers(ws.text(for: path))
        {
            ConflictView(path: path)
        } else if let path {
            VStack(spacing: 0) {
                Crumbs(path: path)
                CodeEditorView(
                    text: Binding(get: { ws.text(for: path) }, set: { ws.setText($0, for: path) }),
                    documentId: "\(ws.project.id):\(path)",
                    language: Language.detect(path: path),
                    palette: theme.palette,
                    prefs: chrome.snapshot.editor,
                    reveal: path == ws.active ? ws.reveal : nil,
                    onSave: { ws.save(path) },
                    onFind: { chrome.snapshot.side = .search; chrome.snapshot.sideOpen = true }
                )
            }
        } else {
            EmptyEditor()
        }
    }
}

struct Crumbs: View {
    @Environment(\.theme) private var theme
    var path: String
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(path.split(separator: "/").enumerated()), id: \.offset) { i, part in
                if i >
                    0
                {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.fgSubtle)
                }
                Text(part).font(OdeteFont.mono(11))
                    .foregroundStyle(i == path.split(separator: "/").count - 1 ? theme.fgMuted : theme.fgSubtle)
            }
            Spacer()
            Text(Language.detect(path: path).label).font(OdeteFont.mono(10)).foregroundStyle(theme.fgSubtle)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

struct EmptyEditor: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 14) {
            Wordmark(height: 26).opacity(0.5)
            Text("Abra um arquivo na árvore ou crie um novo.")
                .font(OdeteFont.ui(13)).foregroundStyle(theme.fgMuted)
            Button { ws.createFile(near: nil) } label: { Label("Novo arquivo", systemImage: "doc.badge.plus") }
                .buttonStyle(.glass)
            HStack(spacing: 14) {
                key("⌘P", "paleta"); key("⌘S", "salvar"); key("⌘B", "sidebar"); key("⌘J", "terminal")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func key(_ k: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(k).font(OdeteFont.mono(11)).foregroundStyle(theme.fg)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(theme.bgSubtle, in: RoundedRectangle(cornerRadius: 5))
            Text(what).font(OdeteFont.ui(11)).foregroundStyle(theme.fgSubtle)
        }
    }
}
