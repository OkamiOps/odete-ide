import OdeteCore
import OdeteEditor
import OdeteUI
import SwiftUI

/// Layout de abas: iPhone (TabView nativa) e iPad em retrato (barra própria embaixo, como um iPhone grande).
struct PhoneShell: View {
    /// Falso quando o agente já está numa coluna ao lado (retrato no iPad).
    var showAgentTab = true
    @Environment(ChromeState.self) private var chrome
    @Environment(WorkspaceModel.self) private var ws
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    var tabs: [PhoneTab] {
        PhoneTab.allCases.filter { showAgentTab || $0 != .agent }
    }

    var body: some View {
        @Bindable var chrome = chrome
        if sizeClass == .compact {
            TabView(selection: $chrome.snapshot.phoneTab) {
                ForEach(tabs, id: \.self) { t in
                    Tab(t.label, systemImage: t.symbol, value: t) { content(t) }
                }
            }
            .tabViewStyle(.tabBarOnly)
        } else {
            VStack(spacing: 0) {
                content(tabs.contains(chrome.snapshot.phoneTab) ? chrome.snapshot.phoneTab : .files)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar
            }
        }
    }

    /// Barra de abas do iPad em retrato.
    var bottomBar: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { t in
                let on = chrome.snapshot.phoneTab == t
                Button { chrome.snapshot.phoneTab = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol).font(.system(size: 18, weight: on ? .semibold : .regular))
                        Text(t.label).font(OdeteFont.ui(10, weight: on ? .semibold : .regular))
                    }
                    .foregroundStyle(on ? theme.accent : theme.fgMuted)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .background(theme.bgElevated)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    @ViewBuilder func content(_ tab: PhoneTab) -> some View {
        @Bindable var chrome = chrome
        switch tab {
        case .files:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { app.closeWorkspace() } label: { Label("Projetos", systemImage: "square.grid.2x2") }
                        .buttonStyle(.glass)
                    Picker("Painel", selection: $chrome.snapshot.side) {
                        ForEach([SidePanel.files, .search, .git, .problems], id: \.self) { p in
                            Image(systemName: p.symbol).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    Spacer()
                    Text(ws.project.name).font(OdeteFont.ui(13, weight: .semibold)).foregroundStyle(theme.fg)
                        .lineLimit(1)
                }
                .padding(10)
                if chrome.snapshot.side == .settings {
                    FileTreeView()
                } else {
                    SidebarView()
                }
            }
            .background(theme.bgElevated)
            .onChange(of: ws.active) { _, new in
                if new != nil, chrome.snapshot.side == .files {
                    chrome.snapshot.phoneTab = .edit
                }
            }
        case .edit:
            VStack(spacing: 0) {
                EditorTabs(
                    tabs: ws.tabs,
                    active: ws.active,
                    onSelect: { ws.openFile($0) },
                    onClose: { ws.closeTab($0) }
                )
                if let path = ws.active {
                    if let p = ws.agent.pendingPatches.first(where: { $0.path == path }) {
                        PatchBanner(patch: p)
                    }
                    CodeEditorView(
                        text: Binding(get: { ws.text(for: path) }, set: { ws.setText($0, for: path) }),
                        documentId: "\(ws.project.id):\(path)",
                        language: Language.detect(path: path),
                        palette: theme.palette,
                        prefs: chrome.snapshot.editor,
                        reveal: ws.reveal,
                        onSave: { ws.save(path) }
                    )
                } else {
                    EmptyEditor()
                }
            }
            .background(theme.bg)
        case .agent: AgentPane()
        case .term: TerminalPane()
        case .preview: PreviewPane()
        case .settings: SettingsShell().background(theme.bgElevated)
        }
    }
}
