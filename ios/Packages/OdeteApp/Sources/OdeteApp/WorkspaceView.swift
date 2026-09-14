import OdeteCore
import OdeteUI
import SwiftUI

func clamp(_ v: Double, _ menor: Double, _ maior: Double) -> Double {
    min(max(v, menor), max(menor, maior))
}

/// Layout de iPad: rail, sidebar, centro, agente e a gaveta do terminal.
struct WorkspaceView: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(WorkspaceModel.self) private var ws
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        GeometryReader { geo in
            // iPhone, ou iPad em retrato/janela estreita: abas embaixo como um iPhone grande,
            // no máximo dividindo a tela com o agente. Paisagem: colunas.
            let portrait = geo.size.width < geo.size.height || geo.size.width < 1000
            if sizeClass == .compact {
                PhoneShell()
            } else if portrait {
                portraitLayout(width: geo.size.width)
            } else {
                padLayout
            }
        }
        .overlay {
            if ws.paletteOpen {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { ws.paletteOpen = false }
                    CommandPalette().padding(.top, 60)
                }
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.15), value: ws.paletteOpen)
        // A faixa na altura do relógio é área de segurança: pintada aqui, fora do
        // GeometryReader, ela some e a barra de abas encosta no topo.
        .background(theme.surface.ignoresSafeArea())
        .focusedSceneValue(\.workspaceActions, WorkspaceActions(ws: ws, chrome: chrome, app: app))
        .alert("Erro", isPresented: Binding(get: { ws.error != nil }, set: {
            if !$0 {
                ws.error = nil
            }
        })) {
            Button("OK") { ws.error = nil }
        } message: { Text(ws.error ?? "") }
    }

    func portraitLayout(width: CGFloat) -> some View {
        @Bindable var chrome = chrome
        return HStack(spacing: 0) {
            PhoneShell(showAgentTab: !chrome.snapshot.agentVisible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if chrome.snapshot.agentVisible {
                let maior = max(Metrics.minAgent, width - Metrics.minCenter)
                Splitter(
                    value: preso($chrome.snapshot.agentWidth, Metrics.minAgent, maior),
                    axis: .horizontal,
                    range: Metrics.minAgent ... maior,
                    direction: -1
                )
                AgentPane()
                    .frame(width: clamp(chrome.snapshot.agentWidth, Metrics.minAgent, maior))
            }
        }
        .background(theme.bg)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.agentVisible)
    }

    var padLayout: some View {
        GeometryReader { geo in
            // Os máximos saem da tela, não de constantes. Antes a largura desenhada
            // era cortada por um segundo limite e a alça continuava andando sozinha
            // depois que o painel já tinha parado.
            let livre = geo.size.width - Metrics.railWidth - 24
            let agenteAberto = chrome.snapshot.agentVisible
            let sideMax = max(Metrics.minSide, livre - Metrics.minCenter - (agenteAberto ? Metrics.minAgent : 0))
            let sideW = chrome.snapshot.sideOpen ? clamp(chrome.snapshot.sideWidth, Metrics.minSide, sideMax) : 0
            let agentMax = max(Metrics.minAgent, livre - sideW - Metrics.minCenter)
            let agentW = agenteAberto ? clamp(chrome.snapshot.agentWidth, Metrics.minAgent, agentMax) : 0
            columns(narrow: false, medidas: Medidas(
                side: sideW,
                sideMax: sideMax,
                agent: agentW,
                agentMax: agentMax,
                termMax: max(Metrics.minTerm, geo.size.height - Metrics.minCenter)
            ))
        }
        // Sem isto sobra uma faixa preta na altura do relógio, acima das abas.
        .background(theme.surface.ignoresSafeArea())
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.sideOpen)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.agentVisible)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.termVisible)
    }

    /// Ligação que já entrega e guarda o valor dentro dos limites desta tela: sem isso
    /// o valor guardado passa do máximo visível e o arrasto de volta não faz nada até
    /// ele cair de novo abaixo do corte.
    func preso(_ valor: Binding<Double>, _ menor: Double, _ maior: Double) -> Binding<Double> {
        Binding(
            get: { clamp(valor.wrappedValue, menor, maior) },
            set: { valor.wrappedValue = clamp($0, menor, maior) }
        )
    }

    /// Larguras já resolvidas para esta tela, com os máximos que valem agora.
    struct Medidas {
        var side: Double
        var sideMax: Double
        var agent: Double
        var agentMax: Double
        var termMax: Double
    }

    func columns(narrow: Bool, medidas m: Medidas) -> some View {
        @Bindable var chrome = chrome
        return HStack(spacing: 0) {
            Rail(
                side: chrome.snapshot.side,
                sideOpen: chrome.snapshot.sideOpen,
                agentVisible: chrome.snapshot.agentVisible,
                agentBusy: ws.agent.running,
                // Ajustes é uma folha, não um painel de coluna: numa coluna estreita a lista
                // inteira vira uma linguiça sem hierarquia.
                onSelect: { p in
                    if p == .settings {
                        chrome.settingsOpen = true
                    } else {
                        chrome.select(side: p)
                    }
                },
                onToggleAgent: { chrome.toggleAgent() }
            )
            if chrome.snapshot.sideOpen {
                SidebarView()
                    .frame(width: m.side)
                    .background(theme.surface)
                Splitter(
                    value: preso($chrome.snapshot.sideWidth, Metrics.minSide, m.sideMax),
                    axis: .horizontal,
                    range: Metrics.minSide ... m.sideMax
                )
            }
            VStack(spacing: 0) {
                CenterPane()
                // As informações do arquivo ficam colados no pé do editor, não no pé da janela.
                StatusBar()
                if chrome.snapshot.termVisible {
                    Splitter(
                        value: preso($chrome.snapshot.termHeight, Metrics.minTerm, m.termMax),
                        axis: .vertical,
                        range: Metrics.minTerm ... m.termMax,
                        direction: -1
                    )
                    TerminalPane()
                        .frame(height: clamp(chrome.snapshot.termHeight, Metrics.minTerm, m.termMax))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            if chrome.snapshot.agentVisible, !narrow {
                Splitter(
                    value: preso($chrome.snapshot.agentWidth, Metrics.minAgent, m.agentMax),
                    axis: .horizontal,
                    range: Metrics.minAgent ... m.agentMax,
                    direction: -1
                )
                AgentPane()
                    .frame(width: m.agent)
            }
        }
    }
}

struct SidebarView: View {
    @Environment(ChromeState.self) private var chrome

    var body: some View {
        switch chrome.snapshot.side {
        case .files: FileTreeView()
        case .outline: OutlinePane()
        case .search: SearchPane()
        case .git: GitPane()
        case .problems: ProblemsPane()
        case .settings: SettingsShell()
        }
    }
}

struct SettingsShell: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var chrome = chrome
        VStack(spacing: 0) {
            PaneHeader("Ajustes")
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Metrics.s2)], spacing: Metrics.s2) {
                        ForEach(ThemePalette.all) { p in
                            Button { withAnimation(.snappy(duration: 0.2)) { chrome.snapshot.theme = p.id } } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 4) {
                                        Circle().fill(Color(hex: p.bg)).frame(width: 12, height: 12)
                                            .overlay(Circle().stroke(
                                                .white.opacity(0.15),
                                                lineWidth: 0.5
                                            ))
                                        Circle().fill(Color(hex: p.accent)).frame(width: 12, height: 12)
                                        Circle().fill(Color(hex: p.bgSubtle)).frame(width: 12, height: 12)
                                    }
                                    Text(p.label).font(OdeteFont.ui(12.5, weight: .medium))
                                        .foregroundStyle(Color(hex: p.fg))
                                    Text(p.blurb).font(OdeteFont.ui(10.5)).foregroundStyle(Color(hex: p.fgMuted))
                                        .lineLimit(1)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    Color(hex: p.bg),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(
                                    p.id == chrome.snapshot.theme ? theme.accent : theme.separator,
                                    lineWidth: p.id == chrome.snapshot.theme ? 1.5 : 0.5
                                ))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
                } header: { header("Tema") }
                Section {
                    Stepper(value: $chrome.snapshot.editor.fontSize, in: 10 ... 22, step: 1) {
                        LabeledContent("Tamanho da fonte") {
                            Text("\(Int(chrome.snapshot.editor.fontSize)) pt").font(OdeteFont.mono(12))
                                .foregroundStyle(theme.fgMuted)
                        }
                    }
                    Toggle("Salvar automaticamente", isOn: $chrome.snapshot.editor.autoSave)
                    Toggle("Quebrar linhas", isOn: $chrome.snapshot.editor.wrap)
                    Toggle("Números de linha", isOn: $chrome.snapshot.editor.lineNumbers)
                } header: { header("Editor") }
                Section {
                    Toggle("Agente", isOn: $chrome.snapshot.agentVisible)
                    Toggle("Terminal", isOn: $chrome.snapshot.termVisible)
                    Button("Restaurar layout") { chrome.resetLayout() }
                } header: { header("Layout") }
                Section {
                    Toggle("Projetos no iCloud Drive", isOn: Binding(
                        get: { chrome.snapshot.projectsInCloud },
                        set: { chrome.snapshot.projectsInCloud = app.setCloud($0) }
                    ))
                    .disabled(!app.cloudAvailable && !chrome.snapshot.projectsInCloud)
                    Text(app.cloudAvailable
                        ? "Move a pasta Projects para o iCloud Drive; continua funcionando offline."
                        :
                        "iCloud Drive indisponível neste dispositivo (entre com o Apple ID ou habilite o iCloud Drive).")
                        .font(OdeteFont.ui(11)).foregroundStyle(theme.fgMuted)
                    Text(
                        "Atalhos: Abrir projeto, Rodar comando, Perguntar à Odete e Novo projeto ficam no app Atalhos."
                    )
                    .font(OdeteFont.ui(11)).foregroundStyle(theme.fgMuted)
                } header: { header("Sistema") }
                Section { AccountsSettings() } header: { header("Contas e Git") }
                Section { AIAccountsSettings() } header: { header("Contas de IA") }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .listRowBackground(theme.bg.opacity(theme.dark ? 0.55 : 0.7))
            .font(OdeteFont.ui(13.5))
            .foregroundStyle(theme.fg)
            .tint(theme.accent)
        }
        .background(theme.surface)
    }

    func header(_ s: String) -> some View {
        Text(s.uppercased()).font(OdeteFont.label).tracking(1.2).foregroundStyle(theme.fgSubtle)
    }
}
