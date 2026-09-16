import OdeteAgent
import OdeteCore
import OdeteI18n
import OdeteUI
import SwiftUI

/// Coluna do agente (iPad) e aba Agente (iPhone).
struct AgentPane: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var history = false
    @State private var showAccounts = false

    var body: some View {
        let ag = ws.agent!
        VStack(spacing: 0) {
            header(ag)
            ChatList(agent: ag)
            if !ag.pendingPatches.isEmpty {
                patchBar(ag)
            }
            Composer(agent: ag)
        }
        .background(theme.bgElevated)
        .overlay(alignment: .leading) {
            if sizeClass != .compact {
                Rectangle().fill(theme.border).frame(width: 1)
            }
        }
        .sheet(isPresented: $history) { HistorySheet(agent: ag) }
        .sheet(isPresented: $showAccounts) {
            NavigationStack {
                // Fundo mais fundo que os cartões: com `surface` eles somem, porque é a
                // mesma cor de `bgElevated`.
                ScrollPane { AIAccountsSettings().padding(16) }
                    .background(theme.bg)
                    .navigationTitle(tr("Contas de IA"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(tr("Concluído")) { showAccounts = false }
                        }
                    }
            }
            // Tamanho de formulário. `.fitted` não mede uma área de rolagem e a folha
            // colapsava; a altura cheia deixava meia tela vazia.
            .presentationSizing(.form)
        }
        .task { await ag.loadModels() }
    }

    /// Barra do painel no formato das barras de navegação do iPadOS: identidade com
    /// título e subtítulo à esquerda, ações reunidas numa única cápsula de vidro à
    /// direita, em vez de ícones soltos.
    func header(_ ag: AgentModel) -> some View {
        HStack(spacing: 8) {
            // Prioridade para a identidade: sem isto o subtítulo era comido pela
            // cápsula de ações numa coluna de 300 pt.
            ModelMenu(agent: ag, onConnect: { showAccounts = true }).layoutPriority(1)
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                // A contagem em cima do relógio: sem ela o botão parecia desligado, como
                // se não houvesse conversa nenhuma guardada.
                PaneAction("clock.arrow.circlepath", label: tr("Conversas"), conta: ag.threads.count) { history = true }
                PaneAction("arrow.uturn.backward", label: tr("Desfazer último turno")) { _ = ag.undoLastTurn() }
                    .disabled(!ag.canUndoTurn)
                PaneAction("square.and.pencil", label: tr("Nova conversa")) { ag.newChat() }
                    .disabled(ag.thread.isEmpty)
                if sizeClass != .compact {
                    PaneAction("sidebar.trailing", label: tr("Fechar agente")) { chrome.toggleAgent() }
                }
            }
            .padding(.horizontal, 2)
            .glassEffect(.regular, in: Capsule())
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 0.5) }
    }

    /// Numa coluna de 300 pt os dois botões comiam o rótulo e sobrava "1 patch p…".
    /// Como na barra de status, quem decide é o `ViewThatFits`, não um limiar de largura.
    func patchBar(_ ag: AgentModel) -> some View {
        let n = ag.pendingPatches.count
        return ViewThatFits(in: .horizontal) {
            linhaDoPatch(ag, n == 1 ? tr("1 patch pendente") : tr("%1$@ patches pendentes", "\(n)"))
            linhaDoPatch(ag, n == 1 ? "1 pendente" : "\(n) pendentes")
            linhaDoPatch(ag, "\(n)")
        }
        .controlSize(.small)
        .padding(.horizontal, 12).frame(height: 48)
        .background(theme.bg)
        .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 0.5) }
    }

    func linhaDoPatch(_ ag: AgentModel, _ texto: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.gearshape").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text(texto).font(.subheadline).foregroundStyle(theme.fg).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            Button(tr("Rejeitar")) { ag.rejectAll() }.buttonStyle(.glass).fixedSize()
            Button(tr("Aceitar")) { ag.acceptAll() }.buttonStyle(.glassProminent).fixedSize()
        }
    }
}

/// Ícone de ação do cabeçalho. Um pouco mais estreito que o `HeaderButton` dos outros
/// painéis para caber quatro deles na coluna mínima de 300 pt sem comer o título.
struct PaneAction: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    var symbol: String
    var label: String
    /// Número no canto do ícone. Zero não desenha nada.
    var conta = 0
    var action: () -> Void

    init(_ symbol: String, label: String, conta: Int = 0, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.conta = conta
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                // Ligado é o texto normal, não o cinza apagado: com `fgMuted` todo botão
                // parecia desabilitado, e o desabilitado de verdade não se distinguia.
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(enabled ? theme.fg.opacity(0.9) : theme.fgSubtle.opacity(0.4))
                .frame(width: 30, height: 30)
                .overlay(alignment: .topTrailing) {
                    if conta > 1, enabled {
                        Text("\(min(conta, 99))")
                            .font(.system(size: 8.5, weight: .bold)).monospacedDigit()
                            .foregroundStyle(theme.accentFg)
                            .padding(.horizontal, 3).frame(minWidth: 13, minHeight: 13)
                            .background(theme.accent, in: Capsule())
                            .offset(x: 2, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(conta > 1 ? "\(label), \(conta)" : label)
        .help(label)
    }
}

func fmtTok(_ n: Int) -> String {
    if n >= 1_000_000 {
        return String(format: n % 1_000_000 == 0 ? "%.0fM" : "%.1fM", Double(n) / 1_000_000)
    }
    if n >= 10000 {
        return "\(n / 1000)k"
    }
    if n >= 1000 {
        return String(format: "%.1fk", Double(n) / 1000).replacingOccurrences(of: ".0k", with: "k")
    }
    return String(n)
}

/// Identidade do painel: só a conta. Modelo e esforço moraram aqui por um tempo, mas
/// pertencem à barra de digitação, junto do que a pessoa está escrevendo.
struct ModelMenu: View {
    @Environment(\.theme) private var theme
    let agent: AgentModel
    let onConnect: () -> Void

    @State private var aberto = false

    var body: some View {
        Button { aberto = true } label: { label }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Conta"))
            .popover(isPresented: $aberto, arrowEdge: .bottom) {
                ContasPopover(
                    agent: agent,
                    escolher: { agent.setAccount($0); aberto = false },
                    gerenciar: { aberto = false; onConnect() }
                )
            }
    }

    var label: some View {
        HStack(spacing: 7) {
            Image(systemName: agent.account?.kind.symbol ?? "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(agent.account == nil ? theme.fgSubtle : theme.accent)
                .frame(width: 24, height: 24)
                .background(
                    agent.account == nil ? theme.fg.opacity(0.06) : theme.accent.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(agent.account?.label ?? tr("Sem conta"))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(theme.fg).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.fgSubtle)
                }
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.85)
            }
        }
        .contentShape(Rectangle())
    }

    var subtitle: String {
        guard let a = agent.account else { return tr("conectar") }
        return a.login.isEmpty ? a.kind.vendor : a.login
    }
}

/// Lista de contas no formato dos cartões do resto do app, no lugar do menu do sistema,
/// onde o e-mail quebrava no meio e o ícone do Grok parecia um erro.
struct ContasPopover: View {
    @Environment(\.theme) private var theme
    let agent: AgentModel
    var escolher: (AIAccount) -> Void
    var gerenciar: () -> Void

    var body: some View {
        ScrollPane {
            VStack(alignment: .leading, spacing: 14) {
                if agent.accounts.accounts.isEmpty {
                    CardNote(tr("Nenhuma conta ainda. O modelo da Apple não pede conta nenhuma."))
                } else {
                    SectionTitle(tr("Contas"))
                    CardList {
                        ForEach(Array(agent.accounts.accounts.enumerated()), id: \.element.id) { i, a in
                            Button { escolher(a) } label: {
                                CardRow(
                                    a.label,
                                    symbol: a.kind.symbol,
                                    color: a.needsReconnect ? theme.danger : ProviderCor.de(a.kind),
                                    detail: a.needsReconnect ? tr("sessão expirou, reconecte")
                                        : (a.login.isEmpty ? a.kind.vendor : a.login),
                                    first: i == 0
                                ) {
                                    if a.id == agent.account?.id {
                                        Image(systemName: "checkmark").font(.caption.bold())
                                            .foregroundStyle(theme.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                CardList {
                    Button { gerenciar() } label: {
                        CardRow(
                            tr("Contas de IA…"),
                            symbol: "person.crop.circle.badge.plus",
                            color: .indigo,
                            first: true
                        ) {
                            Image(systemName: "chevron.right").font(.caption2.bold())
                                .foregroundStyle(theme.fgSubtle)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        // Medida exata, não ideal: dentro de um popover o conteúdo é um ScrollView, que
        // não tem tamanho próprio. Com `idealWidth`/`idealHeight` o popover abria com
        // altura zero — só a setinha aparecia no topo do painel, e não dava para clicar
        // em nada. Era esse o bug de "clico em Sem conta e não acontece nada".
        .frame(width: 280, height: altura)
        .background(theme.bg)
        // No iPhone o popover vira folha sozinho, e a folha é melhor lá.
        .presentationCompactAdaptation(horizontal: .popover, vertical: .sheet)
    }

    /// Acompanha o número de contas, senão sobra um vazio embaixo — com teto, para uma
    /// lista longa rolar em vez de passar da tela.
    var altura: CGFloat {
        let contas = agent.accounts.accounts.count
        let pedida = 28 + (contas == 0 ? 52 : 32 + CGFloat(contas) * 50) + 14 + 44
        return min(pedida, 460)
    }
}
