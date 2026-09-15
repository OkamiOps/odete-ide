import OdeteCore
import OdeteFiles
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
    @State private var recado: String?
    @FocusState private var focused: Bool

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
            PaneHeader("Busca", detail: hits.isEmpty ? nil : "\(hits.count) em \(grouped.count) arquivos")
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.fgSubtle)
                    TextField("buscar no projeto", text: $query)
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
                        TextField("trocar por", text: $troca)
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
                    chip("Aa", on: $caseSensitive, label: "Distinguir maiúsculas")
                    chip(".*", on: $regex, label: "Expressão regular")
                    chip("↔", on: $trocarAberto, label: "Substituir")
                    Spacer()
                    if searching {
                        ProgressView().controlSize(.small)
                    } else if trocarAberto, !hits.isEmpty {
                        Button("Trocar tudo") { confirmandoTroca = true }
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
                Text("nada encontrado").font(OdeteFont.ui(12)).foregroundStyle(theme.fgSubtle).padding(16)
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
                                Text("\(g.hits.count)").font(OdeteFont.mono(10)).foregroundStyle(theme.fgSubtle)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(theme.bgSubtle.opacity(0.5))
                            .contextMenu {
                                Button("Abrir", systemImage: "doc.text") { ws.open(g.path, line: g.hits[0].line) }
                                if trocarAberto {
                                    Button("Trocar só neste arquivo", systemImage: "arrow.2.squarepath") {
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
                                        Text(highlight(h.text)).font(OdeteFont.mono(12)).lineLimit(1)
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
            "Trocar \(hits.count) ocorrência(s) em \(grouped.count) arquivo(s)?",
            isPresented: $confirmandoTroca,
            titleVisibility: .visible
        ) {
            Button("Trocar tudo", role: .destructive) { trocar(em: grouped.map(\.path)) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Isto grava nos arquivos. O desfazer da árvore não cobre troca em massa: confira no git depois.")
        }
        .onChange(of: query) { _, _ in schedule() }
        .onChange(of: regex) { _, _ in run() }
        .onChange(of: caseSensitive) { _, _ in run() }
        .onAppear { focused = true }
    }

    /// Grava a troca nos arquivos escolhidos e refaz a busca.
    func trocar(em paths: [String]) {
        do {
            let r = try TextSearch.replace(
                root: ws.root,
                query: query,
                with: troca,
                regex: regex,
                caseSensitive: caseSensitive,
                in: paths
            )
            for p in paths {
                ws.reloadBuffer(p)
            }
            ws.reload()
            ws.git.scheduleRefresh()
            recado = r.trocas == 0
                ? "nada foi trocado"
                : "\(r.trocas) troca(s) em \(r.arquivos) arquivo(s)"
            run()
        } catch {
            ws.error = error.localizedDescription
        }
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

    func highlight(_ line: String) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var a = AttributedString(trimmed)
        a.foregroundColor = theme.fg
        if !regex, let r = trimmed.range(of: query, options: caseSensitive ? [] : [.caseInsensitive]),
           let lo = AttributedString.Index(r.lowerBound, within: a), let hi = AttributedString.Index(
               r.upperBound,
               within: a
           )
        {
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
        Task.detached(priority: .userInitiated) {
            let found = (try? TextSearch.search(root: root, query: q, regex: re, caseSensitive: cs)) ?? []
            await MainActor.run {
                if query == q {
                    hits = found; searching = false
                }
            }
        }
    }
}
