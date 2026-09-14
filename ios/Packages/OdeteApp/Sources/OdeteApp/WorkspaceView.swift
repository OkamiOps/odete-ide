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
        Group {
            if sizeClass == .compact {
                PhoneShell()
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

    var padLayout: some View {
        @Bindable var chrome = chrome
        return HStack(spacing: 0) {
            Rail(
                side: chrome.snapshot.side,
                sideOpen: chrome.snapshot.sideOpen,
                agentVisible: chrome.snapshot.agentVisible,
                onSelect: { chrome.select(side: $0) },
                onToggleAgent: { chrome.toggleAgent() }
            )
            if chrome.snapshot.sideOpen {
                SidebarView()
                    .frame(width: chrome.snapshot.sideWidth)
                    .background(theme.bgElevated)
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
            if chrome.snapshot.agentVisible {
                Splitter(
                    value: $chrome.snapshot.agentWidth,
                    axis: .horizontal,
                    range: Metrics.minAgent ... Metrics.maxAgent,
                    direction: -1
                )
                AgentPane()
                    .frame(width: chrome.snapshot.agentWidth)
            }
        }
        .background(theme.bg)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.sideOpen)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.agentVisible)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.termVisible)
    }
}

struct SidebarView: View {
    @Environment(ChromeState.self) private var chrome

    var body: some View {
        switch chrome.snapshot.side {
        case .files: FileTreeView()
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
            // List (UICollectionView) em vez de ScrollView: rola com dedo, trackpad e roda.
            List {
                Group {
                    label("Tema")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(ThemePalette.all) { p in
                            Button { chrome.snapshot.theme = p.id } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 4) {
                                        Circle().fill(Color(hex: p.bg)).frame(width: 12, height: 12)
                                        Circle().fill(Color(hex: p.accent)).frame(width: 12, height: 12)
                                        Circle().fill(Color(hex: p.bgSubtle)).frame(width: 12, height: 12)
                                    }
                                    Text(p.label).font(OdeteFont.ui(12, weight: .medium)).foregroundStyle(theme.fg)
                                    Text(p.blurb).font(OdeteFont.ui(10)).foregroundStyle(theme.fgMuted).lineLimit(1)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(
                                    p.id == chrome.snapshot.theme ? theme.accent : theme.border,
                                    lineWidth: 1
                                ))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    label("Editor").padding(.top, 6)
                    HStack {
                        Text("Tamanho da fonte")
                        Spacer()
                        Stepper(
                            "\(Int(chrome.snapshot.editor.fontSize)) pt",
                            value: $chrome.snapshot.editor.fontSize,
                            in: 10 ... 22,
                            step: 1
                        )
                        .fixedSize()
                    }
                    Toggle("Salvar automaticamente", isOn: $chrome.snapshot.editor.autoSave)
                    Toggle("Quebrar linhas", isOn: $chrome.snapshot.editor.wrap)
                    Toggle("Números de linha", isOn: $chrome.snapshot.editor.lineNumbers)
                    label("Layout").padding(.top, 6)
                    Toggle("Agente", isOn: $chrome.snapshot.agentVisible)
                    Toggle("Terminal", isOn: $chrome.snapshot.termVisible)
                    Button("Restaurar layout") { chrome.resetLayout() }
                    label("Contas e Git").padding(.top, 6)
                    AccountsSettings()
                    label("Contas de IA").padding(.top, 6)
                    AIAccountsSettings()
                }
                .font(OdeteFont.ui(13))
                .foregroundStyle(theme.fg)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
        }
    }

    func label(_ s: String) -> some View {
        Text(s.uppercased()).font(OdeteFont.label).tracking(1).foregroundStyle(theme.fgSubtle)
    }
}
