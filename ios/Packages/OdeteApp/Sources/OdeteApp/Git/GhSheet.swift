import OdeteAccounts
import OdeteCore
import OdeteGit
import OdeteUI
import SwiftUI

/// Folha GitHub: PRs, Criar PR, Issues, Actions.
struct GhSheet: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Int
    @State private var openPull: GitHubPull?

    init(tab: Int = 0, pull: GitHubPull? = nil) {
        _tab = State(initialValue: tab)
        _openPull = State(initialValue: pull)
    }

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
        .sheet(item: $openPull) { p in PullDetail(slug: slug, api: api, pull: p) {} }
    }
}

/// Card do painel Git: PRs abertos do repositório, com atalho para criar.
struct PullRequestsCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @State private var pulls: [GitHubPull] = []
    @State private var loading = false
    @State private var error: String?
    @State private var sheet: GhTarget?

    struct GhTarget: Identifiable {
        var tab: Int
        var pull: GitHubPull?
        var id: String {
            "\(tab):\(pull?.number ?? 0)"
        }
    }

    var body: some View {
        GitCard(title: "Pull requests", trailing: loading ? "…" : "\(pulls.count) abertos") {
            if let recado {
                // "GitHub 404: Not Found" no meio do painel não diz o que fazer.
                Text(recado).font(.caption).foregroundStyle(theme.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if pulls.isEmpty, !loading {
                Text("Nenhum PR aberto.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(pulls.prefix(5)) { p in
                Button { sheet = GhTarget(tab: 0, pull: p) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: p.draft == true ? "arrow.triangle.pull" : "arrow.triangle.pull")
                            .font(.system(size: 12)).foregroundStyle(p.draft == true ? theme.fgSubtle : theme.ok)
                            .padding(
                                .top,
                                2
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.title).font(OdeteFont.ui(12.5)).foregroundStyle(theme.fg).lineLimit(2)
                            Text("#\(p.number) · \(p.head.ref) → \(p.base.ref) · \(p.user?.login ?? "")")
                                .font(OdeteFont.ui(10.5)).foregroundStyle(theme.fgSubtle).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                GitButton(title: "Criar PR", symbol: "plus", accent: true, disabled: false) { sheet = GhTarget(
                    tab: 1,
                    pull: nil
                ) }
                GitButton(title: "Ver todos", symbol: "list.bullet", disabled: false) { sheet = GhTarget(
                    tab: 0,
                    pull: nil
                ) }
            }
        }
        .task(id: ws.git.githubSlug) { await load() }
        .sheet(item: $sheet, onDismiss: { Task { await load() } }) { t in GhSheet(tab: t.tab, pull: t.pull) }
    }

    /// Recado no lugar do erro cru da API.
    var recado: String? {
        if ws.git.githubToken == nil {
            return "Conecte uma conta do GitHub nos Ajustes para ver e abrir pull requests."
        }
        guard let error else { return nil }
        if error.contains("404") {
            return "Não achei este repositório no GitHub. Confira o remoto e se a conta tem acesso a ele."
        }
        if error.contains("401") || error.contains("403") {
            return "A conta do GitHub não tem acesso a este repositório."
        }
        return error
    }

    func load() async {
        guard let slug = ws.git.githubSlug else { return }
        loading = true
        do { pulls = try await GitHubAPI(token: ws.git.githubToken).pulls(slug); error = nil } catch {
            self.error = error.localizedDescription
        }
        loading = false
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
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var files: [GitHubPullFile] = []
    @State private var comments: [GitHubComment] = []
    @State private var checks: [GitHubCheckRun] = []
    @State private var draft = ""
    @State private var error: String?
    @State private var openFiles: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Text("\(pull.head.ref) → \(pull.base.ref)").font(OdeteFont.mono(11))
                        if pull.draft == true {
                            Text("rascunho").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(
                                .quaternary,
                                in: Capsule()
                            )
                        }
                        Spacer()
                        Button { openURL(URL(string: pull.htmlUrl)!) } label: { Image(systemName: "safari") }
                            .buttonStyle(.glass).controlSize(.small)
                    }
                    MarkdownText(text: pull.body?.isEmpty == false ? pull.body! : "_sem descrição_")
                }
                if !checks.isEmpty {
                    Section("Checks") {
                        ForEach(checks) { c in
                            HStack {
                                Image(systemName: checkIcon(c)).foregroundStyle(checkColor(c))
                                Text(c.name).font(OdeteFont.ui(13))
                                Spacer()
                                Text(c.conclusion ?? c.status).font(OdeteFont.mono(10.5)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Arquivos (\(files.count))") {
                    ForEach(files) { f in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                if openFiles.contains(f.id) {
                                    openFiles.remove(f.id)
                                } else {
                                    openFiles.insert(f.id)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: openFiles.contains(f.id) ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                                    Text(f.filename).font(OdeteFont.mono(11.5)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("+\(f.additions) −\(f.deletions)").font(OdeteFont.mono(10.5))
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if openFiles.contains(f.id), let patch = f.patch {
                                ScrollPane(.horizontal) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(
                                            Array(patch.split(separator: "\n", omittingEmptySubsequences: false)
                                                .enumerated()),
                                            id: \.offset
                                        ) { _, l in
                                            Text(String(l)).font(OdeteFont.mono(11))
                                                .foregroundStyle(l.hasPrefix("+") ? theme.ok : l.hasPrefix("-") ? theme
                                                    .danger : l.hasPrefix("@@") ? theme.accent : theme.fgMuted)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(l.hasPrefix("+") ? theme.ok.opacity(0.08) : l
                                                    .hasPrefix("-") ? theme.danger.opacity(0.08) : .clear)
                                        }
                                    }
                                }
                                .frame(maxHeight: 320)
                            }
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
                        TextField("comentar…", text: $draft, axis: .vertical).lineLimit(1 ... 6)
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
        checks = await (try? api.checkRuns(slug, ref: pull.head.sha)) ?? []
    }

    func checkIcon(_ c: GitHubCheckRun) -> String {
        switch (c.status, c.conclusion) {
        case (_, "success"): "checkmark.circle.fill"
        case (_, "failure"), (_, "timed_out"): "xmark.circle.fill"
        case ("completed", _): "minus.circle"
        default: "circle.dotted"
        }
    }

    func checkColor(_ c: GitHubCheckRun) -> Color {
        switch c.conclusion {
        case "success": theme.ok
        case "failure", "timed_out": theme.danger
        default: theme.fgSubtle
        }
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
    @State private var suggesting = false

    var body: some View {
        Form {
            HStack {
                TextField("Título", text: $title)
                Button {
                    suggesting = true
                    Task {
                        do {
                            let s = try await ws.agent.suggestPullRequest(base: base)
                            title = s.title
                            desc = s.body
                        } catch { self.error = error.localizedDescription }
                        suggesting = false
                    }
                } label: {
                    if suggesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                }
                .buttonStyle(.glass).controlSize(.small).disabled(suggesting)
                .help("Sugerir título e descrição com o agente")
            }
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
