import OdeteAgent
import OdeteCore
import OdeteI18n
import OdeteUI
import PhotosUI
import SwiftUI

/// Caixa de texto do agente: anexos, @arquivos, /skills, modo, permissão, enviar/parar.
/// Tudo mora numa cápsula de vidro só, com uma única ação preenchida — o enviar —
/// como nas barras flutuantes dos apps da Apple.
struct Composer: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @Bindable var agent: AgentModel
    @State private var focused = false
    @State private var photo: PhotosPickerItem?
    @State private var contexto = false
    @State private var janela = false
    @State private var modelos = false
    @State private var ditado = Dictation()

    var vazio: Bool {
        agent.draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            if let menu = menuState {
                MentionMenu(
                    kind: menu.kind,
                    query: menu.query,
                    files: ws.filePaths,
                    skills: Skills.all(host: agent.host)
                ) { pick($0, menu) }
            }
            if !agent.attachments.isEmpty {
                anexos
            }
            caixa
        }
        .padding(.top, Metrics.s2)
        .sheet(isPresented: $contexto) {
            ContextSheet(agent: agent, photo: $photo, temPreview: ws.preview.url != nil)
        }
        .onChange(of: ditado.texto) { _, t in agent.draft = t }
        .alert(tr("Ditado"), isPresented: Binding(
            get: { ditado.error != nil },
            set: {
                if !$0 {
                    ditado.error = nil
                }
            }
        )) {
            Button(tr("OK")) { ditado.error = nil }
        } message: { Text(ditado.error ?? "") }
        .onChange(of: agent.focusRequest) { focused = true }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: d)
                {
                    agent.attach(img)
                }; photo = nil
            }
        }
    }

    var anexos: some View {
        ScrollPane(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(agent.attachments.indices, id: \.self) { i in
                    ZStack(alignment: .topTrailing) {
                        if let d = Data(base64Encoded: agent.attachments[i].data), let ui = UIImage(data: d) {
                            Image(uiImage: ui).resizable().scaledToFill().frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        Button { agent.attachments.remove(at: i) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(
                                .white,
                                .black.opacity(0.6)
                            )
                        }
                        .buttonStyle(.plain).offset(x: 5, y: -5)
                        .accessibilityLabel(tr("Remover anexo"))
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
        }
    }

    var caixa: some View {
        VStack(alignment: .leading, spacing: 6) {
            GrowingTextView(
                text: $agent.draft,
                placeholder: agent.running ? tr("redirecionar o agente…") : tr("Peça algo à Odete…"),
                minHeight: 22,
                maxHeight: 220,
                focusRequest: agent.focusRequest,
                focused: $focused,
                onSend: { send() },
                onEscape: {
                    if agent.running {
                        agent.stop()
                    }
                }
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            // Numa coluna estreita o modo abre mão do rótulo antes que o nome do modelo
            // vire reticências.
            ViewThatFits(in: .horizontal) {
                controles(modoComTexto: true)
                controles(modoComTexto: false)
            }
        }
        .padding(8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(theme.accent.opacity(focused ? 0.5 : 0), lineWidth: 1))
        .padding(.horizontal, 12)
    }

    /// Uma linha só: anexar, ditar, modo, e no canto o modelo, o contexto e o enviar.
    func controles(modoComTexto: Bool) -> some View {
        HStack(spacing: 3) {
            iconeBotao("plus", label: tr("Contexto")) { contexto = true }
            iconeBotao(
                ditado.running ? "mic.fill" : "mic",
                label: ditado.running ? "Parar ditado" : "Ditar",
                cor: ditado.running ? theme.accent : theme.fgMuted
            ) { ditado.toggle(atual: agent.draft) }
            modoMenu(comTexto: modoComTexto)
            Spacer(minLength: 6)
            // Sem prioridade o espaçador come a largura do nome e sobra só "…". Na versão
            // apertada o esforço também sai: ele está a um toque, no mesmo popover.
            modeloMenu(comEsforco: modoComTexto).layoutPriority(1)
            anelContexto
            enviar
        }
    }

    var fracaoContexto: Double {
        let usado = max(agent.thread.lastInput, agent.estimatedTokens)
        return min(1, Double(usado) / Double(max(1, agent.contextWindow)))
    }

    /// Anel do contexto sem percentual escrito: o número não cabe na mesma linha dos
    /// controles, e o detalhe está a um toque.
    var anelContexto: some View {
        Button { janela = true } label: {
            ContextGauge(fracao: fracaoContexto, mostrarTexto: false)
                .frame(width: 24, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("Janela de contexto"))
        .popover(isPresented: $janela) {
            ContextPopover(agent: agent).presentationCompactAdaptation(.popover)
        }
    }

    func iconeBotao(
        _ symbol: String,
        label: String,
        cor: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(cor ?? theme.fgMuted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    func modoMenu(comTexto: Bool) -> some View {
        Menu {
            Picker(tr("Modo"), selection: Binding(get: { agent.mode }, set: { agent.setMode($0) })) {
                ForEach(AgentMode.allCases) { m in Label(m.label, systemImage: simbolo(m)).tag(m) }
            }
        } label: {
            capsula(
                comTexto ? agent.mode.label : nil,
                symbol: simbolo(agent.mode),
                destacada: agent.mode == .build
            )
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Modo: \(agent.mode.label)")
    }

    /// Modelo e esforço no canto. Popover de cartões e não menu do sistema: aberto de
    /// baixo para cima o menu inverte a ordem dos itens e fica ilegível.
    func modeloMenu(comEsforco: Bool) -> some View {
        Button { modelos = true } label: {
            HStack(spacing: 4) {
                Text(nomeModelo).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.tail)
                if comEsforco, !agent.effortOptions.isEmpty, let e = Effort.labels[agent.effort] {
                    Text(e).font(.caption2).foregroundStyle(theme.fgSubtle).fixedSize()
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
            }
            .foregroundStyle(theme.fgMuted)
            .padding(.horizontal, 2)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Modelo: \(nomeModelo)")
        .popover(isPresented: $modelos) {
            ModeloPopover(agent: agent) { modelos = false }
        }
    }

    /// Nome curto: na barra cabe o essencial, o resto está no menu.
    var nomeModelo: String {
        guard agent.account != nil else { return tr("conectar") }
        let cheio = agent.models.first { $0.id == agent.model }?.label ?? agent.model
        let primeiro = cheio.split(separator: "·").first.map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? cheio
        return primeiro.isEmpty ? "modelo" : primeiro
    }

    /// Cápsula de filtro do iOS: fundo tênue quando neutra, tinta de destaque quando ligada.
    func capsula(_ text: String?, symbol: String, destacada: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            if let text {
                Text(text).font(.caption.weight(.medium)).fixedSize()
            }
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
        }
        .foregroundStyle(destacada ? theme.accent : theme.fgMuted)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            destacada ? theme.accent.opacity(0.12) : theme.fg.opacity(0.06),
            in: Capsule()
        )
        .contentShape(Capsule())
    }

    /// A única ação preenchida da tela.
    @ViewBuilder var enviar: some View {
        if agent.running, vazio {
            Button { agent.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(theme.danger, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Parar"))
        } else {
            Button { send() } label: {
                Image(systemName: agent.running ? "arrow.triangle.turn.up.right" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(vazio ? theme.fgSubtle : theme.accentFg)
                    .frame(width: 28, height: 28)
                    .background(vazio ? theme.fg.opacity(0.08) : theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(vazio)
            .accessibilityLabel(agent.running ? "Redirecionar" : "Enviar")
        }
    }

    func simbolo(_ m: AgentMode) -> String {
        switch m {
        case .chat: "bubble.left"
        case .plan: "list.bullet.clipboard"
        case .build: "hammer"
        }
    }

    func send() {
        agent.send()
        agent.focusRequest += 1
    }

    struct MenuState { let kind: MentionMenu.Kind; let query: String; let range: Range<String.Index> }

    /// Último `@x` ou `/x` sendo digitado no fim do texto.
    var menuState: MenuState? {
        let t = agent.draft
        guard let m = t.range(of: #"(?:^|\s)([@/])([\w./-]*)$"#, options: .regularExpression) else { return nil }
        var token = String(t[m])
        if token.first == " " || token.first == "\n" {
            token.removeFirst()
        }
        let kind: MentionMenu.Kind = token.hasPrefix("@") ? .file : .skill
        let start = t.index(m.upperBound, offsetBy: -token.count)
        return MenuState(kind: kind, query: String(token.dropFirst()), range: start ..< m.upperBound)
    }

    func pick(_ value: String, _ m: MenuState) {
        agent.draft.replaceSubrange(m.range, with: (m.kind == .file ? "@" : "/") + value + " ")
    }
}

/// Lista flutuante de arquivos ou skills enquanto se digita `@` ou `/`.
struct MentionMenu: View {
    enum Kind { case file, skill }
    @Environment(\.theme) private var theme
    let kind: Kind
    let query: String
    let files: [String]
    let skills: [Skill]
    let pick: (String) -> Void

    var options: [(String, String)] {
        let q = query.lowercased()
        switch kind {
        case .file: return files.filter { q.isEmpty || $0.lowercased().contains(q) }.sorted { (
                $0.lowercased().hasPrefix(q) ? 0 : 1,
                $0.count
            ) < ($1.lowercased().hasPrefix(q) ? 0 : 1, $1.count) }.prefix(8).map { ($0, "") }
        case .skill: return skills.filter { q.isEmpty || $0.id.contains(q) }.prefix(8).map { ($0.id, $0.description) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.0) { i, o in
                Button { pick(o.0) } label: {
                    HStack(spacing: 9) {
                        if kind == .file {
                            FileGlyph(path: o.0, size: 13)
                        } else {
                            Image(systemName: "slash.circle").font(.system(size: 12)).foregroundStyle(theme.accent)
                        }
                        Text((kind == .file ? "" : "/") + o.0).font(.footnote).foregroundStyle(theme.fg)
                            .lineLimit(1).truncationMode(.middle)
                        if !o.1.isEmpty {
                            Text(o.1).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).frame(height: 38).contentShape(Rectangle())
                    .overlay(alignment: .top) {
                        if i > 0 {
                            Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 33)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if options.isEmpty {
                Text(kind == .file ? tr("nenhum arquivo") : tr("nenhuma skill")).font(.footnote)
                    .foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 38)
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
    }
}

/// Lista de modelos e níveis de esforço, no formato dos cartões do app.
struct ModeloPopover: View {
    @Environment(\.theme) private var theme
    let agent: AgentModel
    var fechar: () -> Void

    var body: some View {
        ScrollPane {
            VStack(alignment: .leading, spacing: 14) {
                if let acc = agent.account {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(tr("Modelo"), detail: acc.kind.label) {
                            Button(tr("Recarregar"), systemImage: "arrow.clockwise") {
                                Task { await agent.loadModels() }
                            }
                        }
                        CardList {
                            if agent.models.isEmpty {
                                Button { agent.setModel(acc.kind.defaultModel); fechar() } label: {
                                    linha(acc.kind.defaultModel, escolhido: true, first: true, kind: acc.kind)
                                }
                                .buttonStyle(.plain)
                            }
                            ForEach(Array(agent.models.enumerated()), id: \.element.id) { i, m in
                                Button { agent.setModel(m.id); fechar() } label: {
                                    linha(m.label, escolhido: m.id == agent.model, first: i == 0, kind: acc.kind)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if agent.loadingModels {
                            CardNote(tr("carregando a lista…"))
                        }
                    }
                } else {
                    CardNote(tr("Conecte uma conta para escolher o modelo."))
                }
                if !agent.effortOptions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(tr("Esforço"))
                        CardList {
                            ForEach(Array(agent.effortOptions.enumerated()), id: \.element) { i, e in
                                Button { agent.setEffort(e); fechar() } label: {
                                    linha(
                                        Effort.labels[e] ?? e,
                                        escolhido: e == agent.effort,
                                        first: i == 0,
                                        kind: nil
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(idealWidth: 260, idealHeight: altura)
        .background(theme.bg)
    }

    var altura: CGFloat {
        let modelos = max(agent.models.count, 1)
        let esforcos = agent.effortOptions.count
        return 28 + 32 + CGFloat(modelos) * 44 + (esforcos == 0 ? 0 : 14 + 32 + CGFloat(esforcos) * 44)
    }

    func linha(_ texto: String, escolhido: Bool, first: Bool, kind: ProviderKind?) -> some View {
        HStack(spacing: 10) {
            if let kind {
                Marca(kind: kind, lado: 22, glifo: 11, apagada: false)
            }
            Text(texto).font(.subheadline).foregroundStyle(theme.fg).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if escolhido {
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(theme.accent)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if !first {
                Rectangle().fill(theme.separator).frame(height: 0.5)
                    .padding(.leading, kind == nil ? 12 : 44)
            }
        }
    }
}
