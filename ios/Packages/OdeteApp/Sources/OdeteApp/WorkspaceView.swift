import OdeteCore
import OdeteUI
import SwiftUI

/// Layout de iPad: rail, sidebar, centro, agente e a gaveta do terminal.
struct WorkspaceView: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(WorkspaceModel.self) private var ws
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var chrome = chrome
        HStack(spacing: 0) {
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
                Splitter(value: $chrome.snapshot.sideWidth, axis: .horizontal, range: Metrics.minSide ... Metrics.maxSide)
            }
            VStack(spacing: 0) {
                CenterPane()
                if chrome.snapshot.termVisible {
                    Splitter(value: $chrome.snapshot.termHeight, axis: .vertical, range: Metrics.minTerm ... Metrics.maxTerm, direction: -1)
                    TerminalDrawer()
                        .frame(height: chrome.snapshot.termHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if chrome.snapshot.agentVisible {
                Splitter(value: $chrome.snapshot.agentWidth, axis: .horizontal, range: Metrics.minAgent ... Metrics.maxAgent, direction: -1)
                AgentColumn()
                    .frame(width: chrome.snapshot.agentWidth)
            }
        }
        .background(theme.bg)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.sideOpen)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.agentVisible)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.termVisible)
        .alert("Erro", isPresented: Binding(get: { ws.error != nil }, set: { if !$0 { ws.error = nil } })) {
            Button("OK") { ws.error = nil }
        } message: { Text(ws.error ?? "") }
        .background {
            // Atalhos de teclado físico.
            Group {
                Button("") { ws.save() }.keyboardShortcut("s", modifiers: .command)
                Button("") { chrome.toggleSide() }.keyboardShortcut("b", modifiers: .command)
                Button("") { chrome.toggleTerm() }.keyboardShortcut("j", modifiers: .command)
                Button("") { if let a = ws.active { ws.closeTab(a) } }.keyboardShortcut("w", modifiers: .command)
                Button("") { chrome.toggleAgent() }.keyboardShortcut("i", modifiers: .command)
            }
            .opacity(0)
        }
    }
}

struct SidebarView: View {
    @Environment(ChromeState.self) private var chrome

    var body: some View {
        switch chrome.snapshot.side {
        case .files: FileTreeView()
        case .search: ShellPanel("Busca", symbol: "magnifyingglass", phase: 1, blurb: "Busca no projeto chega no marco 5.")
        case .git: ShellPanel("Git", symbol: "arrow.triangle.branch", phase: 2, blurb: "Commits, branches e GitHub com libgit2.")
        case .problems: ShellPanel("Problemas", symbol: "exclamationmark.circle", phase: 3, blurb: "Diagnósticos do lint e do build.")
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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(p.id == chrome.snapshot.theme ? theme.accent : theme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    label("Editor").padding(.top, 6)
                    HStack {
                        Text("Tamanho da fonte")
                        Spacer()
                        Stepper("\(Int(chrome.snapshot.editor.fontSize)) pt", value: $chrome.snapshot.editor.fontSize, in: 10 ... 22, step: 1)
                            .fixedSize()
                    }
                    Toggle("Salvar automaticamente", isOn: $chrome.snapshot.editor.autoSave)
                    Toggle("Quebrar linhas", isOn: $chrome.snapshot.editor.wrap)
                    Toggle("Números de linha", isOn: $chrome.snapshot.editor.lineNumbers)
                    label("Layout").padding(.top, 6)
                    Toggle("Agente", isOn: $chrome.snapshot.agentVisible)
                    Toggle("Terminal", isOn: $chrome.snapshot.termVisible)
                    Button("Restaurar layout") { chrome.resetLayout() }
                    label("Em breve").padding(.top, 6)
                    Text("Agente (Fase 4) · Git (Fase 2) · Segurança e chaves (Fase 4)")
                        .font(OdeteFont.ui(12)).foregroundStyle(theme.fgMuted)
                }
                .font(OdeteFont.ui(13))
                .foregroundStyle(theme.fg)
                .padding(12)
            }
        }
    }

    func label(_ s: String) -> some View {
        Text(s.uppercased()).font(OdeteFont.label).tracking(1).foregroundStyle(theme.fgSubtle)
    }
}

struct AgentColumn: View {
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Agente", detail: "Claude · Sonnet") {
                HeaderButton("plus.bubble", label: "Novo chat") {}
            }
            ShellPanel("Agente", symbol: "sparkles", phase: 4, blurb: "Claude, Codex e Grok pela sua assinatura, editando o projeto.")
            HStack(spacing: 8) {
                Text("Peça algo à Odete…").font(OdeteFont.ui(13)).foregroundStyle(theme.fgSubtle)
                Spacer()
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).foregroundStyle(theme.fgSubtle)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.border))
            .padding(10)
        }
        .background(theme.bgElevated)
        .overlay(alignment: .leading) { Rectangle().fill(theme.border).frame(width: 1) }
    }
}

struct TerminalDrawer: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Terminal", detail: "~/\(ws.project.name)") {
                HeaderButton("xmark", label: "Fechar terminal") { chrome.toggleTerm() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("odete ~/\(ws.project.name) %").font(OdeteFont.mono(12)).foregroundStyle(theme.accent)
                Text("shell nativo, npm por ESM e Node em JavaScriptCore chegam na Fase 3").font(OdeteFont.mono(12)).foregroundStyle(theme.fgMuted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.bgElevated)
    }
}
