import OdeteCore
import OdeteGit
import OdeteUI
import SwiftUI

/// Commits que tocaram um arquivo; toque mostra o diff daquele commit só para o arquivo.
struct FileHistorySheet: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    var path: String
    @State private var commits: [Commit] = []
    @State private var loading = true
    @State private var selected: Commit?
    @State private var diff: FileDiff?

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                List(selection: $selected) {
                    if loading {
                        ProgressView()
                    } else if commits.isEmpty {
                        Text("nenhum commit tocou este arquivo").font(OdeteFont.ui(12)).foregroundStyle(theme.fgMuted)
                    }
                    ForEach(commits) { c in
                        Button { select(c) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text(c.short).font(OdeteFont.mono(11)).foregroundStyle(theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.summary).font(OdeteFont.ui(12.5)).foregroundStyle(theme.fg).lineLimit(2)
                                    Text("\(c.author.name) · \(c.date.formatted(.relative(presentation: .named)))")
                                        .font(OdeteFont.ui(10.5)).foregroundStyle(theme.fgSubtle)
                                }
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(selected?.id == c.id ? theme.glassTint : Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(width: 300)
                Divider()
                Group {
                    if let diff, let selected {
                        ScrollPane {
                            FileDiffView(file: diff, source: .commit(selected.id)).padding(Metrics.s2)
                        }
                    } else {
                        EmptyState(
                            "clock.arrow.circlepath",
                            title: "Escolha um commit",
                            text: "O diff do arquivo naquele commit aparece aqui."
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.bg)
            .navigationTitle(path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Blame", systemImage: "person.text.rectangle") { ws.blamePath = path; dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.large])
        .presentationSizing(.page)
    }

    func load() async {
        guard let repo = ws.git.repo else { loading = false; return }
        commits = await (try? repo.log(path: path)) ?? []
        loading = false
        if let first = commits.first {
            select(first)
        }
    }

    func select(_ c: Commit) {
        selected = c
        Task {
            guard let repo = ws.git.repo else { return }
            let d = try? await repo.diff(.commit(c.id), path: path)
            diff = d?.files.first
        }
    }
}

/// Blame simples: cada linha com autor e commit, agrupado por trecho.
struct BlameSheet: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    var path: String
    @State private var hunks: [BlameHunk] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        let lines = ws.text(for: path).components(separatedBy: "\n")
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    EmptyState("person.text.rectangle", title: "Sem blame", text: error)
                } else {
                    ScrollPane {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(hunks) { h in
                                ForEach(0 ..< h.lines, id: \.self) { i in
                                    let n = h.startLine + i
                                    HStack(spacing: 0) {
                                        Group {
                                            if i == 0 {
                                                HStack(spacing: 6) {
                                                    Text(h.isUncommitted ? "local" : h.short).font(OdeteFont.mono(10.5))
                                                        .foregroundStyle(h.isUncommitted ? theme.fgSubtle : theme
                                                            .accent)
                                                    Text(h.author).font(OdeteFont.ui(10.5))
                                                        .foregroundStyle(theme.fgMuted).lineLimit(1)
                                                    Spacer(minLength: 0)
                                                    Text(h.isUncommitted ? "" : h.date
                                                        .formatted(.dateTime.day().month(.abbreviated)))
                                                        .font(OdeteFont.ui(10)).foregroundStyle(theme.fgSubtle)
                                                }
                                            } else {
                                                Color.clear
                                            }
                                        }
                                        .frame(width: 220, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .background(color(for: h).opacity(0.10))
                                        Text("\(n)").font(OdeteFont.mono(10.5)).foregroundStyle(theme.fgSubtle)
                                            .frame(width: 40, alignment: .trailing).padding(.trailing, 10)
                                        Text(lines.indices.contains(n - 1) ? lines[n - 1] : "")
                                            .font(OdeteFont.mono(11.5))
                                            .foregroundStyle(theme.fg).lineLimit(1).truncationMode(.tail)
                                        Spacer(minLength: 20)
                                    }
                                    .frame(height: 20)
                                    .help(h.summary)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .background(theme.bg)
            .navigationTitle("Blame · \(path)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Histórico", systemImage: "clock.arrow.circlepath") { ws.historyPath = path; dismiss() }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.large])
        .presentationSizing(.page)
    }

    func color(for h: BlameHunk) -> Color {
        if h.isUncommitted {
            return theme.fgSubtle
        }
        // cor estável por commit
        let hue = Double(abs(h.sha.hashValue % 360)) / 360
        return Color(hue: hue, saturation: 0.5, brightness: 0.8)
    }

    func load() async {
        guard let repo = ws.git.repo else { error = "Este projeto não é um repositório git."; loading = false; return }
        do {
            hunks = try await repo.blame(path: path)
            if hunks.isEmpty {
                error = "Arquivo ainda sem commits."
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
