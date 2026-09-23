import OdeteCore
import OdeteFiles
import OdeteI18n
import OdeteUI
import SwiftUI

/// Busca de texto no projeto, resultados agrupados por arquivo.
struct SearchPane: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var regex = false
    @State private var caseSensitive = false
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var task: Task<Void, Never>?
    @State private var trocarAberto = false
    @State private var troca = ""
    @State private var confirmandoTroca = false
    /// O que a troca vai fazer, calculado antes de perguntar — com a mesma conta da troca.
    @State private var previa = WorkspaceModel.PreviaDaTroca()
    @State private var recado: String?
    @FocusState private var focused: Bool

    var consulta: ConsultaDeTexto {
        ConsultaDeTexto(texto: query, regex: regex, caseSensitive: caseSensitive)
    }

    /// Ocorrências de verdade, não linhas: uma linha com três vira três.
    var totalDeOcorrencias: Int {
        hits.reduce(0) { $0 + $1.ocorrencias }
    }

    var grouped: [(path: String, hits: [SearchHit])] {
        var order: [String] = []
        var map: [String: [SearchHit]] = [:]
        for h in hits {
            if map[h.path] == nil {
                order.append(h.path)
            }
            map[h.path, default: []].append(h)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                tr("Busca"),
                detail: hits.isEmpty ? nil : tr("%1$@ em %2$@ arquivos", "\(totalDeOcorrencias)", "\(grouped.count)")
            )
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.fgSubtle)
                    TextField(tr("buscar no projeto"), text: $query)
                        .focused($focused)
                        .textFieldStyle(.plain)
                        .font(OdeteFont.mono(13))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { run() }
                    if !query.isEmpty {
                        Button { query = ""; hits = [] } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(theme.fgSubtle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr("Limpar busca"))
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(focused ? theme.accent : theme.border))
                if trocarAberto {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.2.squarepath").foregroundStyle(theme.fgSubtle)
                        TextField(tr("trocar por"), text: $troca)
                            .textFieldStyle(.plain)
                            .font(OdeteFont.mono(13))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                    .background(theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.border))
                }
                HStack(spacing: 6) {
                    chip("Aa", on: $caseSensitive, label: tr("Distinguir maiúsculas"))
                    chip(".*", on: $regex, label: tr("Expressão regular"))
                    chip("↔", on: $trocarAberto, label: tr("Substituir"))
                    Spacer()
                    if searching {
                        ProgressView().controlSize(.small)
                    } else if trocarAberto, !hits.isEmpty {
                        Button(tr("Trocar tudo")) {
                            previa = ws.previaDaTroca(consulta, por: troca, em: grouped.map(\.path))
                            confirmandoTroca = true
                        }
                            .font(.caption.weight(.medium))
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
                if let recado {
                    Text(recado).font(.caption).foregroundStyle(theme.ok)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
            if hits.isEmpty, !query.isEmpty, !searching {
                Text(tr("nada encontrado")).font(OdeteFont.ui(12)).foregroundStyle(theme.fgSubtle).padding(16)
                Spacer()
            } else {
                ScrollPane {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(grouped, id: \.path) { g in
                            HStack(spacing: 6) {
                                FileGlyph(path: g.path, size: 12)
                                Text(g.path).font(OdeteFont.mono(11)).foregroundStyle(theme.fgMuted).lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("\(g.hits.reduce(0) { $0 + $1.ocorrencias })").font(OdeteFont.mono(10))
                                    .foregroundStyle(theme.fgSubtle)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(theme.bgSubtle.opacity(0.5))
                            .contextMenu {
                                Button(tr("Abrir"), systemImage: "doc.text") { ws.open(g.path, line: g.hits[0].line) }
                                if trocarAberto {
                                    Button(tr("Trocar só neste arquivo"), systemImage: "arrow.2.squarepath") {
                                        trocar(em: [g.path])
                                    }
                                }
                            }
                            ForEach(g.hits) { h in
                                Button { ws.open(h.path, line: h.line) } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(h.line)").font(OdeteFont.mono(11)).foregroundStyle(theme.fgSubtle)
                                            .frame(
                                                width: 34,
                                                alignment: .trailing
                                            )
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(highlight(h.text)).font(OdeteFont.mono(12)).lineLimit(1)
                                            // A prévia da troca, linha a linha, com a mesma
                                            // conta que a troca vai fazer.
                                            if trocarAberto, let depois = previaDaLinha(h.text) {
                                                Text(depois).font(OdeteFont.mono(12)).lineLimit(1)
                                                    .foregroundStyle(theme.ok)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: Metrics.row)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            tr("Trocar %1$@ ocorrência(s) em %2$@ arquivo(s)?", "\(previa.total)", "\(previa.arquivos.count)"),
            isPresented: $confirmandoTroca,
            titleVisibility: .visible
        ) {
            Button(tr("Trocar tudo"), role: .destructive) { trocar(em: previa.arquivos.map(\.path)) }
                .disabled(previa.total == 0)
            Button(tr("Cancelar"), role: .cancel) {}
        } message: {
            Text(mensagemDaTroca)
        }
        .onChange(of: query) { _, _ in schedule() }
        .onChange(of: regex) { _, _ in run() }
        .onChange(of: caseSensitive) { _, _ in run() }
        .onAppear { focused = true }
    }

    /// Os arquivos que a troca vai mexer, com quantas trocas cada um — a prévia antes de
    /// confirmar —, e onde fica a versão de antes de cada arquivo.
    var mensagemDaTroca: String {
        let lista = previa.arquivos.prefix(6).map { "\($0.path) (\($0.trocas))" }
        let resto = previa.arquivos.count - lista.count
        var linhas = lista
        if resto > 0 {
            linhas.append(tr("e mais %1$@", "\(resto)"))
        }
        linhas.append("")
        linhas.append(tr("Abas abertas recebem a troca no editor, e dá para desfazer lá. Os outros arquivos são gravados no disco, e a versão de antes de cada um fica no histórico local."))
        return linhas.joined(separator: "\n")
    }

    /// A linha como fica depois da troca, ou `nil` se a troca não muda nada nela.
    func previaDaLinha(_ linha: String) -> String? {
        guard !query.isEmpty, let r = try? consulta.trocar(em: linha, por: troca), r.trocas > 0 else { return nil }
        return r.texto.trimmingCharacters(in: .whitespaces)
    }

    /// Troca nos arquivos escolhidos — no texto das abas abertas, no disco dos outros — e
    /// refaz a busca.
    func trocar(em paths: [String]) {
        let r = ws.trocarNoProjeto(consulta, por: troca, em: paths)
        recado = r.trocas == 0
            ? tr("nada foi trocado")
            : tr("%1$@ troca(s) em %2$@ arquivo(s)", "\(r.trocas)", "\(r.arquivos)")
        run()
    }

    func chip(_ text: String, on: Binding<Bool>, label: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Text(text)
                .font(OdeteFont.mono(11, weight: .medium))
                .foregroundStyle(on.wrappedValue ? theme.accentFg : theme.fgMuted)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(on.wrappedValue ? theme.accent : theme.bgSubtle, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// A linha com as ocorrências em destaque — todas, e também em regex, pela mesma
    /// consulta da busca.
    func highlight(_ line: String) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var a = AttributedString(trimmed)
        a.foregroundColor = theme.fg
        guard !query.isEmpty, let achados = try? consulta.ocorrencias(em: trimmed) else { return a }
        for m in achados {
            guard let r = Range(m.range, in: trimmed),
                  let lo = AttributedString.Index(r.lowerBound, within: a),
                  let hi = AttributedString.Index(r.upperBound, within: a) else { continue }
            a[lo ..< hi].foregroundColor = theme.accent
            a[lo ..< hi].font = OdeteFont.mono(12, weight: .bold)
        }
        return a
    }

    func schedule() {
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled {
                run()
            }
        }
    }

    func run() {
        let q = query, re = regex, cs = caseSensitive, root = ws.root
        guard !q.isEmpty else { hits = []; return }
        searching = true
        // As abas abertas entram com o texto delas, não com o disco: a lista mostra o que
        // está na tela, e a troca trabalha sobre o mesmo texto.
        let abertos = ws.textosAbertos()
        Task.detached(priority: .userInitiated) {
            let found = (try? TextSearch.search(root: root, query: q, regex: re, caseSensitive: cs, abertos: abertos)) ?? []
            await MainActor.run {
                if query == q {
                    hits = found; searching = false
                }
            }
        }
    }
}
