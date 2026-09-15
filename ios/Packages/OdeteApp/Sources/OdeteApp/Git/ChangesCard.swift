import OdeteAccounts
import OdeteCore
import OdeteGit
import OdeteUI
import SwiftUI

// Cartão de alterações do painel Git: a lista de arquivos mexidos e cada linha dela.

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
    @Environment(\.paneWidth) private var paneWidth
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
            // Alinhado pelo topo quando a linha tem duas alturas: centralizado, o ícone
            // ficava um degrau abaixo do nome e a lista parecia desalinhada.
            HStack(alignment: compacto ? .top : .center, spacing: 10) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                if compacto {
                    // Coluna estreita: o nome fica com a linha inteira e a pasta e os
                    // números descem. Disputando espaço na mesma linha, o nome sobrava
                    // como "in…l" e não dava para saber de que arquivo era a linha.
                    VStack(alignment: .leading, spacing: 2) {
                        nome
                        HStack(spacing: 6) {
                            if let dir {
                                Text(dir).font(.caption2).foregroundStyle(theme.fgSubtle)
                                    .lineLimit(1).truncationMode(.head)
                            }
                            Spacer(minLength: 4)
                            numeros(stat)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        if let dir {
                            Text(dir).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        nome
                    }
                    Spacer(minLength: 8)
                    numeros(stat)
                    Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(theme.fgSubtle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, compacto ? 8 : 0)
            .frame(minHeight: compacto ? 46 : (dir == nil ? 40 : 46))
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

    var compacto: Bool {
        paneWidth < 250
    }

    var nome: some View {
        HStack(spacing: 5) {
            Text(name).font(.subheadline).foregroundStyle(theme.fg)
                .lineLimit(1).truncationMode(.middle).layoutPriority(1)
            if staged, !compacto {
                Text("no stage").font(.caption2).foregroundStyle(theme.ok)
            }
            if compacto {
                Spacer(minLength: 0)
                if staged {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                        .foregroundStyle(theme.ok)
                }
            }
        }
    }

    @ViewBuilder func numeros(_ stat: (added: Int, removed: Int)?) -> some View {
        if let stat {
            HStack(spacing: 6) {
                Text("+\(stat.added)").foregroundStyle(theme.ok)
                Text("−\(stat.removed)").foregroundStyle(theme.danger)
            }
            .font(.caption).monospacedDigit()
            .lineLimit(1)
            .fixedSize()
        } else if git.ehBinario(entry.path) {
            Text("binário").font(.caption).foregroundStyle(theme.fgSubtle).lineLimit(1).fixedSize()
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
