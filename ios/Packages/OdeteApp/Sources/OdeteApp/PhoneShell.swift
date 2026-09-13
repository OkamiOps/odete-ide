import OdeteCore
import OdeteEditor
import OdeteUI
import SwiftUI

/// Layout de iPhone: uma aba por painel.
struct PhoneShell: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(WorkspaceModel.self) private var ws
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var chrome = chrome
        TabView(selection: $chrome.snapshot.phoneTab) {
            Tab(PhoneTab.files.label, systemImage: PhoneTab.files.symbol, value: PhoneTab.files) {
                VStack(spacing: 0) {
                    HStack {
                        Button { app.closeWorkspace() } label: { Label("Projetos", systemImage: "square.grid.2x2") }
                            .buttonStyle(.glass)
                        Spacer()
                        Text(ws.project.name).font(OdeteFont.ui(13, weight: .semibold)).foregroundStyle(theme.fg)
                    }
                    .padding(10)
                    FileTreeView()
                }
                .background(theme.bgElevated)
                .onChange(of: ws.active) {
                    _, new in if new != nil {
                        chrome.snapshot.phoneTab = .edit
                    }
                }
            }
            Tab(PhoneTab.edit.label, systemImage: PhoneTab.edit.symbol, value: PhoneTab.edit) {
                VStack(spacing: 0) {
                    EditorTabs(
                        tabs: ws.tabs,
                        active: ws.active,
                        onSelect: { ws.openFile($0) },
                        onClose: { ws.closeTab($0) }
                    )
                    if let path = ws.active {
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
            }
            Tab(PhoneTab.agent.label, systemImage: PhoneTab.agent.symbol, value: PhoneTab.agent) {
                AgentColumn()
            }
            Tab(PhoneTab.term.label, systemImage: PhoneTab.term.symbol, value: PhoneTab.term) {
                TerminalDrawer()
            }
            Tab(PhoneTab.preview.label, systemImage: PhoneTab.preview.symbol, value: PhoneTab.preview) {
                ShellPanel(
                    "Preview",
                    symbol: "play.rectangle",
                    phase: 3,
                    blurb: "O app do usuário rodando no dispositivo."
                ).background(theme.bg)
            }
            Tab(PhoneTab.settings.label, systemImage: PhoneTab.settings.symbol, value: PhoneTab.settings) {
                SettingsShell().background(theme.bgElevated)
            }
        }
        .tabViewStyle(.tabBarOnly)
    }
}
