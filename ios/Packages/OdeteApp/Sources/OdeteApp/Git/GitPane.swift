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
                        if git.githubSlug != nil {
                            PullRequestsCard()
                        }
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

/// Seção do painel no formato do app do GitHub: título fora, cartão embaixo.
struct GitCard<Content: View>: View {
    @Environment(\.theme) private var theme
    var title: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title, detail: trailing)
            CardList {
                VStack(alignment: .leading, spacing: 10) { content }
                    .padding(12)
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
    @Environment(\.theme) private var theme
    var git: GitModel {
        ws.git
    }

    var body: some View {
        // Medidas de docs/design/README.md: título fora do cartão, linhas com ícone
        // quadrado, números na mesma linha e chevron no fim.
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Alterações", detail: git.isClean ? nil : "\(git.status.count)") {
                Button("Mandar tudo para o stage", systemImage: "plus.circle") { git.stageAll() }
                    .disabled(git.unstaged.isEmpty || git.busy)
                Button("Tirar tudo do stage", systemImage: "minus.circle") { git.unstageAll() }
                    .disabled(git.staged.isEmpty || git.busy)
                Divider()
                Button("Descartar tudo", systemImage: "arrow.uturn.backward", role: .destructive) {
                    git.discard(git.unstaged.map(\.path))
                }
                .disabled(git.unstaged.isEmpty || git.busy)
            }
            if git.isClean {
                CardList {
                    Text("Nada mudou desde o último commit.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 12)
                }
            } else {
                CardList {
                    ForEach(Array(git.staged.enumerated()), id: \.element.id) { i, e in
                        ChangeRow(entry: e, staged: true, first: i == 0)
                    }
                    ForEach(Array(git.unstaged.enumerated()), id: \.element.id) { i, e in
                        ChangeRow(entry: e, staged: false, first: i == 0 && git.staged.isEmpty)
                    }
                }
            }
        }
    }
}

/// Linha de arquivo alterado no formato do app do GitHub: quadrado colorido do tipo de
/// mudança, pasta pequena em cima do nome, contagem de linhas e chevron.
struct ChangeRow: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    let entry: StatusEntry
    let staged: Bool
    /// A primeira linha do cartão não leva separador em cima.
    var first = false

    var git: GitModel {
        ws.git
    }

    var change: Change {
        (staged ? entry.staged : entry.unstaged) ?? .modified
    }

    var body: some View {
        let stat = git.lineStat(for: entry.path)
        return Button {
            git.setDiff(staged ? .index : .workdir, path: entry.path)
            chrome.snapshot.center = .diff
        } label: {
            HStack(spacing: 10) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    if let dir {
                        Text(dir).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    HStack(spacing: 5) {
                        Text(name).font(.subheadline).foregroundStyle(theme.fg)
                            .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        if staged {
                            Text("no stage").font(.caption2).foregroundStyle(theme.ok)
                        }
                    }
                }
                Spacer(minLength: 8)
                if let stat {
                    HStack(spacing: 6) {
                        Text("+\(stat.added)").foregroundStyle(theme.ok)
                        Text("−\(stat.removed)").foregroundStyle(theme.danger)
                    }
                    .font(.caption).monospacedDigit()
                    .fixedSize()
                    .layoutPriority(1)
                }
                Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(theme.fgSubtle)
            }
            .padding(.horizontal, 12)
            .frame(height: dir == nil ? 40 : 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if !first {
                Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 44)
            }
        }
        .contextMenu {
            Button("Abrir no editor", systemImage: "doc.text") { ws.openFile(entry.path) }
            Button(
                staged ? "Tirar do stage" : "Mandar para o stage",
                systemImage: staged ? "minus.circle" : "plus.circle"
            ) {
                staged ? git.unstage([entry.path]) : git.stage([entry.path])
            }
            Button("Histórico do arquivo", systemImage: "clock.arrow.circlepath") { ws.historyPath = entry.path }
            if !staged {
                Button("Descartar alterações", systemImage: "arrow.uturn.backward", role: .destructive) {
                    git.discard([entry.path])
                }
            }
        }
    }

    var name: String {
        entry.path.split(separator: "/").last.map(String.init) ?? entry.path
    }

    var dir: String? {
        let parts = entry.path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
    }

    var color: Color {
        switch change {
        case .added, .untracked: theme.ok
        case .deleted, .conflicted: theme.danger
        case .renamed: .purple
        default: theme.accent
        }
    }

    var glyph: String {
        switch change {
        case .added, .untracked: "plus"
        case .deleted: "minus"
        case .renamed: "arrow.turn.up.right"
        case .conflicted: "exclamationmark"
        default: "pencil"
        }
    }
}

/// Título de seção fora do cartão, com o menu de reticências na borda direita.
struct SectionTitle<Menu: View>: View {
    @Environment(\.theme) private var theme
    var title: String
    var detail: String?
    @ViewBuilder var menu: Menu

    init(_ title: String, detail: String? = nil, @ViewBuilder menu: () -> Menu = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.menu = menu()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline).foregroundStyle(theme.fg)
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            if !(menu is EmptyView) {
                SwiftUI.Menu {
                    menu
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.fgMuted)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Cartão branco que envolve um grupo de linhas, como os do app do GitHub.
struct CardList<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct CommitCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @State private var suggesting = false
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
                Button {
                    suggesting = true
                    Task {
                        do {
                            let m = try await ws.agent.suggestCommitMessage()
                            if !m.isEmpty {
                                git.commitMessage = m
                            }
                        } catch { git.error = error.localizedDescription }
                        suggesting = false
                    }
                } label: {
                    Group {
                        if suggesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles").font(.system(size: 14))
                        }
                    }
                    .foregroundStyle(git.staged.isEmpty ? theme.fgSubtle : theme.accent)
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .disabled(git.staged.isEmpty || suggesting)
                .help("Gerar mensagem com o agente a partir do diff staged")
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
