import OdeteCore
import OdeteEditor
import OdeteI18n
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
    @Environment(\.emJanela) private var emJanela

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
            content(tabs.contains(chrome.snapshot.phoneTab) ? chrome.snapshot.phoneTab : .files)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom) { bottomBar }
        }
    }

    /// Barra de abas do iPad em retrato.
    var bottomBar: some View {
        GlassEffectContainer {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.self) { t in
                    let on = chrome.snapshot.phoneTab == t
                    Button { withAnimation(.snappy(duration: 0.2)) { chrome.snapshot.phoneTab = t } } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.symbol)
                                .font(.system(size: 17, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .symbolVariant(on ? .fill : .none)
                            Text(t.label).font(OdeteFont.ui(10, weight: on ? .semibold : .regular))
                        }
                        .foregroundStyle(on ? theme.accent : theme.fgMuted)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background {
                            if on {
                                Capsule().fill(theme.glassTint)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .glassEffect(.regular, in: Capsule())
        }
        .padding(.horizontal, Metrics.s4)
        .padding(.bottom, Metrics.s2)
    }

    @ViewBuilder func content(_ tab: PhoneTab) -> some View {
        @Bindable var chrome = chrome
        switch tab {
        case .files:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { app.closeWorkspace() } label: { Label(tr("Projetos"), systemImage: "square.grid.2x2") }
                        .buttonStyle(.glass)
                    Picker(tr("Painel"), selection: $chrome.snapshot.side) {
                        ForEach(SidePanel.allCases, id: \.self) { p in
                            Image(systemName: p.symbol).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    Spacer()
                    // Numa janela o nome já está na faixa de título, logo acima.
                    if !emJanela {
                        Text(ws.project.name).font(OdeteFont.ui(13, weight: .semibold)).foregroundStyle(theme.fg)
                            .lineLimit(1)
                    }
                }
                .padding(10)
                SidebarView()
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
                    onClose: { ws.closeTab($0) },
                    menu: menuDaAba(ws)
                )
                if let path = ws.active, ws.naoEhTexto.contains(path) {
                    // O mesmo desvio do layout largo: imagem, PDF e banco vão para o
                    // visualizador. Sem ele, aqui um `.sqlite` abria como uma página em
                    // branco com a linha 1 — nem o arquivo, nem um aviso.
                    FileViewer(path: path)
                } else if let path = ws.active {
                    if ws.conflitos.contains(path) {
                        FaixaDeConflito(path: path)
                    }
                    if let p = ws.agent.pendingPatches.first(where: { $0.path == path }) {
                        PatchBanner(patch: p)
                    }
                    CodeEditorView(
                        text: Binding(get: { ws.text(for: path) }, set: { ws.setText($0, for: path) }),
                        documentId: "\(ws.project.id):\(path)",
                        language: Language.detect(path: path),
                        palette: theme.palette,
                        prefs: chrome.snapshot.editor,
                        reveal: ws.pedidoDeLinha(para: path),
                        changes: ws.patchChanges[path] ?? [],
                        config: ws.configDoArquivo(path),
                        onSave: { ws.save(path) },
                        onCursor: { ws.anotarCursor($0, em: path) },
                        aoConsumirLinha: { ws.linhaRevelada($0) }
                    )
                } else {
                    EmptyEditor()
                }
            }
            .background(theme.bg)
            .perguntaAoFecharAba()
        case .agent: AgentPane()
        case .term: TerminalPane()
        case .preview: PreviewPane()
        case .settings: SettingsShell().background(theme.bgElevated)
        }
    }
}
