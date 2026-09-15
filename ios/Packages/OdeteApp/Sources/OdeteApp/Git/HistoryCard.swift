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
                        expanded ? "Mostrar menos" : "Mostrar todos",
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
                    Button(tr("Apagar %1$@", "\(b.name)"), systemImage: "trash", role: .destructive) {
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

struct ConflictsCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var git: GitModel {
        ws.git
    }

    var body: some View {
        GitCard(title: tr("Conflitos"), trailing: "\(git.conflicts.count)") {
            Text(tr("Resolva cada arquivo no editor e faça o commit de merge.")).font(OdeteFont.ui(12))
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
            GitButton(title: tr("Abortar merge"), symbol: "xmark", disabled: git.busy) { git.abortMerge() }
        }
    }
}
