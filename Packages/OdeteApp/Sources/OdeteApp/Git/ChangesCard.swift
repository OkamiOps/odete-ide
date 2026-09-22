import OdeteAccounts
import OdeteCore
import OdeteGit
import OdeteI18n
import OdeteUI
import SwiftUI

// Cartão de alterações do painel Git: a lista de arquivos mexidos e cada linha dela.

/// Linhas que entraram e saíram num arquivo, ou `binario` quando o git não conta linhas.
struct ContaDoArquivo: Equatable {
    var adicionadas = 0
    var removidas = 0
    var binario = false
}

struct ChangesCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var git: GitModel {
        ws.git
    }

    /// A conta de cada arquivo, feita uma vez por corpo.
    ///
    /// Cada linha procurava o seu arquivo no diff inteiro (`lineStat(for:)` e `ehBinario`
    /// são buscas lineares), e somava as linhas dele: com milhares de arquivos mexidos a
    /// lista custava o quadrado do número de arquivos. Um dicionário montado aqui troca
    /// isso por uma passada.
    func contas() -> [String: ContaDoArquivo] {
        var out: [String: ContaDoArquivo] = [:]
        for f in git.stat.files where out[f.path] == nil {
            out[f.path] = f.isBinary
                ? ContaDoArquivo(binario: true)
                : ContaDoArquivo(adicionadas: f.additions, removidas: f.deletions)
        }
        return out
    }

    /// Os itens da lista vão direto para a lista preguiçosa do painel, um a um: dentro de
    /// um cartão de pilha comum, milhares de arquivos alterados (um `node_modules` fora do
    /// `.gitignore`) viravam milhares de linhas montadas de uma vez.
    var body: some View {
        // Medidas de docs/design/README.md: título fora do cartão, linhas com ícone
        // quadrado, números na mesma linha e chevron no fim.
        SectionTitle(
            tr("Alterações"),
            detail: git.isClean ? nil : "\(git.status.count)",
            stat: git.isClean ? nil : git.lineStat
        ) {
            Button(tr("Mandar tudo para o stage"), systemImage: "plus.circle") { git.stageAll() }
                .disabled(git.unstaged.isEmpty || git.busy)
            Button(tr("Tirar tudo do stage"), systemImage: "minus.circle") { git.unstageAll() }
                .disabled(git.staged.isEmpty || git.busy)
            Divider()
            Button(tr("Descartar tudo"), systemImage: "arrow.uturn.backward", role: .destructive) {
                git.discard(git.unstaged.map(\.path))
            }
            .disabled(git.unstaged.isEmpty || git.busy)
        }
        .padding(.bottom, 8)
        if git.isClean {
            CardList {
                Text(tr("Nada mudou desde o último commit."))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 12)
            }
        } else {
            let contas = contas()
            let itens = git.staged.map { ItemDeAlteracao(entry: $0, staged: true) }
                + git.unstaged.map { ItemDeAlteracao(entry: $0, staged: false) }
            ForEach(Array(itens.enumerated()), id: \.element.id) { i, item in
                ChangeRow(
                    entry: item.entry,
                    staged: item.staged,
                    first: i == 0,
                    ultimo: i == itens.count - 1,
                    conta: contas[item.entry.path]
                )
            }
        }
    }
}

/// Um arquivo na lista: o mesmo caminho pode estar no stage e fora dele ao mesmo tempo.
struct ItemDeAlteracao: Identifiable {
    let entry: StatusEntry
    let staged: Bool
    var id: String {
        "\(staged ? "s" : "u"):\(entry.path)"
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
    /// A última fecha os cantos de baixo do cartão.
    var ultimo = false
    /// A conta de linhas do arquivo, vinda do cartão — ver `ChangesCard.contas()`.
    var conta: ContaDoArquivo?

    var git: GitModel {
        ws.git
    }

    var change: Change {
        (staged ? entry.staged : entry.unstaged) ?? .modified
    }

    var body: some View {
        Button {
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
                            numeros
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
                    numeros
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
        // Cada linha pinta o seu pedaço do cartão; as pontas levam os cantos.
        .background(
            theme.bgElevated,
            in: UnevenRoundedRectangle(
                topLeadingRadius: first ? 14 : 0,
                bottomLeadingRadius: ultimo ? 14 : 0,
                bottomTrailingRadius: ultimo ? 14 : 0,
                topTrailingRadius: first ? 14 : 0,
                style: .continuous
            )
        )
        .contextMenu {
            Button(tr("Abrir no editor"), systemImage: "doc.text") { ws.openFile(entry.path) }
            Button(
                staged ? tr("Tirar do stage") : tr("Mandar para o stage"),
                systemImage: staged ? "minus.circle" : "plus.circle"
            ) {
                staged ? git.unstage([entry.path]) : git.stage([entry.path])
            }
            Button(tr("Histórico do arquivo"), systemImage: "clock.arrow.circlepath") { ws.historyPath = entry.path }
            if !staged {
                Button(tr("Descartar alterações"), systemImage: "arrow.uturn.backward", role: .destructive) {
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
                Text(tr("no stage")).font(.caption2).foregroundStyle(theme.ok)
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

    @ViewBuilder var numeros: some View {
        if let conta, !conta.binario {
            HStack(spacing: 6) {
                Text("+\(conta.adicionadas)").foregroundStyle(theme.ok)
                Text("−\(conta.removidas)").foregroundStyle(theme.danger)
            }
            .font(.caption).monospacedDigit()
            .lineLimit(1)
            .fixedSize()
        } else if conta?.binario == true {
            Text(tr("binário")).font(.caption).foregroundStyle(theme.fgSubtle).lineLimit(1).fixedSize()
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
