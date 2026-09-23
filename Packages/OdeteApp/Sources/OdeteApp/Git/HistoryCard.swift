import OdeteAccounts
import OdeteCore
import OdeteGit
import OdeteI18n
import OdeteUI
import SwiftUI

// Histórico, branches, stash e conflitos do painel Git.

/// Histórico: uma linha por commit, com o fio do tempo à esquerda, como no app do GitHub.
struct HistoryCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    @Environment(\.paneWidth) private var paneWidth
    @State private var expanded = false
    var git: GitModel {
        ws.git
    }

    var shown: [Commit] {
        Array(git.log.prefix(expanded ? 200 : 5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(tr("Histórico"), detail: git.log.isEmpty ? nil : "\(git.log.count)") {
                if git.compareA != nil || git.compareB != nil {
                    Button(tr("Limpar comparação"), systemImage: "xmark") { git.compareA = nil; git.compareB = nil }
                }
                if git.log.count > 5 {
                    Button(
                        expanded ? tr("Mostrar menos") : tr("Mostrar todos"),
                        systemImage: expanded ? "chevron.up" : "chevron.down"
                    ) {
                        withAnimation(.snappy) { expanded.toggle() }
                    }
                }
            }
            CardList {
                if git.log.isEmpty {
                    Text(tr("Nenhum commit ainda.")).font(.subheadline).foregroundStyle(.secondary)
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
                        Text(c.short).font(.caption2).monospaced().foregroundStyle(theme.accent).fixedSize()
                        if paneWidth >= 260 {
                            Text(c.author.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Text("·").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(c.date.noIdioma(Date.RelativeFormatStyle(
                            presentation: .named,
                            unitsStyle: paneWidth < 260 ? .narrow : .wide
                        )))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
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
            Button(tr("Comparar como A"), systemImage: "a.circle") { git.compareA = c.id; compare() }
            Button(tr("Comparar como B"), systemImage: "b.circle") { git.compareB = c.id; compare() }
            Button(tr("Copiar SHA"), systemImage: "doc.on.doc") { UIPasteboard.general.string = c.id }
        }
    }

    var compareRow: some View {
        HStack(spacing: 6) {
            Text("A \(git.compareA.map { String($0.prefix(7)) } ?? "—")")
            Text("B \(git.compareB.map { String($0.prefix(7)) } ?? "—")")
            Spacer(minLength: 0)
            Button(tr("limpar")) { git.compareA = nil; git.compareB = nil }
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
    /// A branch que espera confirmação para ser apagada, e quantos commits só ela tem.
    @State private var apagando: String?
    @State private var soDela = 0
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
            SectionTitle(tr("Branches"), detail: "\(locals.count)") {
                Button(tr("Nova branch…"), systemImage: "plus") { newBranch = ""; askingBranch = true }
                    .disabled(git.busy)
                Button(tr("Guardar stash…"), systemImage: "tray.and.arrow.down") { stashMsg = ""; askingStash = true }
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
                        Text(tr("Remotas")).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 0.5) }
                }
            }
            if !git.stashes.isEmpty {
                SectionTitle(tr("Stash"), detail: "\(git.stashes.count)")
                CardList {
                    ForEach(Array(git.stashes.enumerated()), id: \.element.id) { i, st in
                        stashRow(st, first: i == 0)
                    }
                }
            }
        }
        .alert(tr("Nova branch"), isPresented: $askingBranch) {
            TextField(tr("nome"), text: $newBranch)
            Button(tr("Criar e trocar")) { git.createBranch(newBranch.trimmingCharacters(in: .whitespaces)) }
            Button(tr("Cancelar"), role: .cancel) {}
        }
        .alert(tr("Guardar stash"), isPresented: $askingStash) {
            TextField(tr("mensagem"), text: $stashMsg)
            Button(tr("Guardar")) { git.stashPush(stashMsg) }
            Button(tr("Cancelar"), role: .cancel) {}
        }
        .confirmationDialog(
            tr("Apagar a branch %1$@?", apagando ?? ""),
            isPresented: Binding(get: { apagando != nil }, set: {
                if !$0 {
                    apagando = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button(tr("Apagar branch"), role: .destructive) {
                if let n = apagando {
                    git.deleteBranch(n)
                }
                apagando = nil
            }
            Button(tr("Cancelar"), role: .cancel) { apagando = nil }
        } message: {
            Text(
                soDela > 0
                    ? tr(
                        "%1$@ commit(s) dessa branch não estão na branch atual nem no remoto: eles somem com ela.",
                        "\(soDela)"
                    )
                    : tr("Tudo o que ela tem já está na branch atual ou no remoto.")
            )
        }
    }

    /// Conta antes de perguntar quantos commits só a branch tem: é o que a pessoa perde.
    func pedirApagar(_ nome: String) {
        Task {
            soDela = await git.commitsOnlyIn(branch: nome)
            apagando = nome
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
                    Text(tr("atual")).font(.caption2).foregroundStyle(theme.accent)
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
                Button(tr("Trocar para %1$@", "\(b.name)"), systemImage: "arrow.right.circle") { git.checkout(b.name) }
                Button(tr("Merge de %1$@", "\(b.name)"), systemImage: "arrow.triangle.merge") { git.merge(b.name) }
                if !b.isRemote {
                    // Apagava na hora, sem perguntar, e o commit que só ela tinha ia junto.
                    Button(tr("Apagar %1$@", "\(b.name)"), systemImage: "trash", role: .destructive) {
                        pedirApagar(b.name)
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
                Text(tr("aplicar")).font(.caption2).foregroundStyle(theme.accent)
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
            Button(tr("Aplicar"), systemImage: "tray.and.arrow.up") { git.stashPop(st.index) }
            Button(tr("Apagar"), systemImage: "trash", role: .destructive) { git.stashDrop(st.index) }
        }
    }
}

/// O texto da confirmação de abortar o merge, igual nos dois botões que abortam.
enum MergeAbortText {
    @MainActor static func message(_ git: GitModel) -> String {
        let n = git.staged.count + git.conflicts.count
        return tr(
            "Os %1$@ arquivos do merge voltam ao que eram antes dele, e o que você já resolveu nos conflitos se perde. Arquivos fora do merge ficam como estão.",
            "\(n)"
        )
    }
}

struct ConflictsCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @State private var abortando = false
    @State private var apagando: String?
    var git: GitModel {
        ws.git
    }

    var body: some View {
        GitCard(title: tr("Conflitos"), trailing: "\(git.conflicts.count)") {
            Text(tr("Resolva cada arquivo no editor e faça o commit de merge.")).font(OdeteFont.ui(12))
                .foregroundStyle(theme.fgMuted)
            ForEach(git.conflicts, id: \.self) { p in
                linha(p, info: git.conflictInfos[p])
            }
            GitButton(title: tr("Abortar merge"), symbol: "xmark", disabled: git.busy) { abortando = true }
        }
        .confirmationDialog(tr("Abortar o merge?"), isPresented: $abortando, titleVisibility: .visible) {
            Button(tr("Abortar merge"), role: .destructive) { git.abortMerge() }
            Button(tr("Cancelar"), role: .cancel) {}
        } message: {
            Text(MergeAbortText.message(git))
        }
        .confirmationDialog(
            tr("Apagar %1$@?", apagando ?? ""),
            isPresented: Binding(get: { apagando != nil }, set: {
                if !$0 {
                    apagando = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button(tr("Apagar o arquivo"), role: .destructive) {
                if let p = apagando {
                    git.resolveByDeleting(path: p)
                }
                apagando = nil
            }
            Button(tr("Cancelar"), role: .cancel) { apagando = nil }
        } message: {
            Text(tr("O arquivo sai dos dois lados e o conflito fica resolvido assim."))
        }
    }

    /// Uma linha por conflito. O conflito sem marcadores (binário, apagado de um lado)
    /// não tem bloco para escolher no editor: as escolhas ficam aqui, na própria linha.
    /// Antes o "Marcar resolvido" do editor ficava apagado, o arquivo não aparecia para
    /// stage, e o merge não tinha como terminar.
    func linha(_ p: String, info: ConflictInfo?) -> some View {
        HStack(spacing: 8) {
            Button { ws.openFile(p) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.danger)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p).font(OdeteFont.mono(12)).foregroundStyle(theme.fg).lineLimit(1)
                        if let d = descricao(info) {
                            Text(d).font(.caption2).foregroundStyle(theme.fgSubtle).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                Button(
                    info?.ours == false ? tr("Usar a minha (apaga o arquivo)") : tr("Usar a minha versão"),
                    systemImage: "person"
                ) { git.resolve(path: p, using: .ours) }
                Button(
                    info?.theirs == false ? tr("Usar a deles (apaga o arquivo)") : tr("Usar a versão deles"),
                    systemImage: "person.2"
                ) { git.resolve(path: p, using: .theirs) }
                Button(tr("Apagar o arquivo"), systemImage: "trash", role: .destructive) { apagando = p }
                Divider()
                Button(tr("Marcar resolvido como está"), systemImage: "checkmark") { git.markResolved(path: p) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
                    .foregroundStyle(theme.accent)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .disabled(git.busy)
            .accessibilityLabel(tr("Resolver %1$@", p))
        }
    }

    /// Por que o conflito não se resolve bloco a bloco, quando é o caso.
    func descricao(_ info: ConflictInfo?) -> String? {
        guard let info, !info.hasMarkers else { return nil }
        if !info.ours {
            return tr("apagado na sua branch, alterado na outra")
        }
        if !info.theirs {
            return tr("alterado na sua branch, apagado na outra")
        }
        return tr("binário: escolha uma das versões")
    }
}
