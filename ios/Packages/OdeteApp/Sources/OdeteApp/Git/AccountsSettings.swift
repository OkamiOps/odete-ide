import OdeteAccounts
import OdeteCore
import OdeteUI
import SwiftUI

/// Ajustes → Contas: GitHub por device flow ou token; outros hosts por token.
struct AccountsSettings: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var adding = false
    @State private var kind: HostKind = .github
    @State private var host = "github.com"
    @State private var token = ""
    @State private var login = ""
    @State private var device: GitHubDeviceFlow.DeviceCode?
    @State private var waiting = false
    @State private var error: String?

    var body: some View {
        @Bindable var accounts = accounts
        VStack(alignment: .leading, spacing: 10) {
            ForEach(accounts.accounts) { a in
                HStack(spacing: 10) {
                    Image(systemName: a.kind == .github ? "cat" : "server.rack").foregroundStyle(theme.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(a.login) · \(a.kind.label)").font(OdeteFont.ui(13, weight: .medium))
                            .foregroundStyle(theme.fg)
                        Text(a.host).font(OdeteFont.mono(10.5)).foregroundStyle(theme.fgSubtle)
                    }
                    Spacer()
                    HeaderButton("trash", label: "Remover") { accounts.remove(a) }
                }
                .frame(minHeight: 40)
            }
            if accounts.accounts.isEmpty {
                Text("Nenhuma conta. Sem conta, push e clone de repositórios privados não funcionam.")
                    .font(OdeteFont.ui(12)).foregroundStyle(theme.fgMuted)
            }
            if let d = device {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No GitHub, digite o código:").font(OdeteFont.ui(12)).foregroundStyle(theme.fgMuted)
                    HStack {
                        Text(d.userCode).font(OdeteFont.mono(22, weight: .medium)).foregroundStyle(theme.fg)
                        Spacer()
                        Button("Copiar") { UIPasteboard.general.string = d.userCode }.buttonStyle(.glass)
                        Button("Abrir GitHub") { openURL(URL(string: d.verificationUri)!) }.buttonStyle(.glassProminent)
                    }
                    if waiting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small); Text("aguardando autorização…").font(OdeteFont.ui(11))
                                .foregroundStyle(theme.fgSubtle)
                        }
                    }
                }
                .padding(10)
                .background(theme.bg, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.accent))
            }
            HStack(spacing: 6) {
                if GitHubDeviceFlow().isConfigured {
                    GitButton(title: "Entrar com GitHub", symbol: "cat", accent: true, disabled: waiting) {
                        startDeviceFlow()
                    }
                }
                GitButton(title: "Adicionar por token", symbol: "key") { adding = true }
            }
            if let error {
                Text(error).font(OdeteFont.ui(11)).foregroundStyle(theme.danger)
            }
            Text("AUTOR DOS COMMITS").font(OdeteFont.label).tracking(1).foregroundStyle(theme.fgSubtle).padding(.top, 8)
            TextField("Nome", text: $accounts.authorName).textFieldStyle(.roundedBorder)
            TextField("E-mail", text: $accounts.authorEmail).textFieldStyle(.roundedBorder).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
        }
        .sheet(isPresented: $adding) { tokenSheet }
    }

    var tokenSheet: some View {
        NavigationStack {
            Form {
                Picker("Serviço", selection: $kind) { ForEach(HostKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: kind) {
                    _, k in if !k.defaultHost.isEmpty {
                        host = k.defaultHost
                    }
                }
                TextField("host (ex.: github.com)", text: $host).autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("usuário", text: $login).autocorrectionDisabled().textInputAutocapitalization(.never)
                SecureField("token de acesso pessoal", text: $token)
                Section {
                    Text(kind == .github ?
                        "Crie em github.com → Settings → Developer settings → Tokens, com escopo repo (e workflow para Actions)." :
                        "Token com permissão de leitura e escrita no repositório.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Conta por token")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { adding = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar", action: saveToken).disabled(token.isEmpty || host.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    func saveToken() {
        let t = token.trimmingCharacters(in: .whitespaces)
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        Task {
            var acc = HostAccount(kind: kind, host: h, login: login.isEmpty ? "eu" : login)
            if kind == .github, h == "github.com", let u = try? await GitHubAPI(token: t).user() {
                acc.login = u.login; acc.name = u.name; acc.email = u.email; acc.avatarURL = u.avatarUrl
            }
            do { try accounts.add(acc, token: t); adding = false; token = ""; login = "" } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func startDeviceFlow() {
        let flow = GitHubDeviceFlow()
        waiting = true
        error = nil
        Task {
            do {
                let code = try await flow.requestCode()
                device = code
                let t = try await flow.waitForToken(code)
                let u = try await GitHubAPI(token: t).user()
                try accounts.add(
                    HostAccount(
                        kind: .github,
                        host: "github.com",
                        login: u.login,
                        name: u.name,
                        email: u.email,
                        avatarURL: u.avatarUrl
                    ),
                    token: t
                )
            } catch { self.error = error.localizedDescription }
            device = nil
            waiting = false
        }
    }
}
