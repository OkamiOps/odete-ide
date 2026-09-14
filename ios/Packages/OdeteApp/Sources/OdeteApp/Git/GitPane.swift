import OdeteAccounts
import OdeteCore
import OdeteGit
import OdeteUI
import SwiftUI

/// Painel Git em cartões.
struct GitPane: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    @State private var showGh = false

    var git: GitModel {
        ws.git
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Git", detail: git.isRepo ? (git.isClean ? "limpo" : "\(git.status.count) alterações") : nil) {
                if git.githubSlug != nil {
                    HeaderButton("cat", label: "GitHub") { showGh = true }
                }
                HeaderButton("arrow.clockwise", label: "Atualizar") { git.scheduleRefresh() }
            }
            if !git.isRepo {
                initCard
            } else {
                ScrollView {
                    VStack(spacing: Metrics.s2) {
                        HeroCard()
                        if !git.conflicts.isEmpty {
                            ConflictsCard()
                        }
                        ChangesCard()
                        CommitCard()
                        HistoryCard()
                        BranchesCard()
                    }
                    .padding(Metrics.s2)
                }
            }
        }
        .background(theme.surface)
        .sheet(isPresented: $showGh) { GhSheet() }
        .alert("Git", isPresented: Binding(get: { git.error != nil }, set: {
            if !$0 {
                git.error = nil
            }
        })) {
            Button("OK") { git.error = nil }
        } message: { Text(git.error ?? "") }
    }

    var initCard: some View {
        EmptyState(
            "arrow.triangle.branch",
            title: "Sem git ainda",
            text: "Inicie um repositório para ter histórico, branches e push para o GitHub."
        ) {
            Button { git.initRepository() } label: { Label("Iniciar repositório", systemImage: "plus") }
                .buttonStyle(.glassProminent)
        }
    }
}

struct GitCard<Content: View>: View {
    @Environment(\.theme) private var theme
    var title: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        OdeteCard {
            VStack(alignment: .leading, spacing: Metrics.s2) {
                SectionLabel(title, trailing: trailing)
                content
            }
        }
    }
}

struct GitButton: View {
    var title: String
    var symbol: String?
    var accent = false
    var disabled = false
    var action: () -> Void

    var body: some View {
        WideButton(title, symbol: symbol, prominent: accent, action: action)
            .disabled(disabled)
    }
}

struct HeroCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @State private var remoteURL = ""
    @State private var askingRemote = false
    var git: GitModel {
        ws.git
    }

    var body: some View {
        GitCard(title: "Branch", trailing: git.busy ? git.note : nil) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(theme.accent)
                Text(git.current?.name ?? git.headName ?? "—").font(OdeteFont.ui(15, weight: .semibold))
                    .foregroundStyle(theme.fg)
                Spacer()
                if let ab = git.aheadBehind {
                    badge("↑\(ab.ahead)", on: ab.ahead > 0)
                    badge("↓\(ab.behind)", on: ab.behind > 0)
                }
                if git.busy {
                    ProgressView().controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                if let o = git.origin {
                    Text(o.url).font(OdeteFont.mono(10)).foregroundStyle(theme.fgSubtle).lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Button("adicionar remoto…") { askingRemote = true }.font(OdeteFont.ui(11))
                        .foregroundStyle(theme.accent)
                }
                Spacer()
                if git.origin != nil, !git.hasCredentials {
                    Text("sem conta").font(OdeteFont.mono(10)).foregroundStyle(theme.danger)
                }
            }
            if git.origin != nil {
                HStack(spacing: 6) {
                    GitButton(title: "Fetch", symbol: "arrow.down.circle", disabled: git.busy) { git.fetch() }
                    GitButton(title: "Pull", symbol: "arrow.down.to.line", disabled: git.busy) { git.pull() }
                    GitButton(
                        title: "Push",
                        symbol: "arrow.up.to.line",
                        accent: (git.aheadBehind?.ahead ?? 0) > 0 || git.aheadBehind == nil,
                        disabled: git.busy
                    ) { git.push() }
                }
            }
            if !git.busy, !git.note.isEmpty {
                Text(git.note).font(OdeteFont.mono(11)).foregroundStyle(theme.fgMuted)
            }
        }
        .alert("Remoto origin", isPresented: $askingRemote) {
            TextField("https://github.com/usuario/repo.git", text: $remoteURL)
            Button("Adicionar") { git.addRemote(url: remoteURL.trimmingCharacters(in: .whitespaces)) }
            Button("Cancelar", role: .cancel) {}
        }
    }

    func badge(_ s: String, on: Bool) -> some View {
        Pill(s, on: on)
    }
}

struct ChangesCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    var git: GitModel {
        ws.git
    }

    var body: some View {
        GitCard(title: "Alterações", trailing: git.isClean ? "working tree limpa" : nil) {
            if !git.staged.isEmpty {
                group("Staged", git.staged, staged: true)
            }
            if !git.unstaged.isEmpty {
                group("Não staged", git.unstaged, staged: false)
            }
            if !git.isClean {
                HStack(spacing: 6) {
                    GitButton(title: "Stage all", disabled: git.unstaged.isEmpty || git.busy) { git.stageAll() }
                    GitButton(title: "Unstage all", disabled: git.staged.isEmpty || git.busy) { git.unstageAll() }
                }
            }
        }
    }

    func group(_ title: String, _ entries: [StatusEntry], staged: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title.uppercased()).font(OdeteFont.ui(10, weight: .medium)).tracking(0.6)
                    .foregroundStyle(theme.fgSubtle)
                Text("\(entries.count)").font(OdeteFont.mono(10)).foregroundStyle(theme.fgMuted)
            }
            .padding(.vertical, 4)
            ForEach(entries) { e in
                let change = staged ? e.staged! : e.unstaged!
                HStack(spacing: 8) {
                    Text(change.symbol).font(OdeteFont.mono(11, weight: .semibold))
                        .foregroundStyle(color(change))
                        .frame(width: 20, height: 20)
                        .background(color(change).opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                    FileGlyph(path: e.path, size: 12)
                    Text(e.path).font(OdeteFont.ui(12.5)).foregroundStyle(theme.fg).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    HeaderButton(staged ? "minus.circle" : "plus.circle", label: staged ? "Unstage" : "Stage") {
                        staged ? git.unstage([e.path]) : git.stage([e.path])
                    }
                    if !staged {
                        HeaderButton("arrow.uturn.backward.circle", label: "Descartar") { git.discard([e.path]) }
                    }
                }
                .frame(height: Metrics.row)
                .contentShape(Rectangle())
                .onTapGesture {
                    git.setDiff(staged ? .index : .workdir, path: e.path)
                    chrome.snapshot.center = .diff
                }
                .contextMenu {
                    Button("Abrir no editor", systemImage: "doc.text") { ws.openFile(e.path) }
                    Button(staged ? "Unstage" : "Stage", systemImage: staged ? "minus.circle" : "plus.circle") {
                        staged ? git.unstage([e.path]) : git.stage([e.path])
                    }
                    if !staged {
                        Button(
                            "Descartar alterações",
                            systemImage: "arrow.uturn.backward",
                            role: .destructive
                        ) { git.discard([e.path]) }
                    }
                }
            }
        }
    }

    func color(_ c: Change) -> Color {
        switch c {
        case .added, .untracked: theme.ok
        case .deleted: theme.danger
        case .conflicted: theme.danger
        default: theme.accent
        }
    }
}

struct CommitCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var git: GitModel {
        ws.git
    }

    var body: some View {
        @Bindable var git = git
        GitCard(title: git.mergeInProgress ? "Concluir merge" : "Commit", trailing: git.author.name) {
            ZStack(alignment: .topTrailing) {
                TextField("Mensagem do commit", text: $git.commitMessage, axis: .vertical)
                    .lineLimit(2 ... 6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(OdeteFont.ui(14))
                    .padding(10)
                    .padding(.trailing, 36)
                    .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.border))
                Button {} label: {
                    Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(theme.fgMuted)
                        .frame(width: 32, height: 32).background(theme.bgSubtle, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(true)
                .opacity(0.4)
                .help("Gerar mensagem com o agente (Fase 4)")
                .padding(4)
            }
            HStack(spacing: 6) {
                GitButton(
                    title: git.mergeInProgress ? "Commit de merge" : "Commit",
                    symbol: "checkmark",
                    accent: true,
                    disabled: git.busy || (git.staged.isEmpty && !git.mergeInProgress) || !git.conflicts.isEmpty
                ) {
                    git.commit()
                }
                if git.mergeInProgress {
                    GitButton(title: "Abortar", symbol: "xmark", disabled: git.busy) { git.abortMerge() }
                } else {
                    GitButton(
                        title: "Undo último",
                        symbol: "arrow.uturn.backward",
                        disabled: git.busy || git.log.isEmpty
                    ) { git.undoLastCommit() }
                }
            }
            if git.staged.isEmpty, !git.mergeInProgress {
                Text("faça stage de algo para commitar").font(OdeteFont.mono(11)).foregroundStyle(theme.fgSubtle)
            }
        }
    }
}

struct HistoryCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    @State private var expanded = false
    var git: GitModel {
        ws.git
    }

    var body: some View {
        GitCard(title: "Histórico", trailing: "\(git.log.count) commits") {
            if git.log.isEmpty {
                Text("nenhum commit ainda").font(OdeteFont.mono(11)).foregroundStyle(theme.fgSubtle)
            }
            ForEach(git.log.prefix(expanded ? 200 : 8)) { c in
                Button {
                    git.setDiff(.commit(c.id))
                    chrome.snapshot.center = .diff
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(c.short).font(OdeteFont.mono(11)).foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.summary).font(OdeteFont.ui(12.5)).foregroundStyle(theme.fg).lineLimit(2)
                            Text("\(c.author.name) · \(c.date.formatted(.relative(presentation: .named)))")
                                .font(OdeteFont.ui(10.5)).foregroundStyle(theme.fgSubtle)
                        }
                        Spacer(minLength: 0)
                        if c.parents
                            .count >
                            1
                        {
                            Image(systemName: "arrow.triangle.merge").font(.system(size: 11))
                                .foregroundStyle(theme.fgSubtle)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Comparar como A", systemImage: "a.circle") { git.compareA = c.id; compare() }
                    Button("Comparar como B", systemImage: "b.circle") { git.compareB = c.id; compare() }
                    Button("Copiar SHA", systemImage: "doc.on.doc") { UIPasteboard.general.string = c.id }
                }
            }
            if git.log.count > 8 {
                Button(expanded ? "mostrar menos" : "mostrar todos") { expanded.toggle() }.font(OdeteFont.ui(11))
                    .foregroundStyle(theme.accent)
            }
            if git.compareA != nil || git.compareB != nil {
                HStack(spacing: 6) {
                    Text(
                        "A \(git.compareA.map { String($0.prefix(7)) } ?? "—")  ·  B \(git.compareB.map { String($0.prefix(7)) } ?? "—")"
                    )
                    .font(OdeteFont.mono(11)).foregroundStyle(theme.fgMuted)
                    Spacer()
                    Button("limpar") { git.compareA = nil; git.compareB = nil }.font(OdeteFont.ui(11))
                }
            }
        }
    }

    func compare() {
        if let a = git.compareA, let b = git.compareB {
            git.setDiff(.commits(a, b))
            chrome.snapshot.center = .diff
        }
    }
}

struct BranchesCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @State private var open = false
    @State private var newBranch = ""
    @State private var askingBranch = false
    @State private var stashMsg = ""
    @State private var askingStash = false
    var git: GitModel {
        ws.git
    }

    var body: some View {
        GitCard(
            title: "Branches e stash",
            trailing: "\(git.branches.filter { !$0.isRemote }.count) · \(git.stashes.count)"
        ) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack {
                    Text(open ? "recolher" : "expandir").font(OdeteFont.ui(11)).foregroundStyle(theme.accent); Spacer()
                }
            }
            .buttonStyle(.plain)
            if open {
                HStack(spacing: 6) {
                    GitButton(title: "Nova branch", symbol: "plus", disabled: git.busy) {
                        newBranch = ""; askingBranch = true
                    }
                    GitButton(
                        title: "Guardar stash",
                        symbol: "tray.and.arrow.down",
                        disabled: git.busy || git.isClean
                    ) {
                        stashMsg = ""; askingStash = true
                    }
                }
                ForEach(git.branches) { b in
                    HStack(spacing: 8) {
                        Image(systemName: b.isRemote ? "cloud" : "arrow.triangle.branch").font(.system(size: 11))
                            .foregroundStyle(theme.fgSubtle).frame(width: 14)
                        Text(b.name).font(OdeteFont.mono(12, weight: b.isHead ? .medium : .regular))
                            .foregroundStyle(b.isHead ? theme.accent : theme.fg).lineLimit(1)
                        Spacer()
                        if !b.isHead {
                            HeaderButton("arrow.right.circle", label: "Trocar para \(b.name)") { git.checkout(b.name) }
                            HeaderButton("arrow.triangle.merge", label: "Merge \(b.name)") { git.merge(b.name) }
                            if !b
                                .isRemote
                            {
                                HeaderButton("trash", label: "Apagar \(b.name)") { git.deleteBranch(b.name) }
                            }
                        }
                    }
                    .frame(height: 36)
                }
                if !git.stashes.isEmpty {
                    Text("STASH").font(OdeteFont.ui(10, weight: .medium)).tracking(0.6).foregroundStyle(theme.fgSubtle)
                        .padding(
                            .top,
                            4
                        )
                    ForEach(git.stashes) { s in
                        HStack(spacing: 8) {
                            Text("@\(s.index)").font(OdeteFont.mono(11)).foregroundStyle(theme.fgSubtle)
                            Text(s.message).font(OdeteFont.ui(12)).foregroundStyle(theme.fg).lineLimit(1)
                            Spacer()
                            HeaderButton("tray.and.arrow.up", label: "Aplicar") { git.stashPop(s.index) }
                            HeaderButton("trash", label: "Apagar") { git.stashDrop(s.index) }
                        }
                        .frame(height: 36)
                    }
                }
            }
        }
        .alert("Nova branch", isPresented: $askingBranch) {
            TextField("nome", text: $newBranch)
            Button("Criar e trocar") { git.createBranch(newBranch.trimmingCharacters(in: .whitespaces)) }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Guardar stash", isPresented: $askingStash) {
            TextField("mensagem", text: $stashMsg)
            Button("Guardar") { git.stashPush(stashMsg) }
            Button("Cancelar", role: .cancel) {}
        }
    }
}

struct ConflictsCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var git: GitModel {
        ws.git
    }

    var body: some View {
        GitCard(title: "Conflitos", trailing: "\(git.conflicts.count)") {
            Text("Resolva cada arquivo no editor e faça o commit de merge.").font(OdeteFont.ui(12))
                .foregroundStyle(theme.fgMuted)
            ForEach(git.conflicts, id: \.self) { p in
                Button { ws.openFile(p) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.danger)
                        Text(p).font(OdeteFont.mono(12)).foregroundStyle(theme.fg).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(theme.fgSubtle)
                    }
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            GitButton(title: "Abortar merge", symbol: "xmark", disabled: git.busy) { git.abortMerge() }
        }
    }
}
