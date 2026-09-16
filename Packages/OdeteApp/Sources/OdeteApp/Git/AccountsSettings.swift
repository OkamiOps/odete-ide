import OdeteAccounts
import OdeteCore
import OdeteI18n
import OdeteUI
import SwiftUI

/// Ajustes → Contas: GitHub por device flow ou token; outros hosts por token.
///
/// A tela era três títulos de seção empilhados no vazio: uma frase cinza onde deveria
/// estar a conta, a ação principal disfarçada de linha de lista e dois campos de autor
/// com o texto encostado na direita, sem dizer o que sairia gravado. Aqui o topo diz
/// para que serve a tela, a ação principal é um botão, a conta conectada aparece com
/// rosto e host, e o autor mostra a assinatura pronta — inclusive o que a Odete deduz
/// quando os campos estão vazios.
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
    @State private var removendo: HostAccount?

    var temDeviceFlow: Bool {
        GitHubDeviceFlow().isConfigured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            cabecalho
            if let d = device {
                codigo(d)
            }
            if accounts.accounts.isEmpty {
                vazio
            } else {
                lista
            }
            if let error {
                CardNote(error)
            }
            autor
        }
        .sheet(isPresented: $adding) { tokenSheet }
        .confirmationDialog(
            tr("Remover %1$@?", "\(removendo?.login ?? "")"),
            isPresented: Binding(get: { removendo != nil }, set: {
                if !$0 {
                    removendo = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button(tr("Remover"), role: .destructive) {
                if let a = removendo {
                    accounts.remove(a)
                }
                removendo = nil
            }
            Button(tr("Cancelar"), role: .cancel) { removendo = nil }
        } message: {
            Text(tr("O token sai do Keychain. Push e clone de repositório privado param de funcionar."))
        }
    }

    // MARK: topo

    var cabecalho: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.accent.opacity(0.14)).frame(width: 44, height: 44)
                Ratinha(size: 24).foregroundStyle(theme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("Contas de código")).font(.headline).foregroundStyle(theme.fg)
                Text(
                    tr(
                        "Uma conta conectada libera push, clone de repositório privado e os pull requests dentro da Odete. O token fica no Keychain do iPad."
                    )
                )
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// O código do device flow, enquanto o GitHub espera a autorização.
    func codigo(_ d: GitHubDeviceFlow.DeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("No GitHub, digite este código:")).font(.footnote).foregroundStyle(theme.fgMuted)
            HStack(spacing: 12) {
                Text(d.userCode)
                    .font(OdeteFont.mono(24, weight: .medium)).foregroundStyle(theme.fg)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button(tr("Copiar")) { UIPasteboard.general.string = d.userCode }.buttonStyle(.glass)
                Button(tr("Abrir GitHub")) { openURL(URL(string: d.verificationUri)!) }.buttonStyle(.glassProminent)
            }
            if waiting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("esperando você autorizar…")).font(.caption).foregroundStyle(theme.fgSubtle)
                }
            }
        }
        .padding(14)
        .background(theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.accent))
    }

    // MARK: sem conta

    var vazio: some View {
        VStack(alignment: .leading, spacing: 10) {
            if temDeviceFlow {
                principal(tr("Entrar com GitHub"), acao: startDeviceFlow)
                secundaria("Adicionar por token", detalhe: tr("GitHub, GitLab, Gitea ou qualquer host"))
            } else {
                principal(tr("Adicionar conta por token")) { adding = true }
                Text(tr("GitHub, GitLab, Gitea ou qualquer host que aceite token de acesso pessoal."))
                    .font(.caption).foregroundStyle(theme.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func principal(_ titulo: String, acao: @escaping () -> Void) -> some View {
        Button(action: acao) {
            HStack(spacing: 8) {
                if waiting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "person.badge.key").font(.system(size: 13, weight: .bold))
                }
                Text(waiting ? tr("Esperando o GitHub…") : titulo)
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(theme.accentFg)
            // Numa folha estreita ela ocupa a linha; num painel de ajustes largo, uma
            // barra laranja de ponta a ponta viraria o assunto da tela.
            .frame(maxWidth: 360).frame(height: 42)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(waiting)
        .hoverEffect(.highlight)
    }

    func secundaria(_ titulo: String, detalhe: String) -> some View {
        CardList {
            Button { adding = true } label: {
                CardRow(titulo, symbol: "key", color: theme.fgMuted, detail: detalhe, first: true) {
                    Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(theme.fgSubtle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: com conta

    var lista: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(tr("Conectadas"), detail: "\(accounts.accounts.count)")
            CardList {
                ForEach(Array(accounts.accounts.enumerated()), id: \.element.id) { i, a in
                    linha(a, first: i == 0)
                }
            }
            Button { adding = true } label: {
                Label(tr("Adicionar outra conta"), systemImage: "plus")
                    .font(.subheadline).foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            if temDeviceFlow, accounts.github == nil {
                Button(tr("Entrar com GitHub"), action: startDeviceFlow)
                    .font(.subheadline).foregroundStyle(theme.accent)
                    .buttonStyle(.plain)
            }
        }
    }

    func linha(_ a: HostAccount, first: Bool) -> some View {
        HStack(spacing: 11) {
            rosto(a)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name ?? a.login).font(.subheadline.weight(.medium)).foregroundStyle(theme.fg)
                    .lineLimit(1)
                Text(a.name == nil ? a.host : "\(a.login) · \(a.host)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Menu {
                // O endereço inteiro no rótulo quebrava o item do menu em três linhas; ele
                // aparece por extenso na prévia da assinatura, logo abaixo.
                if let e = a.email {
                    Button(tr("Assinar commits com este e-mail"), systemImage: "envelope") { accounts.authorEmail = e }
                }
                Button(tr("Remover conta"), systemImage: "trash", role: .destructive) { removendo = a }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.fgMuted)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .accessibilityLabel(tr("Ações da conta %1$@", "\(a.login)"))
        }
        .padding(.horizontal, 12).frame(height: 56)
        .overlay(alignment: .top) {
            if !first {
                Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 55)
            }
        }
    }

    /// Foto da conta quando o host manda uma; senão, a inicial num quadrado.
    func rosto(_ a: HostAccount) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.accent.opacity(0.18))
            if let s = a.avatarURL, let u = URL(string: s) {
                AsyncImage(url: u) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    inicial(a)
                }
            } else {
                inicial(a)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    func inicial(_ a: HostAccount) -> some View {
        Text(a.login.prefix(1).uppercased())
            .font(.headline).foregroundStyle(theme.accent)
    }

    // MARK: autor

    var autor: some View {
        @Bindable var accounts = accounts
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle(tr("Autor dos commits"))
            CardList {
                CardRow(tr("Nome"), symbol: "person", color: .gray, first: true) {
                    TextField(assinatura.name, text: $accounts.authorName)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .frame(maxWidth: 220)
                }
                CardRow("E-mail", symbol: "envelope", color: .gray) {
                    TextField(assinatura.email, text: $accounts.authorEmail)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(maxWidth: 220)
                }
            }
            // Os campos vazios não significam "sem autor": a Odete deduz um. Melhor
            // mostrar a linha pronta do que deixar a pessoa descobrir no primeiro commit.
            VStack(alignment: .leading, spacing: 3) {
                Text(deduzida
                    ? tr("Sem preencher, a Odete deduz e cada commit vai assinado assim:")
                    : tr("Cada commit feito daqui vai assinado assim:"))
                    .font(.caption).foregroundStyle(theme.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(assinatura.name) <\(assinatura.email)>")
                    .font(OdeteFont.mono(11)).foregroundStyle(theme.fgMuted)
                    .textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    var assinatura: (name: String, email: String) {
        accounts.autor
    }

    var deduzida: Bool {
        accounts.authorName.isEmpty || accounts.authorEmail.isEmpty
    }

    // MARK: token

    var tokenSheet: some View {
        NavigationStack {
            Form {
                Picker(tr("Serviço"), selection: $kind) {
                    ForEach(HostKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: kind) { _, k in
                    if !k.defaultHost.isEmpty {
                        host = k.defaultHost
                    }
                }
                TextField(tr("host (ex.: github.com)"), text: $host).autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField(tr("usuário"), text: $login).autocorrectionDisabled().textInputAutocapitalization(.never)
                SecureField(tr("token de acesso pessoal"), text: $token)
                Section {
                    Text(kind == .github
                        ?
                        tr(
                            "Crie em github.com → Settings → Developer settings → Tokens, com escopo repo (e workflow para Actions)."
                        )
                        : tr("Token com permissão de leitura e escrita no repositório."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(tr("Conta por token"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Cancelar")) { adding = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Salvar"), action: saveToken).disabled(token.isEmpty || host.isEmpty)
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
                acc.login = u.login
                acc.name = u.name
                acc.email = u.email
                acc.avatarURL = u.avatarUrl
            }
            do {
                try accounts.add(acc, token: t)
                adding = false
                token = ""
                login = ""
            } catch {
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
