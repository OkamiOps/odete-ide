import OdeteAccounts
import OdeteCore
import OdeteFiles
import OdeteGit
import OdeteI18n
import OdeteUI
import SwiftUI

/// Clonar um repositório para `Documents/Projects/<nome>`.
struct CloneSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(ChromeState.self) private var chrome
    @Environment(AccountStore.self) private var accounts
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var name = ""
    @State private var repos: [GitHubRepo] = []
    @State private var loadingRepos = false
    @State private var progress: CloneProgress?
    @State private var running = false
    @State private var error: String?
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("URL do repositório")) {
                    TextField("https://github.com/usuario/repo.git", text: $url)
                        .autocorrectionDisabled().textInputAutocapitalization(.never).keyboardType(.URL)
                        .onChange(of: url) { _, v in
                            if name.isEmpty || name == derivedName(from: url) {
                                name = derivedName(from: v)
                            }
                        }
                    TextField(tr("nome da pasta"), text: $name).autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                if accounts.github != nil {
                    Section(tr("Seus repositórios no GitHub")) {
                        TextField(tr("filtrar"), text: $filter)
                        if loadingRepos {
                            ProgressView()
                        }
                        ForEach(repos.filter { filter.isEmpty || $0.fullName.localizedCaseInsensitiveContains(filter) }
                            .prefix(50))
                        { r in
                            Button {
                                url = r.cloneUrl
                                name = r.name
                            } label: {
                                HStack {
                                    Image(systemName: r.isPrivate ? "lock" : "globe").foregroundStyle(.secondary)
                                    VStack(alignment: .leading) {
                                        Text(r.fullName).foregroundStyle(.primary)
                                        if let d = r.description,
                                           !d
                                           .isEmpty
                                        {
                                            Text(d).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        Text(
                            tr(
                                "Entre com o GitHub em Ajustes → Contas para listar seus repositórios e clonar privados."
                            )
                        )
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let p = progress {
                    Section(tr("Clonando")) {
                        ProgressView(value: p.fraction)
                        Text(
                            tr(
                                "%1$@/%2$@ objetos · %3$@",
                                "\(p.received)",
                                "\(p.total)",
                                "\(ByteCountFormatter.string(fromByteCount: Int64(p.bytes), countStyle: .file))"
                            )
                        )
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(tr("Clonar repositório"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Cancelar")) { dismiss() }.disabled(running) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Clonar"), action: clone)
                        .disabled(running || url.trimmingCharacters(in: .whitespaces).isEmpty || name.isEmpty)
                }
            }
            .task { await loadRepos() }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(running)
    }

    func derivedName(from url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("/") {
            s.removeLast()
        }
        if s.hasSuffix(".git") {
            s.removeLast(4)
        }
        return s.split(separator: "/").last.map(String.init) ?? ""
    }

    func loadRepos() async {
        guard let acc = accounts.github, let token = accounts.token(for: acc) else { return }
        loadingRepos = true
        defer { loadingRepos = false }
        repos = await (try? GitHubAPI(token: token).repos()) ?? []
    }

    func clone() {
        let u = url.trimmingCharacters(in: .whitespaces)
        let dir = app.store.root.appending(path: name, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: dir.path) {
            error = tr("já existe um projeto chamado %1$@", "\(name)"); return
        }
        var cred: Credentials?
        if let acc = accounts.account(forRemote: u), let t = accounts.token(for: acc) {
            cred = Credentials(
                username: acc.kind.gitUsername,
                token: t
            )
        }
        running = true
        error = nil
        progress = CloneProgress(received: 0, total: 0, bytes: 0, indexed: 0)
        Task {
            do {
                try FileManager.default.createDirectory(at: app.store.root, withIntermediateDirectories: true)
                _ = try await Repository.clone(u, to: dir, credentials: cred) { p in
                    Task { @MainActor in progress = p }
                }
                app.refresh()
                if let p = app.projects.first(where: { $0.name == name }) {
                    dismiss()
                    app.open(p, chrome: chrome)
                }
            } catch {
                try? FileManager.default.removeItem(at: dir)
                self.error = error.localizedDescription
            }
            running = false
            progress = nil
        }
    }
}
