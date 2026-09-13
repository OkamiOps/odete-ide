import OdeteCore
import OdeteUI
import SwiftUI

/// Layout de iPad: rail, sidebar, centro, agente e a gaveta do terminal.
struct WorkspaceView: View {
    @Environment(ChromeState.self) private var chrome
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
        .ignoresSafeArea(.keyboard)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.sideOpen)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.agentVisible)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.termVisible)
    }
}

struct SidebarView: View {
    @Environment(ChromeState.self) private var chrome

    var body: some View {
        switch chrome.snapshot.side {
        case .files: FilesShell()
        case .search: ShellPanel("Busca", symbol: "magnifyingglass", phase: 1, blurb: "Busca no projeto chega no marco 5.")
        case .git: ShellPanel("Git", symbol: "arrow.triangle.branch", phase: 2, blurb: "Commits, branches e GitHub com libgit2.")
        case .problems: ShellPanel("Problemas", symbol: "exclamationmark.circle", phase: 3, blurb: "Diagnósticos do lint e do build.")
        case .settings: SettingsShell()
        }
    }
}

struct FilesShell: View {
    @Environment(\.theme) private var theme
    private let sample: [(String, Bool, Int)] = [
        ("src", true, 0), ("App.tsx", false, 1), ("main.tsx", false, 1), ("style.css", false, 1),
        ("index.html", false, 0), ("package.json", false, 0), ("README.md", false, 0), ("vite.config.ts", false, 0),
    ]

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Arquivos", detail: "meu-app") {
                HeaderButton("doc.badge.plus", label: "Novo arquivo") {}
                HeaderButton("folder.badge.plus", label: "Nova pasta") {}
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(sample.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            if row.1 {
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.fgSubtle).frame(width: 12)
                            } else {
                                Spacer().frame(width: 12)
                            }
                            FileGlyph(path: row.0, isDirectory: row.1, expanded: true)
                            Text(row.0).font(OdeteFont.ui(13)).foregroundStyle(theme.fg)
                            Spacer()
                        }
                        .padding(.leading, 10 + CGFloat(row.2) * 16)
                        .frame(height: Metrics.row)
                        .background(row.0 == "App.tsx" ? theme.bgSubtle : .clear)
                    }
                }
            }
        }
    }
}

struct SettingsShell: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Ajustes")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("TEMA").font(OdeteFont.label).tracking(1).foregroundStyle(theme.fgSubtle)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(ThemePalette.all) { p in
                            Button {
                                chrome.snapshot.theme = p.id
                            } label: {
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
                    Text("LAYOUT").font(OdeteFont.label).tracking(1).foregroundStyle(theme.fgSubtle).padding(.top, 6)
                    Toggle("Agente", isOn: Binding(get: { chrome.snapshot.agentVisible }, set: { chrome.snapshot.agentVisible = $0 }))
                    Toggle("Terminal", isOn: Binding(get: { chrome.snapshot.termVisible }, set: { chrome.snapshot.termVisible = $0 }))
                    Button("Restaurar layout") { chrome.resetLayout() }.font(OdeteFont.ui(12))
                }
                .font(OdeteFont.ui(13))
                .foregroundStyle(theme.fg)
                .padding(12)
            }
        }
    }
}

struct CenterPane: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    @State private var tabs: [EditorTab] = [EditorTab(path: "src/App.tsx", isDirty: true), EditorTab(path: "index.html"), EditorTab(path: "README.md")]
    @State private var active: String? = "src/App.tsx"

    var body: some View {
        @Bindable var chrome = chrome
        VStack(spacing: 0) {
            EditorTabs(tabs: tabs, active: active, onSelect: { active = $0 }, onClose: { p in
                tabs.removeAll { $0.path == p }
                if active == p { active = tabs.first?.path }
            })
            HStack {
                ModePicker(mode: $chrome.snapshot.center)
                Spacer()
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
        case .code: EditorShell(path: active)
        case .diff: ShellPanel("Diff", symbol: "plus.forwardslash.minus", phase: 2, blurb: "Diferenças contra o último commit.")
        case .dual: HStack(spacing: 0) { EditorShell(path: active); Rectangle().fill(theme.border).frame(width: 1); EditorShell(path: "index.html") }
        case .split: HStack(spacing: 0) { EditorShell(path: active); Rectangle().fill(theme.border).frame(width: 1); ShellPanel("Preview", symbol: "play.rectangle", phase: 3, blurb: "O app do usuário rodando no dispositivo.") }
        case .preview: ShellPanel("Preview", symbol: "play.rectangle", phase: 3, blurb: "O app do usuário rodando no dispositivo.")
        }
    }
}

/// Editor casca com um trecho fixo, só para o marco 1. O Runestone entra no marco 4.
struct EditorShell: View {
    @Environment(\.theme) private var theme
    var path: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(path ?? "nenhum arquivo")
                .font(OdeteFont.mono(11))
                .foregroundStyle(theme.fgSubtle)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sample.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(i + 1)").font(OdeteFont.mono(12)).foregroundStyle(theme.fgSubtle).frame(width: 40, alignment: .trailing).padding(.trailing, 14)
                            Text(line).font(OdeteFont.mono(13)).foregroundStyle(theme.fg)
                        }
                        .frame(height: 20)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var sample: [AttributedString] {
        let p = theme.palette.syntax
        func t(_ s: String, _ hex: String) -> AttributedString {
            var a = AttributedString(s)
            a.foregroundColor = Color(hex: hex)
            return a
        }
        func plain(_ s: String) -> AttributedString { AttributedString(s) }
        return [
            t("import", p.keyword) + plain(" { useState } ") + t("from", p.keyword) + plain(" ") + t("\"react\"", p.string) + plain(";"),
            plain(""),
            t("export function", p.keyword) + plain(" ") + t("App", p.function) + plain("() {"),
            plain("  ") + t("const", p.keyword) + plain(" [n, setN] = ") + t("useState", p.function) + plain("(") + t("0", p.number) + plain(");"),
            plain("  ") + t("return", p.keyword) + plain(" ("),
            plain("    <") + t("main", p.type) + plain(" className=") + t("\"page\"", p.string) + plain(">"),
            plain("      <") + t("h1", p.type) + plain(">Odete</") + t("h1", p.type) + plain(">"),
            plain("      <") + t("button", p.type) + plain(" onClick={() => setN(n + ") + t("1", p.number) + plain(")}>{n} cliques</") + t("button", p.type) + plain(">"),
            plain("    </") + t("main", p.type) + plain(">"),
            plain("  );"),
            plain("}"),
            plain(""),
            t("// editor real com Runestone chega no marco 4", p.comment),
        ]
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
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Terminal", detail: "~/meu-app") {
                HeaderButton("xmark", label: "Fechar terminal") { chrome.toggleTerm() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("odete ~/meu-app %").font(OdeteFont.mono(12)).foregroundStyle(theme.accent)
                Text("shell nativo, npm por ESM e Node em JavaScriptCore chegam na Fase 3").font(OdeteFont.mono(12)).foregroundStyle(theme.fgMuted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.bgElevated)
    }
}
