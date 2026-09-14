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
        .sheet(item: Binding(
            get: { ws.historyPath.map { PathRef(path: $0) } },
            set: { ws.historyPath = $0?.path }
        )) { r in
            FileHistorySheet(path: r.path)
        }
        .sheet(item: Binding(get: { ws.blamePath.map { PathRef(path: $0) } }, set: { ws.blamePath = $0?.path })) { r in
            BlameSheet(path: r.path)
        }
    }

    /// Sidebar, terminal e agente já têm botão no rail; repetir aqui só enche a barra.
    /// Ficam a paleta, salvar e o menu do arquivo aberto.
    var actions: some View {
        HStack(spacing: 6) {
            Button("Paleta", systemImage: "command") { ws.paletteOpen = true }
            Button("Salvar", systemImage: "square.and.arrow.down") { ws.save() }
                .disabled(ws.activeTab?.isDirty != true)
            Menu {
                if let path = ws.active {
                    Section(path.split(separator: "/").last.map(String.init) ?? path) {
                        Button("Histórico do arquivo", systemImage: "clock.arrow.circlepath") {
                            ws.historyPath = path
                        }
                        Button("Blame", systemImage: "person.text.rectangle") { ws.blamePath = path }
                        Button("Copiar caminho", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
                    }
                    Section {
                        Button("Fechar aba", systemImage: "xmark") { ws.closeTab(path) }
                    }
                }
            } label: {
                Label("Mais", systemImage: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .disabled(ws.active == nil)
        }
        .controlSize(.small)
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .tint(theme.fgMuted)
    }

    @ViewBuilder var content: some View {
        switch chrome.snapshot.center {
        case .code: editor(ws.active)
        case .diff: DiffPane()
        case .dual:
            HStack(spacing: 0) {
                painelDuplo(ws.active, direita: false)
                Rectangle().fill(theme.border).frame(width: 1)
                painelDuplo(direitaPath, direita: true)
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
    /// Lado do modo Dois que está recebendo um arrasto agora.
    @State private var sobre: String?
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

    /// Arquivo do lado direito no modo Dois: o escolhido, ou a primeira aba que não é a
    /// da esquerda enquanto ninguém escolheu.
    var direitaPath: String? {
        if let s = ws.secondary, s != ws.active, ws.tabs.contains(where: { $0.path == s }) {
            return s
        }
        return ws.tabs.first { $0.path != ws.active }?.path
    }

    /// Um lado do modo Dois. Aceita arquivo arrastado da árvore e tem o seletor de
    /// arquivo na própria trilha, para dar para comparar sem depender do arrasto.
    @ViewBuilder func painelDuplo(_ path: String?, direita: Bool) -> some View {
        let lado = direita ? "dir" : "esq"
        Group {
            if path == nil, direita {
                EmptyState(
                    "arrow.down.doc",
                    title: "Nada para comparar",
                    text: "Arraste um arquivo da lista para cá, ou escolha um na trilha do outro lado."
                )
            } else {
                editor(
                    path,
                    escolher: { p in direita ? ws.openSecondary(p) : ws.openFile(p) },
                    trocar: trocarLados
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: String.self) { itens, _ in
            guard let p = itens.first, !p.isEmpty, p != path else { return false }
            if direita {
                ws.openSecondary(p)
            } else {
                ws.openFile(p)
            }
            return true
        } isTargeted: { dentro in
            sobre = dentro ? lado : (sobre == lado ? nil : sobre)
        }
        .overlay {
            if sobre == lado {
                ZStack {
                    theme.accent.opacity(0.1)
                    Label("Soltar aqui", systemImage: "arrow.down.doc")
                        .font(OdeteFont.ui(12, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(theme.bgElevated, in: Capsule())
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.accent, lineWidth: 2)
                        .padding(2)
                }
                .allowsHitTesting(false)
            }
        }
    }

    func trocarLados() {
        let esquerda = ws.active
        let direita = direitaPath
        if let direita {
            ws.openFile(direita)
        }
        if let esquerda {
            ws.openSecondary(esquerda)
        }
    }

    @ViewBuilder func editor(
        _ path: String?,
        escolher: ((String) -> Void)? = nil,
        trocar: (() -> Void)? = nil
    ) -> some View {
        if let path, ws.git.conflicts.contains(path), !ws.forceTextEdit.contains(path),
           ConflictParser.hasMarkers(ws.text(for: path))
        {
            ConflictView(path: path)
        } else if let path {
            VStack(spacing: 0) {
                Crumbs(path: path, escolher: escolher, trocar: trocar)
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
                    changes: ws.patchChanges[path] ?? [],
                    completion: CompletionSource(files: ws.filePaths, path: path),
                    onSave: { ws.save(path) },
                    onFind: { chrome.snapshot.side = .search; chrome.snapshot.sideOpen = true },
                    onGutterLongPress: { hunkAt = HunkRef(path: path, line: $0) },
                    onCursor: {
                        if path == ws.active {
                            ws.cursorOffset = $0
                        }
                    }
                )
                // Folha de ação, não popover: o popover reaparecia sozinho a cada
                // redesenho e engolia o toque seguinte, que era o toque que devia levar
                // o cursor para a linha — daí a sensação de editor travado.
                .confirmationDialog(
                    ws.hunk(at: hunkAt?.line ?? 0, in: hunkAt?.path ?? "")?.1.header ?? "Trecho alterado",
                    isPresented: Binding(get: { hunkAt != nil }, set: {
                        if !$0 {
                            hunkAt = nil
                        }
                    }),
                    titleVisibility: .visible
                ) {
                    if let ref = hunkAt {
                        Button("Descartar este trecho", role: .destructive) {
                            ws.discardHunk(at: ref.line, in: ref.path)
                            hunkAt = nil
                        }
                        Button("Ver diff do arquivo") {
                            ws.git.setDiff(.workdir, path: ref.path)
                            chrome.snapshot.center = .diff
                            hunkAt = nil
                        }
                    }
                    Button("Cancelar", role: .cancel) { hunkAt = nil }
                }
                .onChange(of: ws.agent.pendingPatches) { _, _ in ws.refreshPatchMarks(path) }
                .onAppear { ws.refreshPatchMarks(path) }
            }
        } else {
            EmptyEditor()
        }
    }
}

struct Crumbs: View {
    @Environment(\.theme) private var theme
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    var path: String
    /// Modo Dois: trocar o arquivo deste lado e inverter os lados. Fora dele é nulo e o
    /// seletor nem aparece.
    var escolher: ((String) -> Void)?
    var trocar: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if let escolher {
                Menu {
                    ForEach(ws.tabs) { t in
                        Button {
                            escolher(t.path)
                        } label: {
                            Label(
                                t.path.split(separator: "/").last.map(String.init) ?? t.path,
                                systemImage: t.path == path ? "checkmark" : "doc"
                            )
                        }
                    }
                    if let trocar {
                        Divider()
                        Button("Trocar os lados", systemImage: "arrow.left.arrow.right", action: trocar)
                    }
                } label: {
                    Image(systemName: "chevron.down.circle").font(.system(size: 11))
                        .foregroundStyle(theme.fgMuted)
                        .frame(width: 20, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel("Escolher arquivo deste lado")
            }
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
            if ws.git.isRepo {
                Menu {
                    Button("Histórico do arquivo", systemImage: "clock.arrow.circlepath") { ws.historyPath = path }
                    Button("Blame", systemImage: "person.text.rectangle") { ws.blamePath = path }
                    Button("Diff deste arquivo", systemImage: "plus.forwardslash.minus") {
                        ws.git.setDiff(.headToWorkdir, path: path)
                        chrome.snapshot.center = .diff
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(theme.fgSubtle)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
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
