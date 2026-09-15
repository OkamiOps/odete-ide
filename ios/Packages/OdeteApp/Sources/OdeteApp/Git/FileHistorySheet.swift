import OdeteCore
import OdeteGit
import OdeteI18n
import OdeteUI
import SwiftUI
import UIKit

/// Versões de um arquivo: a linha do tempo dos commits que o tocaram, mais o estado
/// local ainda não commitado, com o diff da versão escolhida do lado.
struct FileHistorySheet: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    var path: String
    @State private var commits: [Commit] = []
    @State private var loading = true
    @State private var escolhida: Versao?
    @State private var diff: FileDiff?
    @State private var carregandoDiff = false

    /// Uma versão do arquivo: um commit, ou o que está no disco agora.
    enum Versao: Identifiable, Hashable {
        case local
        case commit(Commit)
        var id: String {
            switch self {
            case .local: "local"
            case let .commit(c): c.id
            }
        }
    }

    var temLocal: Bool {
        ws.git.status.contains { $0.path == path }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sizeClass == .compact {
                    lista
                        .navigationDestination(item: $escolhida) { v in
                            detalhe(v).background(theme.bg).navigationBarTitleDisplayMode(.inline)
                        }
                } else {
                    HStack(spacing: 0) {
                        lista.frame(width: 300)
                        Rectangle().fill(theme.separator).frame(width: 0.5)
                        Group {
                            if let escolhida {
                                detalhe(escolhida)
                            } else {
                                EmptyState(
                                    "clock.arrow.circlepath",
                                    title: tr("Escolha uma versão"),
                                    text: tr("O diff do arquivo naquele ponto aparece aqui.")
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .background(theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Fechar")) { dismiss() } }
                ToolbarItem(placement: .principal) { Titulo(path: path, detalhe: tr("Histórico")) }
                ToolbarItem(placement: .topBarTrailing) { menu }
            }
            .task { await load() }
        }
        .presentationDetents([.large])
        .presentationSizing(.page)
    }

    /// Ações secundárias num menu: como ação de confirmação da barra, o botão virava uma
    /// bolota laranja sem rótulo no canto.
    var menu: some View {
        Menu {
            Button(tr("Blame"), systemImage: "person.text.rectangle") { ws.blamePath = path; dismiss() }
            if case let .commit(c) = escolhida {
                Button(tr("Copiar sha"), systemImage: "number") { UIPasteboard.general.string = c.id }
            }
            Button(tr("Copiar caminho"), systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(tr("Mais"))
    }

    // MARK: linha do tempo

    var lista: some View {
        ScrollPane {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                } else if commits.isEmpty, !temLocal {
                    Text(tr("Nenhum commit tocou este arquivo ainda."))
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(16)
                }
                if temLocal {
                    Section {
                        linha(.local)
                    } header: {
                        cabecalho("Agora")
                    }
                }
                ForEach(grupos, id: \.titulo) { g in
                    Section {
                        ForEach(g.commits) { c in linha(.commit(c)) }
                    } header: {
                        cabecalho(g.titulo)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .background(theme.surface)
    }

    func cabecalho(_ texto: String) -> some View {
        Text(texto.uppercased())
            .font(OdeteFont.label).tracking(1).foregroundStyle(theme.fgSubtle)
            .padding(.horizontal, 14).frame(height: 28, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface)
    }

    func linha(_ v: Versao) -> some View {
        let atual = escolhida == v
        return Button { escolher(v) } label: {
            HStack(alignment: .top, spacing: 10) {
                trilho(atual: atual, local: v == .local)
                VStack(alignment: .leading, spacing: 4) {
                    Text(titulo(v))
                        .font(.subheadline.weight(atual ? .semibold : .regular))
                        .foregroundStyle(theme.fg).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if case let .commit(c) = v {
                            Text(c.short).font(OdeteFont.mono(10))
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 5).frame(height: 16)
                                .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                            Text(c.author.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Text(c.date.formatted(date: .omitted, time: .shortened))
                                .font(.caption2).foregroundStyle(theme.fgSubtle)
                        } else {
                            Text(tr("mudanças no disco, sem commit"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(
                atual ? theme.accent.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Bolinha e fio da linha do tempo, que é o que faz a lista parecer um histórico e
    /// não uma tabela.
    func trilho(atual: Bool, local: Bool) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(local ? theme.ok : (atual ? theme.accent : theme.fgSubtle))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            Rectangle().fill(theme.separator).frame(width: 1)
        }
        .frame(width: 8)
    }

    func titulo(_ v: Versao) -> String {
        switch v {
        case .local: tr("Alterações locais")
        case let .commit(c): c.summary
        }
    }

    /// Commits agrupados por dia, com "Hoje" e "Ontem" por extenso.
    var grupos: [(titulo: String, commits: [Commit])] {
        var out: [(String, [Commit])] = []
        for c in commits {
            let t = dia(c.date)
            if out.last?.0 == t {
                out[out.count - 1].1.append(c)
            } else {
                out.append((t, [c]))
            }
        }
        return out
    }

    func dia(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            return "Hoje"
        }
        if cal.isDateInYesterday(d) {
            return "Ontem"
        }
        return d.formatted(.dateTime.day().month(.wide).year())
    }

    // MARK: diff da versão

    func detalhe(_ v: Versao) -> some View {
        VStack(spacing: 0) {
            ficha(v)
            Rectangle().fill(theme.separator).frame(height: 0.5)
            if carregandoDiff {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diff {
                ScrollPane {
                    FileDiffView(file: diff, source: fonte(v)).padding(Metrics.s2)
                }
            } else {
                EmptyState(
                    "doc.text.magnifyingglass",
                    title: tr("Sem diff"),
                    text: tr("Este commit não mudou o conteúdo deste arquivo.")
                )
            }
        }
    }

    /// Ficha do commit em cima do diff: mensagem inteira, autor, data e o corpo, que
    /// antes não apareciam em lugar nenhum.
    func ficha(_ v: Versao) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titulo(v)).font(.headline).foregroundStyle(theme.fg)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if case let .commit(c) = v {
                    Text(c.short).font(OdeteFont.mono(10.5)).foregroundStyle(theme.accent)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    Text(c.author.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(c.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(theme.fgSubtle)
                } else {
                    Label(tr("no disco, ainda sem commit"), systemImage: "pencil.circle")
                        .font(.caption).foregroundStyle(theme.ok)
                }
                Spacer(minLength: 8)
                if let diff {
                    HStack(spacing: 6) {
                        Text("+\(diff.additions)").foregroundStyle(theme.ok)
                        Text("−\(diff.deletions)").foregroundStyle(theme.danger)
                    }
                    .font(.caption.weight(.medium)).monospacedDigit()
                }
            }
            if case let .commit(c) = v, !c.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(c.body.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
    }

    func fonte(_ v: Versao) -> Repository.DiffSource {
        switch v {
        case .local: .headToWorkdir
        case let .commit(c): .commit(c.id)
        }
    }

    // MARK: dados

    func load() async {
        guard let repo = ws.git.repo else { loading = false; return }
        commits = await (try? repo.log(path: path)) ?? []
        loading = false
        if sizeClass != .compact {
            if temLocal {
                escolher(.local)
            } else if let first = commits.first {
                escolher(.commit(first))
            }
        }
    }

    func escolher(_ v: Versao) {
        escolhida = v
        diff = nil
        carregandoDiff = true
        Task {
            guard let repo = ws.git.repo else { carregandoDiff = false; return }
            let d = try? await repo.diff(fonte(v), path: path)
            diff = d?.files.first
            carregandoDiff = false
        }
    }
}

/// Título das folhas de git: nome do arquivo em destaque e a pasta embaixo, no lugar do
/// caminho inteiro em uma linha só.
struct Titulo: View {
    @Environment(\.theme) private var theme
    var path: String
    var detalhe: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                FileGlyph(path: path, size: 11)
                Text(path.split(separator: "/").last.map(String.init) ?? path)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(theme.fg).lineLimit(1)
            }
            Text(pasta).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }
    }

    var pasta: String {
        let partes = path.split(separator: "/").dropLast()
        return partes.isEmpty ? detalhe : "\(detalhe) · \(partes.joined(separator: "/"))"
    }
}
