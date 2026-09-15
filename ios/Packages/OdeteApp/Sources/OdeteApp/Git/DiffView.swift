import OdeteCore
import OdeteGit
import OdeteI18n
import OdeteUI
import SwiftUI

/// Modo Diff do centro: fonte, arquivos e hunks com ações.
struct DiffPane: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var git: GitModel {
        ws.git
    }

    /// Binário não tem linha para contar. Somando zero por ele, um diff só de binários
    /// anunciava "+0 −0" — que se lê como "não mudou nada" bem em cima da mudança.
    var resumo: String {
        let texto = git.diff.files.filter { !$0.isBinary }
        guard !texto.isEmpty else { return git.diff.files.isEmpty ? "" : tr("binário") }
        return "+\(texto.reduce(0) { $0 + $1.additions })  −\(texto.reduce(0) { $0 + $1.deletions })"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    Button(tr("Tudo (HEAD → workdir)")) { git.setDiff(.headToWorkdir) }
                    Button(tr("Não staged (índice → workdir)")) { git.setDiff(.workdir) }
                    Button(tr("Staged (HEAD → índice)")) { git.setDiff(.index) }
                    if let a = git.compareA, let b = git.compareB {
                        Button(tr("Comparar A → B")) { git.setDiff(.commits(
                            a,
                            b
                        )) }
                    }
                } label: {
                    Label(sourceLabel, systemImage: "line.3.horizontal.decrease.circle").font(OdeteFont.ui(12))
                }
                .buttonStyle(.glass)
                if let p = git.diffPath {
                    Text(p).font(OdeteFont.mono(11)).foregroundStyle(theme.fgMuted).lineLimit(1).truncationMode(.middle)
                    Button(tr("todos os arquivos")) { git.setDiff(git.diffSource) }.font(OdeteFont.ui(11))
                }
                Spacer()
                Text(resumo).font(OdeteFont.mono(11)).foregroundStyle(theme.fgMuted)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
            if !git.isRepo {
                ShellPanel(
                    "Diff",
                    symbol: "plus.forwardslash.minus",
                    phase: 2,
                    blurb: tr("Inicie um repositório no painel Git.")
                )
            } else if git.diff.files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 26, weight: .light))
                        .foregroundStyle(theme.fgSubtle)
                    Text(tr("sem diferenças")).font(OdeteFont.ui(13)).foregroundStyle(theme.fgMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollPane {
                    LazyVStack(spacing: 14) {
                        ForEach(git.diff.files) { f in FileDiffView(file: f, source: git.diffSource) }
                    }
                    .padding(12)
                }
            }
        }
        .background(theme.bg)
    }

    var sourceLabel: String {
        switch git.diffSource {
        case .headToWorkdir: "Tudo"
        case .workdir: "Não staged"
        case .index: "Staged"
        case let .commit(s): "commit \(s.prefix(7))"
        case let .commits(a, b): "\(a.prefix(7)) → \(b.prefix(7))"
        }
    }
}

struct FileDiffView: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var file: FileDiff
    var source: Repository.DiffSource
    var git: GitModel {
        ws.git
    }

    var canStage: Bool {
        if case .workdir = source {
            return true
        }; if case .headToWorkdir = source {
            return true
        }; return false
    }

    var canUnstage: Bool {
        if case .index = source {
            return true
        }; return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                FileGlyph(path: file.path, size: 13)
                Text(file.path).font(OdeteFont.mono(12, weight: .medium)).foregroundStyle(theme.fg).lineLimit(1)
                    .truncationMode(.middle)
                if let old = file.oldPath {
                    Text("← \(old)").font(OdeteFont.mono(10)).foregroundStyle(theme.fgSubtle)
                }
                Spacer()
                if !file.isBinary {
                    Text("+\(file.additions)").font(OdeteFont.mono(11)).foregroundStyle(theme.ok)
                    Text("−\(file.deletions)").font(OdeteFont.mono(11)).foregroundStyle(theme.danger)
                }
                HeaderButton("doc.text", label: tr("Abrir")) { ws.openFile(file.path) }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(theme.bgElevated)
            if file.isBinary {
                Text(tr("arquivo binário")).font(OdeteFont.mono(11)).foregroundStyle(theme.fgSubtle).padding(10)
            }
            ForEach(file.hunks) { h in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(h.header).font(OdeteFont.mono(11)).foregroundStyle(theme.accent).lineLimit(1)
                        Spacer()
                        if canStage {
                            Button(tr("Stage hunk")) { git.stageHunk(h, in: file) }.font(OdeteFont.ui(11))
                            Button(tr("Descartar")) { git.discardHunk(h, in: file) }.font(OdeteFont.ui(11))
                                .foregroundStyle(theme.danger)
                        }
                        if canUnstage {
                            Button(tr("Unstage hunk")) { git.unstageHunk(h, in: file) }.font(OdeteFont.ui(11))
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(theme.bgSubtle.opacity(0.6))
                    ForEach(h.lines) { l in
                        HStack(spacing: 0) {
                            Text(l.oldLine.map(String.init) ?? "").font(OdeteFont.mono(11))
                                .foregroundStyle(theme.fgSubtle).frame(
                                    width: 38,
                                    alignment: .trailing
                                )
                            Text(l.newLine.map(String.init) ?? "").font(OdeteFont.mono(11))
                                .foregroundStyle(theme.fgSubtle).frame(
                                    width: 38,
                                    alignment: .trailing
                                )
                            Text(l.kind == .addition ? "+" : l.kind == .deletion ? "−" : " ").font(OdeteFont.mono(12))
                                .frame(width: 18)
                                .foregroundStyle(l.kind == .addition ? theme.ok : l.kind == .deletion ? theme
                                    .danger : theme.fgSubtle)
                            Text(l.text.isEmpty ? " " : l.text).font(OdeteFont.mono(12)).foregroundStyle(theme.fg)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 20)
                        .background(l.kind == .addition ? theme.ok.opacity(0.10) : l.kind == .deletion ? theme.danger
                            .opacity(0.10) : .clear)
                    }
                }
            }
        }
        .background(theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.border))
    }
}
