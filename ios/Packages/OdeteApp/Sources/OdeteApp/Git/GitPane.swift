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
                    VStack(spacing: 14) {
                        HeroCard()
                        if !git.conflicts.isEmpty {
                            ConflictsCard()
                        }
                        ChangesCard()
                        if git.githubSlug != nil {
                            PullRequestsCard()
                        }
                        HistoryCard()
                        BranchesCard()
                    }
                    .padding(12)
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

/// Cabeçalho do painel: o branch é o próprio título, e o commit fica logo abaixo dele,
/// porque é a ação que se faz a partir dali.
struct HeroCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @State private var remoteURL = ""
    @State private var askingRemote = false
    var git: GitModel {
        ws.git
    }

    var body: some View {
        CardList {
            VStack(alignment: .leading, spacing: 10) {
                branchRow
                if git.origin != nil {
                    HStack(spacing: 6) {
                        GitButton(title: "Fetch", symbol: "arrow.down.circle", disabled: git.busy) { git.fetch() }
                        GitButton(title: "Pull", symbol: "arrow.down.to.line", disabled: git.busy) { git.pull() }
                        GitButton(
                            title: "Push",
                            symbol: "arrow.up.to.line",
                            accent: (git.aheadBehind?.ahead ?? 0) > 0,
                            disabled: git.busy
                        ) { git.push() }
                    }
                }
            }
            .padding(12)
            Rectangle().fill(theme.separator).frame(height: 0.5)
            CommitBox()
        }
        .alert("Remoto origin", isPresented: $askingRemote) {
            TextField("https://github.com/usuario/repo.git", text: $remoteURL)
            Button("Adicionar") { git.addRemote(url: remoteURL.trimmingCharacters(in: .whitespaces)) }
            Button("Cancelar", role: .cancel) {}
        }
    }

    var branchRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(git.current?.name ?? git.headName ?? "—").font(.headline).foregroundStyle(theme.fg)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if git.busy {
                    ProgressView().controlSize(.small)
                } else if let ab = git.aheadBehind, ab.ahead > 0 || ab.behind > 0 {
                    Text("↑\(ab.ahead) ↓\(ab.behind)").font(.caption).monospacedDigit()
                        .foregroundStyle(theme.fgMuted)
                }
            }
            HStack(spacing: 6) {
                if let o = git.origin {
                    Text(o.url.replacingOccurrences(of: "https://", with: ""))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if !git.hasCredentials {
                        Text("sem conta").font(.caption2).foregroundStyle(theme.danger)
                    }
                } else {
                    Button("adicionar remoto…") { askingRemote = true }
                        .font(.caption).foregroundStyle(theme.accent)
                }
                Spacer(minLength: 0)
            }
            if !git.busy, !git.note.isEmpty {
                Text(git.note).font(.caption2).foregroundStyle(theme.fgSubtle).lineLimit(1)
            }
        }
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
            SectionTitle(
                "Alterações",
                detail: git.isClean ? nil : "\(git.status.count)",
                stat: git.isClean ? nil : git.lineStat
            ) {
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
    /// Total de linhas que entraram e saíram, mostrado à direita do título.
    var stat: (added: Int, removed: Int)?
    @ViewBuilder var menu: Menu

    init(
        _ title: String,
        detail: String? = nil,
        stat: (added: Int, removed: Int)? = nil,
        @ViewBuilder menu: () -> Menu = { EmptyView() }
    ) {
        self.title = title
        self.detail = detail
        self.stat = stat
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
            if let stat {
                HStack(spacing: 6) {
                    Text("+\(stat.added)").foregroundStyle(theme.ok)
                    Text("−\(stat.removed)").foregroundStyle(theme.danger)
                }
                .font(.caption.weight(.medium)).monospacedDigit()
                .contentTransition(.numericText())
            }
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

/// Caixa de commit, agora dentro do cartão do branch.
struct CommitBox: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @State private var suggesting = false
    @State private var asking = false
    @FocusState private var writing: Bool

    var git: GitModel {
        ws.git
    }

    /// Basta ter mensagem escrita e alguma alteração; se nada estiver no stage,
    /// perguntamos na hora do commit em vez de deixar o botão apagado.
    var canCommit: Bool {
        !git.busy && git.conflicts.isEmpty
            && !git.commitMessage.trimmingCharacters(in: .whitespaces).isEmpty
            && (!git.status.isEmpty || git.mergeInProgress)
    }

    var nothingStaged: Bool {
        git.staged.isEmpty && !git.mergeInProgress && !git.unstaged.isEmpty
    }

    var body: some View {
        @Bindable var git = git
        return VStack(alignment: .leading, spacing: 10) {
            // Cresce com o texto até doze linhas e depois rola por dentro, em vez de
            // ficar preso numa linha só.
            ZStack(alignment: .topTrailing) {
                TextField(
                    git.mergeInProgress ? "Mensagem do merge" : "Mensagem do commit",
                    text: $git.commitMessage,
                    axis: .vertical
                )
                .lineLimit(3 ... 12)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .font(.subheadline)
                .textFieldStyle(.plain)
                .focused($writing)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .padding(.trailing, 26)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(theme.fg.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button { suggest() } label: {
                    Group {
                        if suggesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .foregroundStyle(git.staged.isEmpty ? theme.fgSubtle : theme.accent)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(git.staged.isEmpty || suggesting)
                .accessibilityLabel("Sugerir mensagem a partir do que está no stage")
                .padding(4)
            }
            HStack(spacing: 6) {
                GitButton(
                    title: git.mergeInProgress ? "Commit de merge" : "Commit",
                    symbol: "checkmark",
                    accent: true,
                    disabled: !canCommit
                ) {
                    writing = false
                    if nothingStaged {
                        asking = true
                    } else {
                        git.commit()
                    }
                }
                if git.mergeInProgress {
                    GitButton(title: "Abortar", symbol: "xmark", disabled: git.busy) { git.abortMerge() }
                } else {
                    GitButton(
                        title: "Desfazer",
                        symbol: "arrow.uturn.backward",
                        disabled: git.busy || git.log.isEmpty
                    ) { git.undoLastCommit() }
                }
            }
            if !git.conflicts.isEmpty {
                Text("resolva os conflitos antes de commitar")
                    .font(.caption2).foregroundStyle(theme.danger)
            }
        }
        .padding(12)
        .confirmationDialog(
            "Nada está no stage",
            isPresented: $asking,
            titleVisibility: .visible
        ) {
            Button("Commitar as \(git.unstaged.count) alterações") { git.commit(stagingEverything: true) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Quer mandar tudo para o stage e commitar?")
        }
    }

    func suggest() {
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
    }
}

/// Histórico: uma linha por commit, com o fio do tempo à esquerda, como no app do GitHub.
struct HistoryCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    @State private var expanded = false
    var git: GitModel {
        ws.git
    }

    var shown: [Commit] {
        Array(git.log.prefix(expanded ? 200 : 5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Histórico", detail: git.log.isEmpty ? nil : "\(git.log.count)") {
                if git.compareA != nil || git.compareB != nil {
                    Button("Limpar comparação", systemImage: "xmark") { git.compareA = nil; git.compareB = nil }
                }
                if git.log.count > 5 {
                    Button(
                        expanded ? "Mostrar menos" : "Mostrar todos",
                        systemImage: expanded ? "chevron.up" : "chevron.down"
                    ) {
                        withAnimation(.snappy) { expanded.toggle() }
                    }
                }
            }
            CardList {
                if git.log.isEmpty {
                    Text("Nenhum commit ainda.").font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 12)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, c in
                    row(c, first: i == 0, last: i == shown.count - 1)
                }
                if git.compareA != nil || git.compareB != nil {
                    compareRow
                }
            }
        }
    }

    func row(_ c: Commit, first: Bool, last: Bool) -> some View {
        Button {
            git.setDiff(.commit(c.id))
            chrome.snapshot.center = .diff
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Fio do tempo: bolinha no commit e linha ligando ao próximo.
                VStack(spacing: 0) {
                    Rectangle().fill(first ? .clear : theme.separator).frame(width: 1, height: 6)
                    Circle()
                        .fill(c.parents.count > 1 ? theme.accent : theme.fgSubtle)
                        .frame(width: 7, height: 7)
                    Rectangle().fill(last ? .clear : theme.separator).frame(width: 1)
                }
                .frame(width: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.summary).font(.subheadline).foregroundStyle(theme.fg).lineLimit(2)
                    HStack(spacing: 5) {
                        Text(c.short).font(.caption2).monospaced().foregroundStyle(theme.accent)
                        Text(c.author.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Text("·").font(.caption2).foregroundStyle(.secondary)
                        Text(c.date.formatted(.relative(presentation: .named).locale(Locale(identifier: "pt_BR"))))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(theme.fgSubtle)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Comparar como A", systemImage: "a.circle") { git.compareA = c.id; compare() }
            Button("Comparar como B", systemImage: "b.circle") { git.compareB = c.id; compare() }
            Button("Copiar SHA", systemImage: "doc.on.doc") { UIPasteboard.general.string = c.id }
        }
    }

    var compareRow: some View {
        HStack(spacing: 6) {
            Text("A \(git.compareA.map { String($0.prefix(7)) } ?? "—")")
            Text("B \(git.compareB.map { String($0.prefix(7)) } ?? "—")")
            Spacer(minLength: 0)
            Button("limpar") { git.compareA = nil; git.compareB = nil }
        }
        .font(.caption2).monospaced().foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 0.5) }
    }

    func compare() {
        if let a = git.compareA, let b = git.compareB {
            git.setDiff(.commits(a, b))
            chrome.snapshot.center = .diff
        }
    }
}

/// Branches e stash: uma linha por item, com o atual marcado e as ações no toque longo.
struct BranchesCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @State private var newBranch = ""
    @State private var askingBranch = false
    @State private var stashMsg = ""
    @State private var askingStash = false
    var git: GitModel {
        ws.git
    }

    var locals: [Branch] {
        git.branches.filter { !$0.isRemote }
    }

    var remotes: [Branch] {
        git.branches.filter(\.isRemote)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Branches", detail: "\(locals.count)") {
                Button("Nova branch…", systemImage: "plus") { newBranch = ""; askingBranch = true }
                    .disabled(git.busy)
                Button("Guardar stash…", systemImage: "tray.and.arrow.down") { stashMsg = ""; askingStash = true }
                    .disabled(git.busy || git.isClean)
            }
            CardList {
                ForEach(Array(locals.enumerated()), id: \.element.id) { i, b in
                    branchRow(b, first: i == 0)
                }
                if !remotes.isEmpty {
                    DisclosureGroup {
                        ForEach(remotes) { b in branchRow(b, first: true) }
                    } label: {
                        Text("Remotas").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 0.5) }
                }
            }
            if !git.stashes.isEmpty {
                SectionTitle("Stash", detail: "\(git.stashes.count)")
                CardList {
                    ForEach(Array(git.stashes.enumerated()), id: \.element.id) { i, st in
                        stashRow(st, first: i == 0)
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

    func branchRow(_ b: Branch, first: Bool) -> some View {
        Button {
            if !b.isHead {
                git.checkout(b.name)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: b.isRemote ? "cloud" : "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(b.isHead ? .white : theme.fgMuted)
                    .frame(width: 22, height: 22)
                    .background(
                        b.isHead ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.fg.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                Text(b.name).font(.subheadline).foregroundStyle(theme.fg).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if b.isHead {
                    Text("atual").font(.caption2).foregroundStyle(theme.accent)
                } else {
                    Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(theme.fgSubtle)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if !first {
                Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 44)
            }
        }
        .contextMenu {
            if !b.isHead {
                Button("Trocar para \(b.name)", systemImage: "arrow.right.circle") { git.checkout(b.name) }
                Button("Merge de \(b.name)", systemImage: "arrow.triangle.merge") { git.merge(b.name) }
                if !b.isRemote {
                    Button("Apagar \(b.name)", systemImage: "trash", role: .destructive) {
                        git.deleteBranch(b.name)
                    }
                }
            }
        }
    }

    func stashRow(_ st: StashEntry, first: Bool) -> some View {
        Button { git.stashPop(st.index) } label: {
            HStack(spacing: 10) {
                Image(systemName: "tray.full").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.fgMuted)
                    .frame(width: 22, height: 22)
                    .background(theme.fg.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(st.message.isEmpty ? "stash @\(st.index)" : st.message)
                    .font(.subheadline).foregroundStyle(theme.fg).lineLimit(1)
                Spacer(minLength: 4)
                Text("aplicar").font(.caption2).foregroundStyle(theme.accent)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if !first {
                Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 44)
            }
        }
        .contextMenu {
            Button("Aplicar", systemImage: "tray.and.arrow.up") { git.stashPop(st.index) }
            Button("Apagar", systemImage: "trash", role: .destructive) { git.stashDrop(st.index) }
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
