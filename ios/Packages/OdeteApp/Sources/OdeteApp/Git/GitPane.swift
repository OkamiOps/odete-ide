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
    @State private var largura: CGFloat = 320

    var git: GitModel {
        ws.git
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Git", detail: git.isRepo ? resumo : nil) {
                if git.githubSlug != nil {
                    HeaderButton("cat", label: "GitHub") { showGh = true }
                }
                HeaderButton("arrow.clockwise", label: "Atualizar") { git.scheduleRefresh() }
            }
            if !git.isRepo {
                ScrollPane { GitEmpty(largura: largura) }
            } else {
                ScrollPane {
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
        // Um painel de 200 pt e um de 500 não podem desenhar a mesma coisa. Os cartões
        // leem esta largura para decidir entre rótulo e só ícone.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { largura = $0 }
        .environment(\.paneWidth, largura)
        .sheet(isPresented: $showGh) { GhSheet() }
        .alert("Git", isPresented: Binding(get: { git.error != nil }, set: {
            if !$0 {
                git.error = nil
            }
        })) {
            Button("OK") { git.error = nil }
        } message: { Text(git.error ?? "") }
    }

    /// Numa coluna de 200 pt "4 alterações" virava "4 alt...ções".
    var resumo: String {
        if git.isClean {
            return "limpo"
        }
        return largura < 250 ? "\(git.status.count)" : "\(git.status.count) alterações"
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

/// Botão de ação do painel. Em coluna estreita vira só o ícone, em vez de espremer
/// "Fetch" até virar "F...".
struct GitButton: View {
    @Environment(\.paneWidth) private var paneWidth
    var title: String
    var symbol: String?
    var accent = false
    var disabled = false
    /// Ações principais nunca viram só ícone: a pessoa precisa ler o que vai acontecer.
    var keepsLabel = false
    var action: () -> Void

    var body: some View {
        Group {
            if let symbol, paneWidth < 260, !keepsLabel {
                icone(symbol)
            } else {
                WideButton(title, symbol: symbol, prominent: accent, action: action)
            }
        }
        .disabled(disabled)
    }

    @ViewBuilder
    func icone(_ symbol: String) -> some View {
        let rotulo = Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            .frame(maxWidth: .infinity).frame(height: 18)
        Group {
            if accent {
                Button(action: action) { rotulo }.buttonStyle(.glassProminent)
            } else {
                Button(action: action) { rotulo }.buttonStyle(.glass)
            }
        }
        .controlSize(.small)
        .accessibilityLabel(title)
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
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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
                    // "Https:/…este.git" não diz nada. O slug do GitHub, quando existe,
                    // cabe inteiro e é o que a pessoa reconhece.
                    Text(git.githubSlug ?? o.url.replacingOccurrences(of: "https://", with: ""))
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

/// Caixa de commit, agora dentro do cartão do branch.
struct CommitBox: View {
    @Environment(\.paneWidth) private var paneWidth
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
                    title: git.mergeInProgress ? (paneWidth < 300 ? "Merge" : "Commit de merge")
                        : git.origin == nil || paneWidth < 300 ? "Commit" : "Commit e push",
                    symbol: "checkmark",
                    accent: true,
                    disabled: !canCommit,
                    keepsLabel: true
                ) {
                    writing = false
                    if nothingStaged {
                        asking = true
                    } else {
                        git.commit()
                    }
                }
                // A ação principal leva a largura; desfazer fica como ícone ao lado, para o
                // rótulo "Commit e push" nunca precisar truncar.
                if git.mergeInProgress {
                    Button("Abortar merge", systemImage: "xmark") { git.abortMerge() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(git.busy)
                } else {
                    Button("Desfazer último commit", systemImage: "arrow.uturn.backward") {
                        git.undoLastCommit()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(git.busy || git.log.isEmpty)
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
            Button(
                git.unstaged.count == 1 ? "Commitar 1 alteração"
                    : "Commitar \(git.unstaged.count) alterações"
            ) { git.commit(stagingEverything: true) }
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
