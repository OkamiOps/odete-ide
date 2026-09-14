import OdeteCore
import OdeteUI
import SwiftUI

/// Layout de iPad: rail, sidebar, centro, agente e a gaveta do terminal.
struct WorkspaceView: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(WorkspaceModel.self) private var ws
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { geo in
            // iPhone, ou iPad em retrato/janela estreita: abas embaixo como um iPhone grande,
            // no máximo dividindo a tela com o agente. Paisagem: colunas.
            let portrait = geo.size.width < geo.size.height || geo.size.width < 1000
            if sizeClass == .compact {
                PhoneShell()
            } else if portrait {
                portraitLayout(width: geo.size.width)
            } else {
                padLayout
            }
        }
        .overlay {
            if ws.paletteOpen {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { ws.paletteOpen = false }
                    CommandPalette().padding(.top, 60)
                }
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.15), value: ws.paletteOpen)
        .focusedSceneValue(\.workspaceActions, WorkspaceActions(ws: ws, chrome: chrome, app: app))
        .alert("Erro", isPresented: Binding(get: { ws.error != nil }, set: {
            if !$0 {
                ws.error = nil
            }
        })) {
            Button("OK") { ws.error = nil }
        } message: { Text(ws.error ?? "") }
    }

    func portraitLayout(width: CGFloat) -> some View {
        @Bindable var chrome = chrome
        return HStack(spacing: 0) {
            PhoneShell(showAgentTab: !chrome.snapshot.agentVisible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if chrome.snapshot.agentVisible {
                Splitter(
                    value: $chrome.snapshot.agentWidth,
                    axis: .horizontal,
                    range: Metrics.minAgent ... max(Metrics.minAgent, width * 0.5),
                    direction: -1
                )
                AgentPane()
                    .frame(width: min(chrome.snapshot.agentWidth, width * 0.5))
            }
        }
        .background(theme.bg)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.agentVisible)
    }

    var padLayout: some View {
        GeometryReader { geo in
            // O centro precisa de ~470 pt; o agente cede antes da sidebar.
            let sideW = chrome.snapshot.sideOpen ? min(chrome.snapshot.sideWidth, geo.size.width * 0.26) : 0
            let free = geo.size.width - Metrics.railWidth - 24 - sideW - 470
            let agentW = chrome.snapshot.agentVisible ? min(chrome.snapshot.agentWidth, max(Metrics.minAgent, free)) : 0
            columns(narrow: false, sideW: sideW, agentW: agentW)
        }
        .background(theme.bg)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.sideOpen)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.agentVisible)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.termVisible)
    }

    func columns(narrow: Bool, sideW: Double, agentW: Double) -> some View {
        @Bindable var chrome = chrome
        return HStack(spacing: 0) {
            Rail(
                side: chrome.snapshot.side,
                sideOpen: chrome.snapshot.sideOpen,
                agentVisible: chrome.snapshot.agentVisible,
                agentBusy: ws.agent.running,
                onSelect: { chrome.select(side: $0) },
                onToggleAgent: { chrome.toggleAgent() }
            )
            if chrome.snapshot.sideOpen {
                SidebarView()
                    .frame(width: sideW)
                    .background(theme.surface)
                Splitter(
                    value: $chrome.snapshot.sideWidth,
                    axis: .horizontal,
                    range: Metrics.minSide ... Metrics.maxSide
                )
            }
            VStack(spacing: 0) {
                CenterPane()
                if chrome.snapshot.termVisible {
                    Splitter(
                        value: $chrome.snapshot.termHeight,
                        axis: .vertical,
                        range: Metrics.minTerm ... Metrics.maxTerm,
                        direction: -1
                    )
                    TerminalPane()
                        .frame(height: chrome.snapshot.termHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            if chrome.snapshot.agentVisible, !narrow {
                Splitter(
                    value: $chrome.snapshot.agentWidth,
                    axis: .horizontal,
                    range: Metrics.minAgent ... Metrics.maxAgent,
                    direction: -1
                )
                AgentPane()
                    .frame(width: agentW)
            }
        }
    }
}

struct SidebarView: View {
    @Environment(ChromeState.self) private var chrome

    var body: some View {
        switch chrome.snapshot.side {
        case .files: FileTreeView()
        case .outline: OutlinePane()
        case .search: SearchPane()
        case .git: GitPane()
        case .problems: ProblemsPane()
        case .settings: SettingsShell()
        }
    }
}

struct SettingsShell: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var chrome = chrome
        VStack(spacing: 0) {
            PaneHeader("Ajustes")
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Metrics.s2)], spacing: Metrics.s2) {
                        ForEach(ThemePalette.all) { p in
                            Button { withAnimation(.snappy(duration: 0.2)) { chrome.snapshot.theme = p.id } } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 4) {
                                        Circle().fill(Color(hex: p.bg)).frame(width: 12, height: 12)
                                            .overlay(Circle().stroke(
                                                .white.opacity(0.15),
                                                lineWidth: 0.5
                                            ))
                                        Circle().fill(Color(hex: p.accent)).frame(width: 12, height: 12)
                                        Circle().fill(Color(hex: p.bgSubtle)).frame(width: 12, height: 12)
                                    }
                                    Text(p.label).font(OdeteFont.ui(12.5, weight: .medium))
                                        .foregroundStyle(Color(hex: p.fg))
                                    Text(p.blurb).font(OdeteFont.ui(10.5)).foregroundStyle(Color(hex: p.fgMuted))
                                        .lineLimit(1)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    Color(hex: p.bg),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(
                                    p.id == chrome.snapshot.theme ? theme.accent : theme.separator,
                                    lineWidth: p.id == chrome.snapshot.theme ? 1.5 : 0.5
                                ))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
                } header: { header("Tema") }
                Section {
                    Stepper(value: $chrome.snapshot.editor.fontSize, in: 10 ... 22, step: 1) {
                        LabeledContent("Tamanho da fonte") {
                            Text("\(Int(chrome.snapshot.editor.fontSize)) pt").font(OdeteFont.mono(12))
                                .foregroundStyle(theme.fgMuted)
                        }
                    }
                    Toggle("Salvar automaticamente", isOn: $chrome.snapshot.editor.autoSave)
                    Toggle("Quebrar linhas", isOn: $chrome.snapshot.editor.wrap)
                    Toggle("Números de linha", isOn: $chrome.snapshot.editor.lineNumbers)
                } header: { header("Editor") }
                Section {
                    Toggle("Agente", isOn: $chrome.snapshot.agentVisible)
                    Toggle("Terminal", isOn: $chrome.snapshot.termVisible)
                    Button("Restaurar layout") { chrome.resetLayout() }
                } header: { header("Layout") }
                Section { AccountsSettings() } header: { header("Contas e Git") }
                Section { AIAccountsSettings() } header: { header("Contas de IA") }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .listRowBackground(theme.bg.opacity(theme.dark ? 0.55 : 0.7))
            .font(OdeteFont.ui(13.5))
            .foregroundStyle(theme.fg)
            .tint(theme.accent)
        }
        .background(theme.surface)
    }

    func header(_ s: String) -> some View {
        Text(s.uppercased()).font(OdeteFont.label).tracking(1.2).foregroundStyle(theme.fgSubtle)
    }
}
