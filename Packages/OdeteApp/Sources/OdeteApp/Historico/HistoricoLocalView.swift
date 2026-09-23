import OdeteCore
import OdeteFiles
import OdeteGit
import OdeteI18n
import OdeteUI
import SwiftUI
import UIKit

/// Versões guardadas de um arquivo: a lista de um lado; do outro, o que a escolhida tem —
/// a diferença para o arquivo de agora ou o texto inteiro — com Restaurar e Copiar.
///
/// Vai dentro de um `NavigationStack`: o da folha, ou o da lista de apagados, que empurra
/// esta tela para mostrar as versões de um arquivo que não existe mais.
struct HistoricoLocalView: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    var caminho: String
    @State private var versoes: [HistoricoLocal.Versao] = []
    @State private var carregando = true
    @State private var escolhida: HistoricoLocal.Versao?
    @State private var modo: Modo = .diferenca
    @State private var detalhe: Detalhe?
    /// Hash do que está no arquivo agora, para marcar a versão igual a ele.
    @State private var hashAtual: String?
    @State private var existe = true
    @State private var recado: String?

    enum Modo: Hashable { case diferenca, conteudo }

    /// O que se carrega da versão escolhida, fora do ator principal.
    struct Detalhe: Sendable {
        var versao: HistoricoLocal.Versao
        /// `nil` quando o conteúdo não é texto.
        var texto: String?
        var linhas: [String]
        /// `nil` quando o arquivo não existe mais — não há com o que comparar.
        var diff: FileDiff?
    }

    var body: some View {
        Group {
            if sizeClass == .compact {
                lista
                    .navigationDestination(item: $escolhida) { v in
                        painel(v).background(theme.bg).navigationBarTitleDisplayMode(.inline)
                    }
            } else {
                HStack(spacing: 0) {
                    lista.frame(width: 300)
                    Rectangle().fill(theme.separator).frame(width: 0.5)
                    Group {
                        if let escolhida {
                            painel(escolhida)
                        } else {
                            EmptyState(
                                "clock",
                                title: tr("Escolha uma versão"),
                                text: tr("A diferença para o arquivo de agora aparece aqui.")
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
            ToolbarItem(placement: .principal) { Titulo(path: caminho, detalhe: tr("Histórico local")) }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
        .task { await carregar() }
    }

    var menu: some View {
        Menu {
            Button(tr("Copiar caminho"), systemImage: "doc.on.doc") { UIPasteboard.general.string = caminho }
            if existe {
                Button(tr("Abrir"), systemImage: "doc.text") {
                    ws.openFile(caminho)
                    ws.historicoLocal.arquivo = nil
                    ws.historicoLocal.apagadosEm = nil
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(tr("Mais"))
    }

    // MARK: lista

    var lista: some View {
        ScrollPane {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if carregando {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                } else if versoes.isEmpty {
                    Text(tr(
                        "Nenhuma versão guardada ainda. Ela aparece quando o arquivo é salvo por cima, mudado pelo agente, pelo git ou pelo terminal, ou apagado."
                    ))
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(16)
                }
                ForEach(grupos, id: \.titulo) { g in
                    Section {
                        ForEach(g.versoes) { linha($0) }
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

    func linha(_ v: HistoricoLocal.Versao) -> some View {
        let atual = escolhida?.id == v.id
        return Button { escolher(v) } label: {
            HStack(spacing: 10) {
                Image(systemName: v.origem.simbolo)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(atual ? theme.accentFg : theme.fgMuted)
                    .frame(width: 26, height: 26)
                    .background(atual ? theme.accent : theme.bgSubtle, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(v.origem.rotulo)
                        .font(.subheadline.weight(atual ? .semibold : .regular))
                        .foregroundStyle(theme.fg).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(v.data.noIdioma(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(theme.fgSubtle)
                        Text(Tamanho.arquivo(v.tamanho)).font(.caption2).foregroundStyle(.secondary)
                        if v.hash == hashAtual {
                            Text(tr("igual ao atual")).font(.caption2.weight(.medium)).foregroundStyle(theme.ok)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                atual ? theme.accent.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(v.origem.rotulo), \(v.data.noIdioma(date: .abbreviated, time: .shortened))")
    }

    /// Versões agrupadas por dia, com "Hoje" e "Ontem" por extenso.
    var grupos: [(titulo: String, versoes: [HistoricoLocal.Versao])] {
        var out: [(titulo: String, versoes: [HistoricoLocal.Versao])] = []
        for v in versoes {
            let t = dia(v.data)
            if out.last?.titulo == t {
                out[out.count - 1].versoes.append(v)
            } else {
                out.append((t, [v]))
            }
        }
        return out
    }

    func dia(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            return tr("Hoje")
        }
        if cal.isDateInYesterday(d) {
            return tr("Ontem")
        }
        return d.noIdioma(.dateTime.day().month(.wide).year())
    }

    // MARK: versão escolhida

    func painel(_ v: HistoricoLocal.Versao) -> some View {
        VStack(spacing: 0) {
            ficha(v)
            Rectangle().fill(theme.separator).frame(height: 0.5)
            if let d = detalhe, d.versao.id == v.id {
                conteudo(d)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    func ficha(_ v: HistoricoLocal.Versao) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(v.origem.rotulo, systemImage: v.origem.simbolo)
                    .font(.headline).foregroundStyle(theme.fg).lineLimit(1)
                Spacer(minLength: 8)
                if let d = detalhe, d.versao.id == v.id, let diff = d.diff, !diff.isBinary, !diff.hunks.isEmpty {
                    HStack(spacing: 6) {
                        Text("+\(diff.additions)").foregroundStyle(theme.ok)
                        Text("−\(diff.deletions)").foregroundStyle(theme.danger)
                    }
                    .font(.caption.weight(.medium)).monospacedDigit()
                }
            }
            HStack(spacing: 8) {
                Text(v.data.noIdioma(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(theme.fgSubtle)
                Text(Tamanho.arquivo(v.tamanho)).font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    seletor
                    Spacer(minLength: 8)
                    acoes(v)
                }
                VStack(alignment: .leading, spacing: 8) {
                    seletor
                    HStack(spacing: 8) { acoes(v) }
                }
            }
            if let recado {
                Text(recado).font(.caption).foregroundStyle(theme.ok)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
    }

    /// Arquivo apagado não tem com o que comparar: fica só o conteúdo.
    @ViewBuilder var seletor: some View {
        if existe {
            Picker("", selection: $modo) {
                Text(tr("Diferença")).tag(Modo.diferenca)
                Text(tr("Conteúdo")).tag(Modo.conteudo)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder func acoes(_ v: HistoricoLocal.Versao) -> some View {
        Button(tr("Copiar"), systemImage: "doc.on.doc") { copiar() }
            .buttonStyle(.bordered)
            .disabled(detalhe?.versao.id != v.id || detalhe?.texto == nil)
        Button(tr("Restaurar"), systemImage: "clock.arrow.circlepath") { restaurar(v) }
            .buttonStyle(.borderedProminent)
    }

    @ViewBuilder func conteudo(_ d: Detalhe) -> some View {
        if existe, modo == .diferenca, let diff = d.diff {
            if diff.isBinary {
                binario
            } else if diff.hunks.isEmpty {
                EmptyState(
                    "checkmark.circle",
                    title: tr("Igual ao arquivo de agora"),
                    text: tr("Esta versão tem o mesmo conteúdo que o arquivo tem hoje.")
                )
            } else {
                ScrollPane {
                    FileDiffView(file: diff, source: .commit("")).padding(Metrics.s2)
                }
            }
        } else if d.texto == nil {
            binario
        } else {
            ScrollPane([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(d.linhas.indices, id: \.self) { i in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(i + 1)").font(OdeteFont.mono(11)).foregroundStyle(theme.fgSubtle)
                                .frame(width: 44, alignment: .trailing)
                            Text(d.linhas[i].isEmpty ? " " : d.linhas[i]).font(OdeteFont.mono(12))
                                .foregroundStyle(theme.fg)
                                .fixedSize()
                        }
                        .frame(minHeight: 18)
                    }
                }
                .padding(12)
                .textSelection(.enabled)
            }
        }
    }

    var binario: some View {
        EmptyState(
            "doc",
            title: tr("arquivo binário"),
            text: tr("Não dá para mostrar o conteúdo, mas dá para restaurar.")
        )
    }

    // MARK: dados

    func carregar() async {
        let h = ws.historico, raiz = ws.root, c = caminho
        let editor = ws.buffers[c]
        let (lista, atual) = await Task.detached {
            (h.versoes(de: c, raiz: raiz), try? Data(contentsOf: raiz.appending(path: c)))
        }.value
        versoes = lista
        existe = atual != nil
        hashAtual = (editor.map { Data($0.utf8) } ?? atual).map(HistoricoLocal.hash)
        carregando = false
        if let e = escolhida, let mesma = lista.first(where: { $0.id == e.id }) {
            escolher(mesma)
        } else if sizeClass != .compact, let primeira = lista.first {
            escolher(primeira)
        }
    }

    func escolher(_ v: HistoricoLocal.Versao) {
        if escolhida?.id != v.id {
            recado = nil
        }
        escolhida = v
        let h = ws.historico, raiz = ws.root, c = caminho
        // Compara com o que a pessoa vê: a aba aberta, se houver, e não o disco.
        let editor = ws.buffers[c].map { Data($0.utf8) }
        Task {
            let d = await Task.detached { () -> Detalhe? in
                guard let dados = h.dados(v, de: c, raiz: raiz) else { return nil }
                let atual = editor ?? (try? Data(contentsOf: raiz.appending(path: c)))
                let texto = FileOps.pareceBinario(dados) ? nil : String(data: dados, encoding: .utf8)
                return Detalhe(
                    versao: v,
                    texto: texto,
                    linhas: texto.map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
                        ?? [],
                    diff: atual.map { FileDiff.entre(dados, $0, caminho: c) }
                )
            }.value
            guard escolhida?.id == v.id else { return }
            detalhe = d
            if d == nil {
                recado = tr("Esta versão não está mais guardada.")
            }
        }
    }

    /// Restaurar primeiro guarda o que está no arquivo — então também se desfaz, pelo
    /// próprio histórico. Texto não salvo na aba vai para o disco antes, para entrar nessa
    /// versão e não sumir.
    func restaurar(_ v: HistoricoLocal.Versao) {
        if ws.tabs.first(where: { $0.path == caminho })?.isDirty == true {
            ws.save(caminho)
        }
        do {
            try ws.historico.restaurar(v, caminho: caminho, raiz: ws.root)
            if ws.buffers[caminho] != nil {
                ws.reloadBuffer(caminho)
            }
            if !existe {
                ws.reload()
            }
            recado = tr("Restaurado. O que estava no arquivo ficou guardado no histórico.")
            Task { await carregar() }
        } catch {
            recado = error.localizedDescription
        }
    }

    func copiar() {
        guard let texto = detalhe?.texto else { return }
        UIPasteboard.general.string = texto
        recado = tr("Copiado.")
    }
}
