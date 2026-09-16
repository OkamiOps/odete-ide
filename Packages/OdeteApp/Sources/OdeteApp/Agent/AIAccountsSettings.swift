import OdeteAgent
import OdeteI18n
import OdeteUI
import SafariServices
import SwiftUI

/// Ajustes → Contas de IA: os cinco tipos, com as três formas de entrar.
struct AIAccountsSettings: View {
    @Environment(AIAccountStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var adding: ProviderKind?
    @State private var recado: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if store.accounts.isEmpty {
                vazio
            } else {
                conectadas
            }
            adicionar
        }
        .sheet(item: $adding) { k in
            switch k.authStyle {
            case .oauthPaste: ClaudeConnectSheet()
            case .deviceCode: DeviceCodeSheet(kind: k)
            case .apiKey: ApiKeySheet(kind: k)
            case .builtIn: EmptyView()
            }
        }
        .alert(tr("Apple Intelligence"), isPresented: Binding(
            get: { recado != nil },
            set: {
                if !$0 {
                    recado = nil
                }
            }
        )) {
            Button(tr("OK")) { recado = nil }
        } message: { Text(recado ?? "") }
    }

    /// Sem nenhuma conta a tela não pode ser uma lista vazia com um título.
    var vazio: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Nenhuma conta ainda")).font(.title3.weight(.semibold)).foregroundStyle(theme.fg)
            Text(tr("Escolha abaixo por onde entrar. O modelo da Apple não pede conta nenhuma."))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    /// Linha alta, com o ícone grande o bastante para identificar de relance.
    var conectadas: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(tr("Conectadas"), detail: "\(store.accounts.count)")
            CardList {
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { i, a in
                    HStack(spacing: 12) {
                        Marca(kind: a.kind, lado: 34, glifo: 15, apagada: a.needsReconnect)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.label).font(.body).foregroundStyle(theme.fg).lineLimit(1)
                            Text(a.needsReconnect ? tr("a sessão expirou")
                                : (a.login.isEmpty ? a.kind.vendor : a.login))
                                .font(.caption)
                                .foregroundStyle(a.needsReconnect ? theme.danger : .secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        if a.needsReconnect {
                            Button(tr("Reconectar")) { adding = a.kind }
                                .buttonStyle(.glass).controlSize(.small)
                        }
                        Menu {
                            if a.needsReconnect {
                                Button(tr("Reconectar"), systemImage: "arrow.clockwise") { adding = a.kind }
                            }
                            Button(tr("Remover"), systemImage: "trash", role: .destructive) { store.remove(a) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.fgSubtle)
                                .frame(width: 34, height: 34)
                                .contentShape(Rectangle())
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .accessibilityLabel(tr("Opções de %1$@", "\(a.label)"))
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 6)
                    .frame(height: 60)
                    .overlay(alignment: .top) {
                        if i > 0 {
                            Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 58)
                        }
                    }
                }
            }
        }
    }

    /// Assinatura em ladrilho grande, que é o caminho principal; chave de API em linha,
    /// que é o caminho de quem já sabe o que quer. Repetir "assinatura" cinco vezes numa
    /// lista igual não dizia nada.
    var adicionar: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(tr("Adicionar"))
            if faltando.contains(.apple) {
                Button { escolher(.apple) } label: { appleCard }.buttonStyle(.plain)
            }
            let assinaturas = faltando.filter { $0.authStyle == .oauthPaste || $0.authStyle == .deviceCode }
            if !assinaturas.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                    ForEach(assinaturas) { k in
                        Button { escolher(k) } label: { ladrilho(k) }.buttonStyle(.plain)
                    }
                }
            }
            let chaves = faltando.filter { $0.authStyle == .apiKey }
            if !chaves.isEmpty {
                CardList {
                    ForEach(Array(chaves.enumerated()), id: \.element.id) { i, k in
                        Button { escolher(k) } label: {
                            CardRow(k.label, symbol: k.symbol, color: ProviderCor.de(k), first: i == 0) {
                                Image(systemName: "chevron.right").font(.caption2.bold())
                                    .foregroundStyle(theme.fgSubtle)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// O modelo do sistema tem cartão próprio: é o único que não custa nada e é por onde
    /// quem não assina nada consegue começar.
    var appleCard: some View {
        let impedimento = AppleProvider.impedimento
        return HStack(spacing: 12) {
            Marca(kind: .apple, lado: 40, glifo: 18, apagada: impedimento != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Apple Intelligence")).font(.body.weight(.medium)).foregroundStyle(theme.fg)
                Text(impedimento ?? tr("Roda no próprio iPad, sem conta e sem rede."))
                    .font(.caption).foregroundStyle(impedimento == nil ? .secondary : Color(theme.danger))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if impedimento == nil {
                Text(tr("Usar")).font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(theme.accent, in: Capsule())
                    .foregroundStyle(theme.accentFg)
            }
        }
        .padding(12)
        .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(theme.accent.opacity(impedimento == nil ? 0.45 : 0), lineWidth: 1))
        .contentShape(Rectangle())
    }

    func ladrilho(_ k: ProviderKind) -> some View {
        VStack(spacing: 8) {
            Marca(kind: k, lado: 40, glifo: 18, apagada: false)
            VStack(spacing: 1) {
                Text(k.label).font(.subheadline.weight(.medium)).foregroundStyle(theme.fg).lineLimit(1)
                Text(tr("assinatura")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 104)
        .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Só o que ainda não foi conectado. O modelo do sistema entra uma vez só.
    var faltando: [ProviderKind] {
        ProviderKind.allCases.filter { k in k != .apple || !store.accounts.contains { $0.kind == .apple } }
    }

    func escolher(_ k: ProviderKind) {
        guard k == .apple else {
            adding = k
            return
        }
        if let impedimento = AppleProvider.impedimento {
            recado = impedimento
        } else {
            store.addBuiltIn(AIAccount(kind: .apple))
        }
    }
}

struct ClaudeConnectSheet: View {
    @Environment(AIAccountStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var auth = ClaudeAuth().authorize()
    @State private var pasted = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        tr(
                            "1. Abra a página da Anthropic e entre com a conta Pro/Max.\n2. Copie o código que aparece no fim.\n3. Cole aqui."
                        )
                    )
                    .font(.footnote)
                    Button { openURL(auth.url) } label: { Label(tr("Abrir claude.com"), systemImage: "safari") }
                }
                Section(tr("Código")) {
                    TextField(tr("cole o código (code#state)"), text: $pasted).autocorrectionDisabled()
                        .textInputAutocapitalization(.never).font(.system(
                            .body,
                            design: .monospaced
                        ))
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle(tr("Conectar Claude"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Cancelar")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? tr("Conectando…") : tr("Conectar")) { connect() }.disabled(pasted.isEmpty || busy)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    func connect() {
        let (code, state) = ClaudeAuth.parseCode(pasted)
        busy = true
        error = nil
        Task {
            do {
                let t = try await ClaudeAuth().exchange(
                    code: code,
                    state: state.isEmpty ? auth.state : state,
                    verifier: auth.verifier
                )
                let existing = store.accounts(of: .claude).first
                try store.add(existing ?? AIAccount(kind: .claude, login: ""), tokens: t)
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct DeviceCodeSheet: View {
    @Environment(AIAccountStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme
    let kind: ProviderKind
    @State private var start: DeviceStart?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var auth: any DeviceAuth {
        kind == .grok ? GrokDeviceAuth() : OpenAIDeviceAuth()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Cabecalho(
                    kind: kind,
                    titulo: tr("Conectar %1$@", "\(kind.label)"),
                    texto: kind == .grok
                        ? tr("Entre na xAI com a conta SuperGrok ou X Premium e digite o código.")
                        :
                        tr(
                            "Entre no ChatGPT e digite o código. Se pedir, ligue \"Device code\" em Ajustes → Segurança."
                        )
                )
                if let s = start {
                    codigo(s.userCode)
                    Button(tr("Abrir %1$@", "\(s.verificationURL.host() ?? "site")")) { openURL(s.verificationURL) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text(tr("aguardando você autorizar…")).font(.footnote).foregroundStyle(.secondary)
                    }
                } else if error == nil {
                    Spacer(minLength: 0)
                    ProgressView(tr("pedindo o código…")).font(.footnote)
                    Spacer(minLength: 0)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(theme.danger)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button(tr("Tentar de novo")) { begin() }.buttonStyle(.glass)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.bg)
            .navigationTitle(tr("Nova conta"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancelar")) { task?.cancel(); dismiss() }
                }
            }
        }
        .presentationSizing(.form)
        .onAppear { begin() }
        .onDisappear { task?.cancel() }
    }

    /// O código é a única coisa que a pessoa precisa ler e copiar, então ele é o bloco
    /// principal da tela, com o botão de copiar do lado e não escondido embaixo.
    func codigo(_ texto: String) -> some View {
        HStack(spacing: 12) {
            Text(texto)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(theme.fg)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
            Button {
                UIPasteboard.general.string = texto
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Copiar código"))
        }
        .padding(.horizontal, 10).padding(.vertical, 14)
        .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    func begin() {
        error = nil
        start = nil
        task?.cancel()
        task = Task {
            do {
                let s = try await auth.start()
                start = s
                var interval = s.interval
                let deadline = Date(timeIntervalSinceNow: Double(s.expiresIn))
                while !Task.isCancelled, Date() < deadline {
                    try await Task.sleep(for: .seconds(interval))
                    switch try await auth.poll(s) {
                    case .pending: continue
                    case .slowDown: interval += 5
                    case let .tokens(t):
                        let existing = store.accounts(of: kind).first
                        try store.add(existing ?? AIAccount(kind: kind, login: t.accountId ?? ""), tokens: t)
                        dismiss()
                        return
                    }
                }
                if !Task.isCancelled {
                    error = tr("o código expirou; comece de novo")
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct ApiKeySheet: View {
    @Environment(AIAccountStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let kind: ProviderKind
    @State private var label = ""
    @State private var base = ""
    @State private var key = ""
    @State private var error: String?

    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            ScrollPane {
                VStack(alignment: .leading, spacing: 16) {
                    Cabecalho(kind: kind, titulo: kind.label, texto: tr("Endereço e chave do serviço."))
                    CardList {
                        campo("Nome", dica: tr("opcional, ex.: OpenRouter"), texto: $label, first: true)
                        campo("URL base", dica: kind.defaultBaseURL, texto: $base, url: true)
                        chave
                    }
                    CardNote(kind == .openaiCompat
                        ? tr("Vale qualquer API no formato /chat/completions da OpenAI: OpenAI, OpenRouter, Groq, ")
                        + "Together, Ollama, LM Studio."
                        :
                        tr(
                            "Vale qualquer API no formato /v1/messages da Anthropic. Para a Anthropic oficial, deixe a URL padrão."
                        ))
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                    }
                }
                .padding(16)
            }
            .background(theme.bg)
            .navigationTitle(tr("Nova conta"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Cancelar")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Salvar")) { save() }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationSizing(.form)
    }

    /// Rótulo em cima, campo embaixo: com o rótulo dentro do campo some quando se digita.
    func campo(_ titulo: String, dica: String, texto: Binding<String>, url: Bool = false, first: Bool = false)
        -> some View
    {
        VStack(alignment: .leading, spacing: 2) {
            Text(titulo).font(.caption).foregroundStyle(.secondary)
            TextField("", text: texto, prompt: Text(dica).foregroundStyle(theme.fgSubtle))
                .font(.body).foregroundStyle(theme.fg)
                .textFieldStyle(.plain)
                .autocorrectionDisabled(url)
                .textInputAutocapitalization(url ? .never : .sentences)
                .keyboardType(url ? .URL : .default)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .overlay(alignment: .top) {
            if !first {
                Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 12)
            }
        }
    }

    var chave: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tr("Chave de API")).font(.caption).foregroundStyle(.secondary)
            SecureField("", text: $key, prompt: Text(tr("cole aqui")).foregroundStyle(theme.fgSubtle))
                .font(.body).foregroundStyle(theme.fg).textFieldStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 12)
        }
    }

    func save() {
        let b = base.trimmingCharacters(in: .whitespaces)
        do {
            try store.add(
                AIAccount(
                    kind: kind,
                    label: label.isEmpty ? nil : label,
                    baseURL: b.isEmpty ? nil : b,
                    login: URL(string: b.isEmpty ? kind.defaultBaseURL : b)?.host() ?? ""
                ),
                apiKey: key.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Quadrado de marca do provedor, no tamanho que a linha pedir.
struct Marca: View {
    @Environment(\.theme) private var theme
    var kind: ProviderKind
    var lado: CGFloat
    var glifo: CGFloat
    var apagada: Bool

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: glifo, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: lado, height: lado)
            .background(
                apagada ? theme.danger : ProviderCor.de(kind),
                in: RoundedRectangle(cornerRadius: lado * 0.28, style: .continuous)
            )
    }
}

/// Abertura das folhas de conexão: marca grande, nome e uma linha do que fazer.
struct Cabecalho: View {
    @Environment(\.theme) private var theme
    var kind: ProviderKind
    var titulo: String
    var texto: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Marca(kind: kind, lado: 44, glifo: 20, apagada: false)
            VStack(alignment: .leading, spacing: 3) {
                Text(titulo).font(.title3.weight(.semibold)).foregroundStyle(theme.fg)
                Text(texto).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
