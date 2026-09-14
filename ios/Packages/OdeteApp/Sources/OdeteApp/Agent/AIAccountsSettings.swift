import OdeteAgent
import OdeteUI
import SafariServices
import SwiftUI

/// Ajustes → Contas de IA: os cinco tipos, com as três formas de entrar.
struct AIAccountsSettings: View {
    @Environment(AIAccountStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var adding: ProviderKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !store.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Conectadas", detail: "\(store.accounts.count)")
                    CardList {
                        ForEach(Array(store.accounts.enumerated()), id: \.element.id) { i, a in
                            CardRow(
                                a.label + (a.login.isEmpty ? "" : " · \(a.login)"),
                                symbol: a.kind.symbol,
                                color: a.needsReconnect ? theme.danger : theme.accent,
                                detail: a.needsReconnect ? "sessão expirou, reconecte" : a.kind.vendor,
                                first: i == 0
                            ) {
                                if a.needsReconnect {
                                    Button("Reconectar") { adding = a.kind }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                                Button("Remover", systemImage: "trash", role: .destructive) { store.remove(a) }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(store.accounts.isEmpty ? "Conectar uma conta" : "Adicionar")
                CardList {
                    ForEach(Array(ProviderKind.allCases.enumerated()), id: \.element.id) { i, k in
                        Button { adding = k } label: {
                            CardRow(
                                k.label,
                                symbol: k.symbol,
                                color: theme.fgMuted,
                                detail: k.authStyle == .apiKey ? "chave de API" : "assinatura",
                                first: i == 0
                            ) {
                                Image(systemName: "chevron.right").font(.caption2.bold())
                                    .foregroundStyle(theme.fgSubtle)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if store.accounts.isEmpty {
                    CardNote("Entre com a assinatura da Claude, do Codex ou do Grok, ou use uma chave de API.")
                }
            }
        }
        .sheet(item: $adding) { k in
            switch k.authStyle {
            case .oauthPaste: ClaudeConnectSheet()
            case .deviceCode: DeviceCodeSheet(kind: k)
            case .apiKey: ApiKeySheet(kind: k)
            }
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
                        "1. Abra a página da Anthropic e entre com a conta Pro/Max.\n2. Copie o código que aparece no fim.\n3. Cole aqui."
                    )
                    .font(.footnote)
                    Button { openURL(auth.url) } label: { Label("Abrir claude.com", systemImage: "safari") }
                }
                Section("Código") {
                    TextField("cole o código (code#state)", text: $pasted).autocorrectionDisabled()
                        .textInputAutocapitalization(.never).font(.system(
                            .body,
                            design: .monospaced
                        ))
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Conectar Claude")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Conectando…" : "Conectar") { connect() }.disabled(pasted.isEmpty || busy)
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
            VStack(spacing: 16) {
                if let s = start {
                    Text(kind == .grok ? "Na xAI, entre com a conta SuperGrok ou X Premium e digite o código:" :
                        "No ChatGPT, entre e digite o código (ative \"Device code\" em Ajustes → Segurança se pedir):")
                        .font(OdeteFont.ui(13)).foregroundStyle(theme.fgMuted).multilineTextAlignment(.center)
                    Text(s.userCode).font(OdeteFont.mono(30, weight: .medium)).foregroundStyle(theme.fg)
                        .textSelection(.enabled)
                    HStack {
                        Button("Copiar") { UIPasteboard.general.string = s.userCode }.buttonStyle(.glass)
                        Button("Abrir \(s.verificationURL.host() ?? "site")") { openURL(s.verificationURL) }
                            .buttonStyle(.glassProminent)
                    }
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small); Text("aguardando autorização…").font(OdeteFont.ui(11))
                            .foregroundStyle(theme.fgSubtle)
                    }
                } else if error == nil {
                    ProgressView("pedindo código…")
                }
                if let error {
                    Text(error).font(OdeteFont.ui(12)).foregroundStyle(theme.danger)
                        .multilineTextAlignment(.center); Button("Tentar de novo") { begin() }.buttonStyle(.glass)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Conectar \(kind.label)")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { task?.cancel(); dismiss() } }
            }
        }
        .presentationDetents([.medium])
        .onAppear { begin() }
        .onDisappear { task?.cancel() }
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
                    error = "o código expirou; comece de novo"
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

    var body: some View {
        NavigationStack {
            Form {
                TextField("nome (ex.: OpenRouter, Ollama do escritório)", text: $label)
                TextField("URL base", text: $base, prompt: Text(kind.defaultBaseURL)).autocorrectionDisabled()
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                SecureField("chave de API", text: $key)
                Section {
                    Text(kind == .openaiCompat ?
                        "Qualquer API no formato /chat/completions da OpenAI: OpenAI, OpenRouter, Groq, Together, Ollama, LM Studio…" :
                        "Qualquer API no formato /v1/messages da Anthropic. Para a Anthropic oficial use a URL padrão.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle(kind.label)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") { save() }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
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
