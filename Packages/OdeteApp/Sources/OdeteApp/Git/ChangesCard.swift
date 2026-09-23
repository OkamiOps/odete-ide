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
    /// Os caminhos esperando a confirmação do "Descartar tudo".
    @State private var descartando: [String]?
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
            // Descartava na hora, sem perguntar, e o não rastreado sumia de vez.
            Button(tr("Descartar tudo"), systemImage: "arrow.uturn.backward", role: .destructive) {
                descartando = git.unstaged.map(\.path)
            }
            .disabled(git.unstaged.isEmpty || git.busy)
        }
        .padding(.bottom, 8)
        .modifier(ConfirmaDescarte(caminhos: $descartando))
        if !git.discarded.isEmpty {
            AvisoDeDescarte()
                .padding(.bottom, 8)
        }
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

/// Confirmação de descarte com a conta de cada tipo: o rastreado volta à versão do git,
/// o não rastreado vai para a lixeira do projeto. Os dois têm desfazer, mas a pessoa
/// precisa saber o que vai acontecer antes de tocar.
struct ConfirmaDescarte: ViewModifier {
    @Environment(WorkspaceModel.self) private var ws
    @Binding var caminhos: [String]?

    func body(content: Content) -> some View {
        let conta = ws.git.discardCount(caminhos ?? [])
        return content.confirmationDialog(
            (caminhos?.count ?? 0) == 1 ? tr("Descartar as alterações deste arquivo?")
                : tr("Descartar %1$@ arquivos?", "\(caminhos?.count ?? 0)"),
            isPresented: Binding(get: { caminhos != nil }, set: {
                if !$0 {
                    caminhos = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button(tr("Descartar"), role: .destructive) {
                if let c = caminhos {
                    ws.git.discard(c)
                }
                caminhos = nil
            }
            Button(tr("Cancelar"), role: .cancel) { caminhos = nil }
        } message: {
            Text(Self.mensagem(rastreados: conta.tracked, naoRastreados: conta.untracked))
        }
    }

    static func mensagem(rastreados: Int, naoRastreados: Int) -> String {
        var partes: [String] = []
        if rastreados > 0 {
            partes.append(tr("Rastreados: %1$@. Voltam à última versão que o git tem.", "\(rastreados)"))
        }
        if naoRastreados > 0 {
            partes.append(tr("Não rastreados: %1$@. Vão para a lixeira do projeto.", "\(naoRastreados)"))
        }
        partes.append(tr("Dá para desfazer logo depois, no aviso que aparece na lista."))
        return partes.joined(separator: "\n")
    }
}

/// Aviso do último descarte, com o desfazer. Some na ação seguinte do painel.
struct AvisoDeDescarte: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme

    var body: some View {
        let n = ws.git.discarded.count
        HStack(spacing: 8) {
            Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.fgMuted)
            Text(n == 1 ? tr("1 arquivo descartado") : tr("%1$@ arquivos descartados", "\(n)"))
                .font(.caption).foregroundStyle(theme.fgMuted).lineLimit(1)
            Spacer(minLength: 4)
            Button(tr("Desfazer")) { ws.git.undoDiscard() }
                .font(.caption.weight(.semibold))
                .disabled(ws.git.busy)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    @State private var descartando: [String]?

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
                    descartando = [entry.path]
                }
            }
        }
        .modifier(ConfirmaDescarte(caminhos: $descartando))
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
