import OdeteAgent
import OdeteCore
import OdeteEditor
import OdeteGit
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
                EditorTabs(
                    tabs: ws.tabs,
                    active: ws.active,
                    onSelect: { ws.openFile($0) },
                    onClose: { ws.closeTab($0) }
                )
            }
            .background(theme.surface)
            // Largura medida uma vez por layout (ViewThatFits media o ModePicker fora da main thread e travava).
            HStack(spacing: Metrics.s2) {
                if toolbarWidth >= 560 {
                    ModePicker(mode: $chrome.snapshot.center)
                    Spacer(minLength: Metrics.s2)
                    if toolbarWidth >= 640, let t = ws.activeTab {
                        Pill(t.isDirty ? "não salvo" : "salvo", on: t.isDirty)
                    }
                    actions
                } else {
                    Menu {
                        ForEach(CenterMode.allCases, id: \.self) { m in
                            Button { chrome.snapshot.center = m } label: { Label(
                                m.label,
                                systemImage: m == chrome.snapshot.center ? "checkmark" : ""
                            ) }
                        }
                    } label: {
                        HStack(spacing: 6) { Text(chrome.snapshot.center.label).font(OdeteFont.ui(
                            12,
                            weight: .semibold
                        )); Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                            .foregroundStyle(theme.fg).padding(.horizontal, 12).frame(height: 30).glassEffect(
                                .regular,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: Metrics.s2)
                    actions
                }
            }
            .padding(.horizontal, Metrics.s3)
            .frame(height: 52)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarWidth = $0 }
            content
        }
        .background(theme.bg)
    }

    var actions: some View {
        GlassBar {
            HeaderButton("command", label: "Paleta") { ws.paletteOpen = true }
            HeaderButton("square.and.arrow.down", label: "Salvar") { ws.save() }
            HeaderButton("sidebar.left", label: "Sidebar") { chrome.toggleSide() }
            HeaderButton("terminal", label: "Terminal") { chrome.toggleTerm() }
            HeaderButton("sidebar.right", label: "Agente") { chrome.toggleAgent() }
        }
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

    @State private var hunkAt: HunkRef?
    @State private var toolbarWidth: CGFloat = 1000

    func kind(_ k: GutterMark.Kind) -> EditorGutterMark.Kind {
        switch k {
        case .added: .added
        case .modified: .modified
        case .deleted: .deleted
        }
    }

    func severity(_ s: LintIssue.Severity) -> EditorIssue.Severity {
        switch s {
        case .error: .error
        case .warning: .warning
        case .info: .info
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
                if let p = ws.agent.pendingPatches.first(where: { $0.path == path }) {
                    PatchBanner(patch: p)
                }
                CodeEditorView(
                    text: Binding(get: { ws.text(for: path) }, set: { ws.setText($0, for: path) }),
                    documentId: "\(ws.project.id):\(path)",
                    language: Language.detect(path: path),
                    palette: theme.palette,
                    prefs: chrome.snapshot.editor,
                    reveal: path == ws.active ? ws.reveal : nil,
                    marks: (ws.gutter[path] ?? []).map { EditorGutterMark(line: $0.line, kind: kind($0.kind)) },
                    issues: ws.issues(for: path).map {
                        EditorIssue(
                            line: $0.line,
                            column: $0.column,
                            length: $0.length,
                            severity: severity($0.severity),
                            message: $0.message
                        )
                    },
                    completion: CompletionSource(files: ws.tree.allFiles().map(\.path), path: path),
                    onSave: { ws.save(path) },
                    onFind: { chrome.snapshot.side = .search; chrome.snapshot.sideOpen = true },
                    onGutterTap: { hunkAt = HunkRef(path: path, line: $0) },
                    onCursor: {
                        if path == ws.active {
                            ws.cursorOffset = $0
                        }
                    }
                )
                .popover(item: $hunkAt) { ref in
                    HunkPopover(ref: ref)
                }
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

/// Faixa no topo do editor quando o agente deixou um patch pendente neste arquivo.
struct PatchBanner: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    let patch: Patch
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(theme.accent)
            Text("Patch do agente: +\(patch.additions) −\(patch.deletions)").font(OdeteFont.ui(12))
                .foregroundStyle(theme.fg)
            Spacer()
            Button("Ver no chat") {
                if !chrome.snapshot.agentVisible {
                    chrome.toggleAgent()
                }
            }.buttonStyle(.plain)
                .font(OdeteFont.ui(12)).foregroundStyle(theme.fgMuted)
            Button("Rejeitar") { ws.agent.reject(patch) }.buttonStyle(.glass).font(OdeteFont.ui(12))
            Button("Aceitar") { ws.agent.accept(patch) }.buttonStyle(.glassProminent).font(OdeteFont.ui(12))
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(theme.accent.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}
