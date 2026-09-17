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
    @State private var contas = false

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
        // A lista de contas mora aqui dentro, e não numa apresentação do sistema.
        // Popover e folha decidem sozinhos onde e de que tamanho aparecem, e foi assim
        // que a lista abriu três vezes como uma linha achatada no iPad e uma vez como um
        // cartão perdido no meio da tela. Desenhada no painel, ela fica onde foi posta:
        // debaixo da linha da conta, do tamanho da lista.
        .overlay {
            if contas {
                ContasSobreposto(
                    agent: ag,
                    escolher: { ag.setAccount($0); fechaContas() },
                    gerenciar: { fechaContas(); showAccounts = true },
                    fechar: { fechaContas() }
                )
            }
        }
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
            ModelMenu(agent: ag, aberto: contas, abrir: abreContas).layoutPriority(1)
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

    func abreContas() {
        withAnimation(.snappy(duration: 0.2)) { contas = true }
    }

    func fechaContas() {
        withAnimation(.snappy(duration: 0.16)) { contas = false }
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
    /// Só para virar a seta. Quem guarda o estado é o painel, que é quem desenha a lista.
    var aberto: Bool
    var abrir: () -> Void

    var body: some View {
        Button(action: abrir) { label }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Conta"))
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
                        .foregroundStyle(aberto ? theme.accent : theme.fgSubtle)
                        .rotationEffect(.degrees(aberto ? 180 : 0))
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

/// A lista de contas, desenhada no painel do agente.
///
/// Já foi menu do sistema, popover e folha. O menu quebrava o e-mail no meio; o popover
/// abriu três vezes no iPad como uma linha achatada com a setinha e nada para tocar; a
/// folha abriu, mas como um cartão solto no meio da tela, longe do botão que a chamou.
///
/// O que as três têm em comum é que quem decide onde e de que tamanho aparecem é o
/// sistema, a partir de coisas que a view não enxerga: espaço livre acima do botão,
/// tamanho de classe medido do lado de dentro, versão do iPadOS. Aqui não há nada disso:
/// é uma `overlay` do próprio painel, ancorada 54 pt abaixo do topo — logo abaixo da
/// linha da conta —, com a largura da coluna e a altura da lista. Fica onde foi posta.
struct ContasSobreposto: View {
    @Environment(\.theme) private var theme
    let agent: AgentModel
    var escolher: (AIAccount) -> Void
    var gerenciar: () -> Void
    var fechar: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Escurece o painel e fecha ao toque, como qualquer menu.
            Rectangle().fill(.black.opacity(0.32))
                .contentShape(Rectangle())
                .onTapGesture { fechar() }
                .accessibilityLabel(tr("Fechar"))
                .accessibilityAddTraits(.isButton)
                .transition(.opacity)
            painel
                .frame(maxWidth: 300, alignment: .leading)
                .padding(.horizontal, 12)
                // 52 pt de cabeçalho mais uma folga: encosta na linha da conta sem cobrir.
                .padding(.top, 56)
                .transition(.scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity))
        }
    }

    var painel: some View {
        VStack(spacing: 0) {
            if agent.accounts.accounts.isEmpty {
                Text(tr("Nenhuma conta ainda. O modelo da Apple não pede conta nenhuma."))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 12)
            } else {
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
                    .hoverEffect(.highlight)
                }
            }
            // Separador inteiro, não recuado: aqui muda o assunto da lista.
            Rectangle().fill(theme.separator).frame(height: 0.5)
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
            .hoverEffect(.highlight)
        }
        .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
    }
}
