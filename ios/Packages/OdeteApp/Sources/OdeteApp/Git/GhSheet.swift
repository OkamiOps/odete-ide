import OdeteAccounts
import OdeteCore
import OdeteGit
import OdeteUI
import SwiftUI

/// Folha GitHub: PRs, Criar PR, Issues, Actions.
struct GhSheet: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var slug: String {
        ws.git.githubSlug ?? ""
    }

    var api: GitHubAPI {
        GitHubAPI(token: ws.git.githubToken)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("PRs").tag(0); Text("Criar PR").tag(1); Text("Issues").tag(2); Text("Actions").tag(3)
                }
                .pickerStyle(.segmented).padding(10)
                switch tab {
                case 0: PullsList(slug: slug, api: api)
                case 1: CreatePR(slug: slug, api: api) { tab = 0 }
                case 2: IssuesList(slug: slug, api: api)
                default: RunsList(slug: slug, api: api)
                }
            }
            .navigationTitle(slug)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
        }
        .presentationDetents([.large])
    }
}

struct PullsList: View {
    var slug: String
    var api: GitHubAPI
    @State private var pulls: [GitHubPull] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selected: GitHubPull?

    var body: some View {
        List {
            if loading {
                ProgressView()
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            if !loading, pulls.isEmpty, error == nil {
                Text("nenhum PR aberto").foregroundStyle(.secondary)
            }
            ForEach(pulls) { p in
                Button { selected = p } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("#\(p.number)").font(.caption.monospaced()).foregroundStyle(.secondary); Text(p.title)
                                .foregroundStyle(.primary); if p
                                .draft == true
                            {
                                Text("draft").font(.caption2).padding(3).background(
                                    .quaternary,
                                    in: Capsule()
                                )
                            }
                        }
                        Text("\(p.head.ref) → \(p.base.ref) · \(p.user?.login ?? "")").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $selected) { p in PullDetail(slug: slug, api: api, pull: p) { await load() } }
    }

    func load() async {
        loading = true
        do { pulls = try await api.pulls(slug); error = nil } catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct PullDetail: View {
    var slug: String
    var api: GitHubAPI
    var pull: GitHubPull
    var onChange: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [GitHubPullFile] = []
    @State private var comments: [GitHubComment] = []
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section { Text(pull.body ?? "sem descrição").font(.body) }
                Section("Arquivos (\(files.count))") {
                    ForEach(files) { f in
                        HStack {
                            Text(f.filename).font(.caption.monospaced())
                                .lineLimit(1); Spacer(); Text("+\(f.additions) −\(f.deletions)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Comentários") {
                    ForEach(comments) { c in
                        VStack(alignment: .leading) {
                            Text(c.user?.login ?? "").font(.caption).foregroundStyle(.secondary); Text(c.body)
                        }
                    }
                    HStack {
                        TextField("comentar…", text: $draft, axis: .vertical)
                        Button("Enviar") {
                            Task {
                                try? await api.comment(slug, number: pull.number, body: draft); draft = ""; await load()
                            }
                        }
                        .disabled(draft.isEmpty)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("#\(pull.number) \(pull.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Menu("Merge") {
                        Button("Squash") { merge("squash") }
                        Button("Merge commit") { merge("merge") }
                        Button("Rebase") { merge("rebase") }
                    }
                    .disabled(pull.merged == true)
                }
            }
            .task { await load() }
        }
    }

    func load() async {
        files = await (try? api.pullFiles(slug, number: pull.number)) ?? []
        comments = await (try? api.pullComments(slug, number: pull.number)) ?? []
    }

    func merge(_ method: String) {
        Task {
            do { try await api.mergePull(slug, number: pull.number, method: method); await onChange(); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CreatePR: View {
    @Environment(WorkspaceModel.self) private var ws
    var slug: String
    var api: GitHubAPI
    var done: () -> Void
    @State private var title = ""
    @State private var desc = ""
    @State private var base = "main"
    @State private var head = ""
    @State private var draft = false
    @State private var error: String?
    @State private var sending = false

    var body: some View {
        Form {
            TextField("Título", text: $title)
            TextField("Descrição", text: $desc, axis: .vertical).lineLimit(4 ... 12)
            HStack { Text("head"); TextField("branch", text: $head).multilineTextAlignment(.trailing) }
            HStack { Text("base"); TextField("main", text: $base).multilineTextAlignment(.trailing) }
            Toggle("Rascunho", isOn: $draft)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            Button(sending ? "Enviando…" : "Criar pull request") {
                sending = true
                Task {
                    do { _ = try await api.createPull(
                        slug,
                        title: title,
                        body: desc,
                        head: head,
                        base: base,
                        draft: draft
                    ); done() } catch { self.error = error.localizedDescription }
                    sending = false
                }
            }
            .disabled(sending || title.isEmpty || head.isEmpty)
        }
        .onAppear {
            if head.isEmpty {
                head = ws.git.current?.name ?? ""
            }
            if let log = ws.git.log.first, title.isEmpty {
                title = log.summary
            }
        }
    }
}

struct IssuesList: View {
    var slug: String
    var api: GitHubAPI
    @State private var issues: [GitHubIssue] = []
    @State private var loading = true
    @State private var creating = false
    @State private var title = ""
    @State private var desc = ""
    @State private var error: String?

    var body: some View {
        List {
            if loading {
                ProgressView()
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            Button { creating = true } label: { Label("Nova issue", systemImage: "plus") }
            ForEach(issues) { i in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("#\(i.number)").font(.caption.monospaced()).foregroundStyle(.secondary); Text(i.title)
                    }
                    Text(i.user?.login ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("Nova issue", isPresented: $creating) {
            TextField("Título", text: $title)
            TextField("Descrição", text: $desc)
            Button("Criar") {
                Task {
                    _ = try? await api.createIssue(slug, title: title, body: desc); title = ""; desc = ""; await load()
                }
            }
            Button("Cancelar", role: .cancel) {}
        }
    }

    func load() async {
        loading = true
        do { issues = try await api.issues(slug); error = nil } catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct RunsList: View {
    var slug: String
    var api: GitHubAPI
    @Environment(\.openURL) private var openURL
    @State private var runs: [GitHubRun] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if loading {
                ProgressView()
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            if !loading, runs.isEmpty, error == nil {
                Text("nenhuma execução").foregroundStyle(.secondary)
            }
            ForEach(runs) { r in
                Button { openURL(URL(string: r.htmlUrl)!) } label: {
                    HStack {
                        Image(systemName: icon(r)).foregroundStyle(color(r))
                        VStack(alignment: .leading) {
                            Text(r.name ?? "workflow").foregroundStyle(.primary)
                            Text(
                                "\(r.headBranch ?? "") · \(r.event ?? "") · \(r.createdAt?.formatted(.relative(presentation: .named)) ?? "")"
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    func icon(_ r: GitHubRun) -> String {
        switch (r.status, r.conclusion) {
        case (_, "success"): "checkmark.circle.fill"
        case (_, "failure"): "xmark.circle.fill"
        case ("in_progress", _), ("queued", _): "circle.dotted"
        default: "minus.circle"
        }
    }

    func color(_ r: GitHubRun) -> Color {
        switch r.conclusion { case "success": .green; case "failure": .red; default: .secondary }
    }

    func load() async {
        loading = true
        do { runs = try await api.runs(slug); error = nil } catch { self.error = error.localizedDescription }
        loading = false
    }
}
