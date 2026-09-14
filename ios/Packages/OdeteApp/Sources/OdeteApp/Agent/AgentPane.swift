import OdeteAgent
import OdeteCore
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
            footer(ag)
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
                ScrollView { AIAccountsSettings().padding() }.navigationTitle("Contas de IA")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { showAccounts = false } } }
            }
        }
        .task { await ag.loadModels() }
    }

    func header(_ ag: AgentModel) -> some View {
        HStack(spacing: 6) {
            ModelMenu(agent: ag, onConnect: { showAccounts = true })
            Spacer(minLength: 4)
            if !ag.effortOptions.isEmpty {
                Menu {
                    ForEach(ag.effortOptions, id: \.self) { e in Button { ag.setEffort(e) } label: { Label(
                        Effort.labels[e] ?? e,
                        systemImage: e == ag.effort ? "checkmark" : ""
                    ) } }
                } label: {
                    Text(Effort.labels[ag.effort] ?? ag.effort).font(OdeteFont.mono(10.5))
                        .foregroundStyle(theme.fgMuted)
                        .padding(.horizontal, 8).frame(height: 26).background(theme.bgSubtle, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            HeaderButton("clock.arrow.circlepath", label: "Conversas") { history = true }
            HeaderButton("arrow.uturn.backward", label: "Desfazer último turno") { _ = ag.undoLastTurn() }
                .disabled(!ag.canUndoTurn)
            HeaderButton("plus.bubble", label: "Nova conversa") { ag.newChat() }
            if sizeClass != .compact {
                HeaderButton("xmark", label: "Fechar agente") { chrome.toggleAgent() }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Metrics.tab)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    func patchBar(_ ag: AgentModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.badge.gearshape").foregroundStyle(theme.accent)
            Text(
                "\(ag.pendingPatches.count) patch\(ag.pendingPatches.count == 1 ? "" : "es") pendente\(ag.pendingPatches.count == 1 ? "" : "s")"
            )
            .font(OdeteFont.ui(12)).foregroundStyle(theme.fg)
            Spacer()
            Button("Rejeitar tudo") { ag.rejectAll() }.buttonStyle(.glass).font(OdeteFont.ui(12))
            Button("Aceitar tudo") { ag.acceptAll() }.buttonStyle(.glassProminent).font(OdeteFont.ui(12))
        }
        .padding(.horizontal, Metrics.s3).frame(height: 44)
        .background(theme.glassTint)
        .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 0.5) }
    }

    func footer(_ ag: AgentModel) -> some View {
        let used = max(ag.thread.lastInput, ag.estimatedTokens)
        let frac = min(1, Double(used) / Double(max(1, ag.contextWindow)))
        return HStack(spacing: 8) {
            Text("turno \(fmtTok(ag.lastTurnUse.input))↑ \(fmtTok(ag.lastTurnUse.output))↓").font(OdeteFont.mono(10))
                .foregroundStyle(theme.fgSubtle)
            Text("conversa \(fmtTok(ag.thread.usage.input + ag.thread.usage.output))").font(OdeteFont.mono(10))
                .foregroundStyle(theme.fgSubtle)
            Spacer()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.bgSubtle)
                    Capsule().fill(frac > 0.85 ? theme.danger : theme.accent).frame(width: g.size.width * frac)
                }
            }
            .frame(width: 70, height: 5)
            Text("\(fmtTok(used))/\(fmtTok(ag.contextWindow))").font(OdeteFont.mono(10)).foregroundStyle(theme.fgSubtle)
        }
        .padding(.horizontal, 12).frame(height: 24)
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

/// Menu de conta e modelo.
struct ModelMenu: View {
    @Environment(\.theme) private var theme
    let agent: AgentModel
    let onConnect: () -> Void

    var body: some View {
        Menu {
            ForEach(ProviderKind.allCases) { kind in
                let accs = agent.accounts.accounts(of: kind)
                if !accs.isEmpty {
                    Section(kind.label) {
                        ForEach(accs) { a in
                            Button { agent.setAccount(a) } label: { Label(
                                a
                                    .label + (a.login.isEmpty ? "" : " · \(a.login)") +
                                    (a.needsReconnect ? " (reconectar)" : ""),
                                systemImage: a.id == agent.account?.id ? "checkmark" : kind.symbol
                            ) }
                        }
                    }
                }
            }
            if let acc = agent.account {
                Section("Modelo · \(acc.kind.label)") {
                    if agent.loadingModels {
                        Text("carregando…")
                    }
                    ForEach(agent.models) { m in Button { agent.setModel(m.id) } label: { Label(
                        m.label,
                        systemImage: m.id == agent.model ? "checkmark" : ""
                    ) } }
                    if agent.models.isEmpty, !agent.loadingModels {
                        Button("usar \(acc.kind.defaultModel)") { agent.setModel(acc.kind.defaultModel) }
                        if let e = agent.modelsError {
                            Text(e)
                        }
                    }
                    Button("Recarregar modelos") { Task { await agent.loadModels() } }
                }
            }
            Button { onConnect() } label: { Label("Contas de IA…", systemImage: "person.crop.circle.badge.plus") }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: agent.account?.kind.symbol ?? "sparkles").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(agent.account?.label ?? "Sem conta").font(OdeteFont.ui(12, weight: .medium))
                        .foregroundStyle(theme.fg).lineLimit(1)
                    Text(agent.account == nil ? "toque para conectar" : agent.model).font(OdeteFont.mono(10))
                        .foregroundStyle(theme.fgSubtle).lineLimit(1)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.fgSubtle)
            }
            .padding(.horizontal, 10).frame(height: 36)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct HistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let agent: AgentModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(agent.threads) { t in
                    Button { agent.open(t); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.title).font(OdeteFont.ui(13, weight: t.id == agent.thread.id ? .semibold : .regular))
                                .foregroundStyle(theme.fg).lineLimit(2)
                            Text(
                                "\(t.updated.formatted(date: .abbreviated, time: .shortened)) · \(fmtTok(t.usage.input + t.usage.output)) tokens"
                            )
                            .font(OdeteFont.mono(10)).foregroundStyle(theme.fgSubtle)
                        }
                    }
                    .swipeActions { Button(role: .destructive) { agent.remove(t) } label: { Label(
                        "Apagar",
                        systemImage: "trash"
                    ) } }
                }
                if agent.threads.isEmpty {
                    Text("Nenhuma conversa ainda.").foregroundStyle(theme.fgMuted)
                }
            }
            .navigationTitle("Conversas")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Nova") { agent.newChat(); dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
