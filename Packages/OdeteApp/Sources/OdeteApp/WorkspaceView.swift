import OdeteCore
import OdeteI18n
import OdeteUI
import SwiftUI

func clamp(_ v: Double, _ menor: Double, _ maior: Double) -> Double {
    min(max(v, menor), max(menor, maior))
}

/// Layout de iPad: rail, sidebar, centro, agente e a gaveta do terminal.
///
/// A raiz do layout lê o que decide o layout — as preferências e as medidas dos
/// divisores — e nada que mude a cada tecla. As views de dentro (centro, barra de status,
/// terminal, árvore) não recebem parâmetros daqui, então refazer este corpo não refaz o
/// delas; o rail recebe números e só se refaz quando eles mudam.
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
                padLayout(size: geo.size)
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
        .alert(tr("Erro"), isPresented: Binding(get: { ws.error != nil }, set: {
            if !$0 {
                ws.error = nil
            }
        })) {
            Button(tr("OK")) { ws.error = nil }
        } message: { Text(ws.error ?? "") }
        .folhasDoHistoricoLocal()
    }

    func portraitLayout(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            PhoneShell(showAgentTab: !chrome.snapshot.agentVisible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if chrome.snapshot.agentVisible {
                let maior = max(Metrics.minAgent, width - Metrics.minCenter)
                divisorArrastavel(.agente, eixo: .horizontal, menor: Metrics.minAgent, maior: maior, direcao: -1)
                AgentPane()
                    .frame(width: clamp(chrome.medida(.agente), Metrics.minAgent, maior))
            }
        }
        .background(theme.bg)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.agentVisible)
    }

    /// Um `GeometryReader` só, o de fora, e a animação por dentro dele.
    ///
    /// Antes havia um segundo `GeometryReader` aqui, com as animações de recolher
    /// envolvendo-o. Quem decide entre colunas e abas é a medida de fora; quem decide a
    /// largura de cada coluna era a de dentro — e animar o que contém um leitor de
    /// geometria faz a medida de dentro andar junto com a animação. Recolher um lado
    /// deixava as duas medidas discordando: o rail do iPad desenhado por causa da medida
    /// de fora, e as colunas espremidas pela de dentro, com o resto da tela preto.
    func padLayout(size: CGSize) -> some View {
        // Os máximos saem da tela, não de constantes. Antes a largura desenhada
        // era cortada por um segundo limite e a alça continuava andando sozinha
        // depois que o painel já tinha parado.
        let livre = size.width - Metrics.railWidth - 24
        let agenteAberto = chrome.snapshot.agentVisible
        let sideMax = max(Metrics.minSide, livre - Metrics.minCenter - (agenteAberto ? Metrics.minAgent : 0))
        let sideW = chrome.snapshot.sideOpen ? clamp(chrome.medida(.lado), Metrics.minSide, sideMax) : 0
        let agentMax = max(Metrics.minAgent, livre - sideW - Metrics.minCenter)
        let agentW = agenteAberto ? clamp(chrome.medida(.agente), Metrics.minAgent, agentMax) : 0
        return columns(narrow: false, medidas: Medidas(
            side: sideW,
            sideMax: sideMax,
            agent: agentW,
            agentMax: agentMax,
            termMax: max(Metrics.minTerm, size.height - Metrics.minCenter)
        ))
        .frame(width: size.width, height: size.height)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.sideOpen)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.agentVisible)
        .animation(.snappy(duration: 0.2), value: chrome.snapshot.termVisible)
        // Sem isto sobra uma faixa preta na altura do relógio, acima das abas.
        .background(theme.surface.ignoresSafeArea())
    }

    /// Divisor que arrasta a medida ao vivo e só grava a preferência ao soltar.
    ///
    /// A ligação já entrega e guarda o valor dentro dos limites desta tela: sem isso o
    /// valor guardado passa do máximo visível e o arrasto de volta não faz nada até ele
    /// cair de novo abaixo do corte.
    func divisorArrastavel(
        _ d: ChromeState.Divisor,
        eixo: Splitter.Axis,
        menor: Double,
        maior: Double,
        direcao: Double
    ) -> Splitter {
        Splitter(
            value: Binding(
                get: { clamp(chrome.medida(d), menor, maior) },
                set: { chrome.arrastar(d, para: clamp($0, menor, maior)) }
            ),
            axis: eixo,
            range: menor ... maior,
            direction: direcao,
            aoSoltar: { chrome.soltarArrasto() }
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
        let esquerdaPrimeiro = chrome.snapshot.sideSide == .esquerda
        let agenteNaEsquerda = chrome.snapshot.agentSide == .esquerda
        let agenteAberto = chrome.snapshot.agentVisible && !narrow
        return HStack(spacing: 0) {
            if esquerdaPrimeiro {
                ladoDosArquivos(m, naEsquerda: true)
            }
            if agenteNaEsquerda, agenteAberto {
                agente(m, naEsquerda: true)
            }
            centro(m)
            if !agenteNaEsquerda, agenteAberto {
                agente(m, naEsquerda: false)
            }
            if !esquerdaPrimeiro {
                ladoDosArquivos(m, naEsquerda: false)
            }
        }
    }

    /// O rail sempre encosta na borda da tela, e a árvore fica entre ele e o editor.
    /// Trocar de lado é espelhar os dois, não só mover a árvore.
    @ViewBuilder
    func ladoDosArquivos(_ m: Medidas, naEsquerda: Bool) -> some View {
        let problemas = ws.contagemDeProblemas
        // Comparado pelos números: os fechamentos mudam a cada corpo, e sem isto o rail e
        // os seis botões dele se refaziam junto com qualquer coisa que refizesse a raiz.
        let rail = Rail(
            side: chrome.snapshot.side,
            sideOpen: chrome.snapshot.sideOpen,
            agentVisible: chrome.snapshot.agentVisible,
            agentBusy: ws.agent.running,
            problemas: problemas.erros + problemas.avisos,
            problemasGraves: problemas.erros > 0,
            alteracoes: ws.git.status.count,
            onSelect: { chrome.select(side: $0) },
            onToggleAgent: { chrome.toggleAgent() },
            // Ajustes é uma folha, não um painel de coluna: numa coluna estreita a
            // lista inteira vira uma linguiça sem hierarquia.
            onSettings: { chrome.settingsOpen = true },
            onProjects: { app.closeWorkspace() }
        )
        .equatable()
        let divisor = divisorArrastavel(.lado, eixo: .horizontal, menor: Metrics.minSide, maior: m.sideMax, direcao: naEsquerda ? 1 : -1)
        if naEsquerda {
            rail
            if chrome.snapshot.sideOpen {
                colunaLateral(m)
                divisor
            }
        } else {
            if chrome.snapshot.sideOpen {
                divisor
                colunaLateral(m)
            }
            rail
        }
    }

    /// A árvore, e embaixo dela o terminal quando ele foi posto aqui. Com o terminal do
    /// lado sobra a largura inteira para o código, que é o que se olha o dia todo.
    func colunaLateral(_ m: Medidas) -> some View {
        let comTerminal = chrome.snapshot.termVisible && chrome.snapshot.termPlace == .lateral
        return VStack(spacing: 0) {
            SidebarView()
                // Cinto de segurança: conteúdo que não consiga encolher fica cortado
                // dentro da coluna, em vez de empurrar o rail para fora da tela.
                .clipped()
                .frame(maxHeight: .infinity)
            if comTerminal {
                divisorArrastavel(.terminal, eixo: .vertical, menor: Metrics.minTerm, maior: m.termMax, direcao: -1)
                TerminalPane()
                    .frame(height: clamp(chrome.medida(.terminal), Metrics.minTerm, m.termMax))
            }
        }
        .frame(width: m.side)
        .background(theme.surface)
    }

    func centro(_ m: Medidas) -> some View {
        // Terminal na coluna lateral só existe quando a coluna existe; com a árvore
        // fechada ele volta para baixo do editor em vez de sumir.
        let aqui = chrome.snapshot.termPlace == .editor || !chrome.snapshot.sideOpen
        return VStack(spacing: 0) {
            CenterPane()
            // As informações do arquivo ficam colados no pé do editor, não no pé da janela.
            if chrome.snapshot.showStatusBar {
                StatusBar()
            }
            if chrome.snapshot.termVisible, aqui {
                divisorArrastavel(.terminal, eixo: .vertical, menor: Metrics.minTerm, maior: m.termMax, direcao: -1)
                TerminalPane()
                    .frame(height: clamp(chrome.medida(.terminal), Metrics.minTerm, m.termMax))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // Identificada para o teste poder medir a largura dela: o bug de recolher os
        // dois lados e a coluna não crescer só aparece na medida.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("colunaCentral")
    }

    func agente(_ m: Medidas, naEsquerda: Bool) -> some View {
        let divisor = divisorArrastavel(.agente, eixo: .horizontal, menor: Metrics.minAgent, maior: m.agentMax, direcao: naEsquerda ? 1 : -1)
        return Group {
            if naEsquerda {
                AgentPane().frame(width: m.agent)
                divisor
            } else {
                divisor
                AgentPane().frame(width: m.agent)
            }
        }
    }
}

struct SidebarView: View {
    @Environment(ChromeState.self) private var chrome

    var body: some View {
        switch chrome.snapshot.side {
        case .files: FileTreeView()
        case .search: SearchPane()
        case .git: GitPane()
        case .problems: ProblemsPane()
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
            PaneHeader(tr("Ajustes"))
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
                                    Text(tr(p.blurb)).font(OdeteFont.ui(10.5)).foregroundStyle(Color(hex: p.fgMuted))
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
                } header: { header(tr("Tema")) }
                Section {
                    Stepper(value: $chrome.snapshot.editor.fontSize, in: 10 ... 22, step: 1) {
                        LabeledContent(tr("Tamanho da fonte")) {
                            Text(tr("%1$@ pt", "\(Int(chrome.snapshot.editor.fontSize))")).font(OdeteFont.mono(12))
                                .foregroundStyle(theme.fgMuted)
                        }
                    }
                    Toggle(tr("Salvar automaticamente"), isOn: $chrome.snapshot.editor.autoSave)
                    Toggle(tr("Quebrar linhas"), isOn: $chrome.snapshot.editor.wrap)
                    Toggle(tr("Números de linha"), isOn: $chrome.snapshot.editor.lineNumbers)
                } header: { header(tr("Editor")) }
                Section {
                    Toggle(tr("Agente"), isOn: $chrome.snapshot.agentVisible)
                    Toggle(tr("Terminal"), isOn: $chrome.snapshot.termVisible)
                    Button(tr("Restaurar layout")) { chrome.resetLayout() }
                } header: { header(tr("Layout")) }
                Section {
                    Toggle(tr("Projetos no iCloud Drive"), isOn: Binding(
                        get: { chrome.snapshot.projectsInCloud },
                        set: { chrome.snapshot.projectsInCloud = app.setCloud($0) }
                    ))
                    .disabled(!app.cloudAvailable && !chrome.snapshot.projectsInCloud)
                    Text(app.cloudAvailable
                        ? tr("Move a pasta Projects para o iCloud Drive; continua funcionando offline.")
                        :
                        tr(
                            "iCloud Drive indisponível neste dispositivo (entre com o Apple ID ou habilite o iCloud Drive)."
                        ))
                        .font(OdeteFont.ui(11)).foregroundStyle(theme.fgMuted)
                    Text(
                        tr(
                            "Atalhos: Abrir projeto, Rodar comando, Perguntar à Odete e Novo projeto ficam no app Atalhos."
                        )
                    )
                    .font(OdeteFont.ui(11)).foregroundStyle(theme.fgMuted)
                } header: { header(tr("Sistema")) }
                Section { AccountsSettings() } header: { header(tr("Contas e Git")) }
                Section { AIAccountsSettings() } header: { header(tr("Contas de IA")) }
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
