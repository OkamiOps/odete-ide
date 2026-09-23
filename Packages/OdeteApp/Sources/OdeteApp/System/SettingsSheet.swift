import OdeteCore
import OdeteI18n
import OdeteUI
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case idioma, appearance, editor, layout, git, ai, system, about
    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .idioma: tr("Idioma")
        case .appearance: tr(tr("Aparência"))
        case .editor: tr("Editor")
        case .layout: tr("Layout")
        case .git: tr("Git e GitHub")
        case .ai: tr("Contas de IA")
        case .system: tr("Sistema")
        case .about: tr("Sobre")
        }
    }

    var symbol: String {
        switch self {
        case .idioma: "globe"
        case .appearance: "paintpalette"
        case .editor: "chevron.left.forwardslash.chevron.right"
        case .layout: "rectangle.3.group"
        case .git: "arrow.triangle.branch"
        case .ai: "sparkles"
        case .system: "ipad.and.arrow.forward"
        case .about: "info.circle"
        }
    }
}

/// Ajustes: folha com seções à esquerda e o formulário da seção à direita (iPad); lista → detalhe no iPhone.
struct SettingsSheet: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var section: SettingsSection = .appearance

    var body: some View {
        Group {
            if sizeClass == .compact {
                NavigationStack {
                    List(SettingsSection.allCases) { s in
                        NavigationLink(value: s) { Label(s.label, systemImage: s.symbol) }
                    }
                    .navigationTitle(tr("Ajustes"))
                    .navigationDestination(for: SettingsSection.self) { s in
                        SettingsContent(section: s).navigationTitle(s.label)
                    }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("OK")) { dismiss() } } }
                }
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Ajustes")).font(OdeteFont.ui(20, weight: .semibold)).foregroundStyle(theme.fg)
                            .padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 10)
                        ForEach(SettingsSection.allCases) { s in
                            let on = s == section
                            Button { withAnimation(.snappy(duration: 0.2)) { section = s } } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: s.symbol).font(.system(size: 13, weight: .medium))
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(on ? theme.accentFg : theme.accent).frame(width: 18)
                                    Text(s.label).font(OdeteFont.ui(13.5, weight: on ? .semibold : .regular))
                                        .foregroundStyle(on ? theme.accentFg : theme.fg)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12).frame(height: 36)
                                .background {
                                    if on {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(theme.accent.gradient)
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .frame(width: 220)
                    .background(theme.surface.opacity(0.6))
                    Divider().opacity(0.3)
                    VStack(spacing: 0) {
                        HStack {
                            Text(section.label).font(OdeteFont.ui(17, weight: .semibold)).foregroundStyle(theme.fg)
                            Spacer()
                            Button(tr("OK")) { dismiss() }.buttonStyle(.glassProminent).controlSize(.small)
                        }
                        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
                        SettingsContent(section: section)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(theme.bg)
            }
        }
        .presentationSizing(.page)
        .presentationDetents([.large])
        .pointerScrolling()
    }
}

/// Conteúdo de uma seção, no mesmo formato do painel Git: título fora do cartão, cartão de
/// linhas com quadrado de ícone, e a explicação embaixo em texto de apoio.
struct SettingsContent: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    /// Calculada, e não guardada: uma propriedade guardada com valor inicial deixaria
    /// o init de membros privado, e quem monta a folha é outro arquivo.
    private var idiomas: Idiomas {
        Idiomas.shared
    }

    var section: SettingsSection

    var body: some View {
        ScrollPane {
            VStack(alignment: .leading, spacing: 16) {
                switch section {
                case .idioma: idioma
                case .appearance: appearance
                case .editor: editor
                case .layout: layout
                case .git: AccountsSettings()
                case .ai: AIAccountsSettings()
                case .system: system
                case .about: about
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .tint(theme.accent)
    }

    // MARK: idioma

    /// A lista começa por "Idioma do aparelho", que é o padrão: quem nunca abriu esta
    /// tela já está no idioma certo. Cada opção aparece escrita nela mesma — quem abriu
    /// os Ajustes num idioma que não lê precisa reconhecer o dele sem entender o resto.
    var idioma: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(tr("Idioma"))
            CardList {
                ForEach(Array(([Idioma.sistema] + Idioma.traduzidos).enumerated()), id: \.element) { i, op in
                    Button { idiomas.escolher(op) } label: {
                        CardRow(
                            op.nome,
                            emoji: op.bandeira,
                            detail: op == .sistema ? Idioma.doAparelho.nome : nil,
                            first: i == 0
                        ) {
                            if idiomas.atual == op {
                                Image(systemName: "checkmark").font(.footnote.bold())
                                    .foregroundStyle(theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            CardNote(tr(tr("Vale para o app inteiro: telas, terminal, git e as respostas do agente.")))
        }
    }

    // MARK: aparência

    var appearance: some View {
        @Bindable var chrome = chrome
        return Group {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(tr("Claro e escuro"))
                CardList {
                    CardRow(tr("Seguir o iPad"), symbol: "circle.lefthalf.filled", color: .purple, first: true) {
                        Toggle("", isOn: $chrome.snapshot.themeAuto).labelsHidden()
                    }
                    if chrome.snapshot.themeAuto {
                        CardRow(tr("Tema claro"), symbol: "sun.max", color: .orange) {
                            escolhaDeTema($chrome.snapshot.themeLight, claros: true)
                        }
                        CardRow(tr("Tema escuro"), symbol: "moon", color: .indigo) {
                            escolhaDeTema($chrome.snapshot.themeDark, claros: false)
                        }
                    }
                }
                CardNote(tr(
                    "Com isto ligado a Odete troca de tema junto com o iPad, no fim do dia. Desligado, fica no tema escolhido abaixo."
                ))
            }
            if !chrome.snapshot.themeAuto {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(tr("Tema"))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(ThemePalette.all) { p in
                            ThemeCard(palette: p, on: p.id == chrome.snapshot.theme) {
                                withAnimation(.snappy(duration: 0.2)) { chrome.snapshot.theme = p.id }
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(tr("Cores do código"))
                CardList {
                    ForEach(Array(SyntaxColors.nomes.enumerated()), id: \.element) { i, nome in
                        CardRow(
                            rotuloDoToken(nome),
                            symbol: "paintbrush.pointed",
                            color: Color(hex: chrome.palette.syntax.cor(nome)),
                            detail: exemploDoToken(nome),
                            first: i == 0
                        ) {
                            ColorPicker("", selection: corDoToken(nome), supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }
                if !chrome.snapshot.syntaxOverrides.isEmpty {
                    CardList {
                        Button { chrome.snapshot.syntaxOverrides = [:] } label: {
                            CardRow(
                                tr("Voltar às cores do tema"),
                                symbol: "arrow.counterclockwise",
                                color: .gray,
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
                CardNote(tr(
                    "Vale por cima do tema escolhido. O que você não trocar continua vindo do tema, então trocar de tema depois ainda muda o resto."
                ))
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(tr("Interface"))
                CardList {
                    CardRow(
                        tr("Tamanho da interface"),
                        symbol: "textformat.size.larger",
                        color: .teal,
                        first: true
                    ) {
                        // Os Ajustes não se redesenham a cada passo (ver `RootView`), então
                        // a amostra é quem mostra o tamanho na hora, aqui do lado do botão.
                        Text(tr("Exemplo"))
                            .font(.system(size: 13 * chrome.snapshot.uiScale))
                            .foregroundStyle(theme.fgMuted).lineLimit(1)
                        Text("\(Int(chrome.snapshot.uiScale * 100))%")
                            .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                        Stepper(
                            tr("Tamanho da interface"),
                            value: $chrome.snapshot.uiScale,
                            in: 0.85 ... 1.4,
                            step: 0.05
                        )
                        .labelsHidden().fixedSize()
                    }
                    CardRow(tr("Barra de abas"), symbol: "rectangle.topthird.inset.filled", color: .teal) {
                        Toggle("", isOn: $chrome.snapshot.showTabBar).labelsHidden()
                    }
                    CardRow(tr("Barra de status"), symbol: "rectangle.bottomthird.inset.filled", color: .teal) {
                        Toggle("", isOn: $chrome.snapshot.showStatusBar).labelsHidden()
                    }
                }
                CardNote(tr(
                    "O tamanho aqui é o das telas do app. O do código é separado, em Editor, e não muda junto."
                ))
            }
        }
    }

    /// Ligação para uma cor do código: lê do tema com a troca por cima, escreve como hex.
    func corDoToken(_ nome: String) -> Binding<Color> {
        Binding(
            get: { Color(hex: chrome.palette.syntax.cor(nome)) },
            set: { chrome.snapshot.syntaxOverrides[nome] = $0.hexRGB }
        )
    }

    func rotuloDoToken(_ nome: String) -> String {
        switch nome {
        case "keyword": tr("Palavra-chave")
        case "string": tr("Texto")
        case "comment": tr("Comentário")
        case "number": tr("Número")
        case "function": tr("Função")
        default: tr("Tipo")
        }
    }

    /// Um pedaço de código de verdade ao lado do nome, para não ter que adivinhar o que
    /// cada um pinta.
    func exemploDoToken(_ nome: String) -> String {
        switch nome {
        case "keyword": "return, if, func"
        case "string": "\"olá\""
        case "comment": "// nota"
        case "number": "42, 3.14"
        case "function": "calcula()"
        default: "String, Pessoa"
        }
    }

    /// Só os temas do lado certo: não faz sentido oferecer um tema escuro como "tema claro".
    func escolhaDeTema(_ escolha: Binding<ThemeId>, claros: Bool) -> some View {
        Picker("", selection: escolha) {
            ForEach(ThemePalette.all.filter { $0.dark != claros }) { p in
                Text(p.label).tag(p.id)
            }
        }
        .labelsHidden()
    }

    // MARK: editor

    var editor: some View {
        @Bindable var chrome = chrome
        return Group {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(tr("Texto"))
                CardList {
                    CardRow(tr("Tamanho da fonte"), symbol: "textformat.size", color: .blue, first: true) {
                        // O rótulo do Stepper fica escondido; o valor vai ao lado, como nos
                        // Ajustes do sistema.
                        Text(tr("%1$@ pt", "\(Int(chrome.snapshot.editor.fontSize))"))
                            .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                        Stepper(tr("Tamanho da fonte"), value: $chrome.snapshot.editor.fontSize, in: 10 ... 22, step: 1)
                            .labelsHidden()
                            .fixedSize()
                    }
                    CardRow(tr("Altura da linha"), symbol: "arrow.up.and.down.text.horizontal", color: .blue) {
                        Picker("", selection: $chrome.snapshot.editor.lineHeight) {
                            Text(tr("Compacta")).tag(1.1)
                            Text(tr("Normal")).tag(1.25)
                            Text(tr("Arejada")).tag(1.45)
                        }
                        .labelsHidden()
                    }
                    CardRow(tr("Fonte"), symbol: "character", color: .blue) {
                        Picker("", selection: $chrome.snapshot.editor.fontFamily) {
                            ForEach(EditorFont.allCases, id: \.self) { f in
                                Text(f.label).tag(f)
                            }
                        }
                        .labelsHidden()
                    }
                    CardRow(
                        tr("Espaçamento das letras"),
                        symbol: "arrow.left.and.right.text.vertical",
                        color: .blue
                    ) {
                        Picker("", selection: $chrome.snapshot.editor.kern) {
                            Text(tr("Apertado")).tag(-0.4)
                            Text(tr("Normal")).tag(0.0)
                            Text(tr("Solto")).tag(0.6)
                        }
                        .labelsHidden()
                    }
                    CardRow(tr("Quebrar linhas"), symbol: "text.append", color: .blue) {
                        Toggle("", isOn: $chrome.snapshot.editor.wrap).labelsHidden()
                    }
                    CardRow(tr("Indentação"), symbol: "increase.indent", color: .blue) {
                        Picker("", selection: $chrome.snapshot.editor.tabWidth) {
                            Text(tr("2 espaços")).tag(2)
                            Text(tr("4 espaços")).tag(4)
                            Text(tr("8 espaços")).tag(8)
                        }
                        .labelsHidden()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(tr("Exibição"))
                CardList {
                    CardRow(tr("Números de linha"), symbol: "list.number", color: .indigo, first: true) {
                        Toggle("", isOn: $chrome.snapshot.editor.lineNumbers).labelsHidden()
                    }
                    CardRow(tr("Minimapa"), symbol: "map", color: .indigo) {
                        Picker("", selection: $chrome.snapshot.editor.minimap) {
                            Text(tr("Desligado")).tag(MinimapSize.off)
                            Text(tr("Pequeno")).tag(MinimapSize.s)
                            Text(tr("Médio")).tag(MinimapSize.m)
                            Text(tr("Grande")).tag(MinimapSize.l)
                        }
                        .labelsHidden()
                    }
                    CardRow(
                        tr("Destacar linha atual"),
                        symbol: "text.line.first.and.arrowtriangle.forward",
                        color: .indigo
                    ) {
                        Toggle("", isOn: $chrome.snapshot.editor.highlightLine).labelsHidden()
                    }
                    CardRow(tr("Guias de indentação"), symbol: "rectangle.split.3x1", color: .indigo) {
                        Toggle("", isOn: $chrome.snapshot.editor.indentGuides).labelsHidden()
                    }
                    CardRow(tr("Mostrar espaços e tabs"), symbol: "space", color: .indigo) {
                        Toggle("", isOn: $chrome.snapshot.editor.showWhitespace).labelsHidden()
                    }
                    CardRow(tr("Mostrar quebras de linha"), symbol: "return", color: .indigo) {
                        Toggle("", isOn: $chrome.snapshot.editor.showLineBreaks).labelsHidden()
                    }
                    CardRow(tr("Guia de página"), symbol: "ruler", color: .indigo) {
                        Picker("", selection: $chrome.snapshot.editor.pageGuide) {
                            Text(tr("Nenhuma")).tag(0)
                            Text(tr("80 colunas")).tag(80)
                            Text(tr("100 colunas")).tag(100)
                            Text(tr("120 colunas")).tag(120)
                        }
                        .labelsHidden()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(tr("Edição"))
                CardList {
                    CardRow(tr("Fechar pares automaticamente"), symbol: "parentheses", color: .teal, first: true) {
                        Toggle("", isOn: $chrome.snapshot.editor.autoClosePairs).labelsHidden()
                    }
                    CardRow(tr("Rolar além do fim"), symbol: "arrow.down.to.line", color: .teal) {
                        Toggle("", isOn: $chrome.snapshot.editor.scrollPastEnd).labelsHidden()
                    }
                    CardRow(tr("Salvar automaticamente"), symbol: "square.and.arrow.down", color: .teal) {
                        Toggle("", isOn: $chrome.snapshot.editor.autoSave).labelsHidden()
                    }
                    CardRow(tr("Aparar espaços ao salvar"), symbol: "scissors", color: .teal) {
                        Toggle("", isOn: $chrome.snapshot.editor.trimOnSave).labelsHidden()
                    }
                    CardRow(tr("Linha em branco no fim"), symbol: "return", color: .teal) {
                        Toggle("", isOn: $chrome.snapshot.editor.finalNewline).labelsHidden()
                    }
                }
                CardNote(
                    tr(
                        "O salvamento automático espera 1 s depois de você parar de digitar. Sem ele, ⌘S ou o botão Salvar — e o que ficar sem salvar volta na próxima abertura, sem tocar no arquivo."
                    )
                )
            }
        }
    }

    // MARK: layout

    var layout: some View {
        @Bindable var chrome = chrome
        return Group {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(tr("Onde cada área fica"))
                CardList {
                    CardRow(tr("Arquivos"), symbol: "sidebar.left", color: .orange, first: true) {
                        Picker("", selection: $chrome.snapshot.sideSide) {
                            ForEach(LadoDoPainel.allCases, id: \.self) { l in Text(l.label).tag(l) }
                        }
                        .labelsHidden()
                    }
                    CardRow(tr("Agente"), symbol: "sparkles", color: .orange) {
                        Picker("", selection: $chrome.snapshot.agentSide) {
                            ForEach(LadoDoPainel.allCases, id: \.self) { l in Text(l.label).tag(l) }
                        }
                        .labelsHidden()
                    }
                    CardRow(tr("Terminal"), symbol: "terminal", color: .orange) {
                        Picker("", selection: $chrome.snapshot.termPlace) {
                            ForEach(LugarDoTerminal.allCases, id: \.self) { l in Text(l.label).tag(l) }
                        }
                        .labelsHidden()
                    }
                }
                CardNote(tr(
                    "O terminal embaixo dos arquivos deixa a largura inteira para o código. Com a barra de arquivos fechada ele volta para baixo do editor, senão sumiria junto."
                ))
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(tr("Terminal"))
                CardList {
                    CardRow(tr("Tamanho da fonte"), symbol: "textformat.size", color: .green, first: true) {
                        Text(tr("%1$@ pt", "\(Int(chrome.snapshot.termFontSize))"))
                            .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                        Stepper(
                            tr("Tamanho da fonte"),
                            value: $chrome.snapshot.termFontSize,
                            in: 9 ... 20,
                            step: 1
                        )
                        .labelsHidden().fixedSize()
                    }
                    CardRow(tr("Fonte"), symbol: "character", color: .green) {
                        Picker("", selection: $chrome.snapshot.termFont) {
                            ForEach(EditorFont.allCases, id: \.self) { f in Text(f.label).tag(f) }
                        }
                        .labelsHidden()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(tr("Painéis"))
                CardList {
                    CardRow(tr("Sidebar"), symbol: "sidebar.left", color: .orange, first: true) {
                        Toggle("", isOn: $chrome.snapshot.sideOpen).labelsHidden()
                    }
                    CardRow(tr("Agente"), symbol: "sparkles", color: .orange) {
                        Toggle("", isOn: $chrome.snapshot.agentVisible).labelsHidden()
                    }
                    CardRow(tr("Terminal"), symbol: "terminal", color: .orange) {
                        Toggle("", isOn: $chrome.snapshot.termVisible).labelsHidden()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                CardList {
                    Button { chrome.resetLayout() } label: {
                        CardRow(
                            tr("Restaurar layout padrão"),
                            symbol: "arrow.counterclockwise",
                            color: .gray,
                            first: true
                        ) {
                            Image(systemName: "chevron.right").font(.caption2.bold())
                                .foregroundStyle(theme.fgSubtle)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                CardNote(tr("Volta as larguras da sidebar e do agente e a altura do terminal."))
            }
        }
    }

    // MARK: sistema

    /// Diz onde os projetos moram e o que isso significa. Desinstalar o app apaga o
    /// container inteiro: sem iCloud, vai junto o código, o histórico git e as conversas.
    var nota: String {
        if chrome.snapshot.projectsInCloud {
            return tr(
                "Os projetos ficam no iCloud Drive: sincronizam entre aparelhos, funcionam offline e sobrevivem a desinstalar o app."
            )
        }
        // `nuvemDisponivel` e não uma pergunta ao iCloud aqui: isto é o corpo da view,
        // e a pergunta travava a folha a cada redesenho (ver `LocalDaNuvem`).
        if app.nuvemDisponivel != false {
            return tr(
                "Os projetos estão dentro do app. Desinstalar apaga tudo — código, histórico do git e conversas. Ligue o iCloud Drive, ou copie a pasta Odete pelo app Arquivos de vez em quando."
            )
        }
        return tr(
            "iCloud Drive indisponível neste aparelho; os projetos ficam dentro do app e desinstalar apaga tudo. Entre com o Apple ID, ou copie a pasta Odete pelo app Arquivos de vez em quando."
        )
    }

    @ViewBuilder
    var system: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(tr("Projetos"))
            CardList {
                CardRow(tr("Projetos no iCloud Drive"), symbol: "icloud", color: .cyan, first: true) {
                    ChaveDoICloud(comRotulo: false)
                }
            }
            AndamentoDaMudanca()
            CardNote(nota)
        }
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(tr("Atalhos e arquivos"))
            CardList {
                CardRow(
                    tr("App Atalhos"),
                    symbol: "app.badge",
                    color: .purple,
                    detail: tr("Abrir projeto, Rodar comando, Perguntar à Odete, Novo projeto"),
                    first: true
                )
                CardRow(
                    tr("Arquivos"),
                    symbol: "folder",
                    color: .purple,
                    detail: tr("Odete → Projects, aberto para outros apps")
                )
            }
        }
        HistoricoLocalAjustes()
    }

    // MARK: sobre

    @ViewBuilder
    var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardList {
                HStack(spacing: 14) {
                    BrandIcon(size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Odete").font(.title3.bold()).foregroundStyle(theme.fg)
                        Text(tr("IDE no colo · versão %1$@ (%2$@)", "\(versao)", "\(build)"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
            CardNote(
                tr(
                    "Tudo roda no iPad: JavaScriptCore com camada Node, esbuild, libgit2, Runestone e um agente que edita com patches. Sem servidores da Odete."
                )
            )
        }
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(tr("Créditos"))
            CardList {
                CardRow("IBM Plex", symbol: "textformat", color: .gray, detail: "OFL", first: true)
                CardRow(tr("Runestone e tree-sitter"), symbol: "curlybraces", color: .gray, detail: "MIT")
                CardRow(
                    "libgit2",
                    symbol: "arrow.triangle.branch",
                    color: .gray,
                    detail: tr("GPLv2 com exceção de linking")
                )
                CardRow("esbuild", symbol: "shippingbox", color: .gray, detail: "MIT")
            }
        }
    }

    var versao: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}

/// Cartão de tema: amostra real das cores, nome e descrição, selecionado com anel de destaque.
struct ThemeCard: View {
    @Environment(\.theme) private var theme
    var palette: ThemePalette
    var on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // miniatura: sidebar + editor com três linhas de "código"
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: palette.bgElevated)).frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(Color(hex: palette.syntax.keyword)).frame(width: 34, height: 4)
                        Capsule().fill(Color(hex: palette.syntax.string)).frame(width: 52, height: 4)
                        Capsule().fill(Color(hex: palette.syntax.function)).frame(width: 40, height: 4)
                        Capsule().fill(Color(hex: palette.accent)).frame(width: 18, height: 4)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: palette.bg), in: RoundedRectangle(cornerRadius: 3))
                }
                .padding(5)
                .frame(height: 56)
                .background(Color(hex: palette.bg), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(palette.label).font(OdeteFont.ui(12.5, weight: .semibold)).foregroundStyle(theme.fg)
                Text(tr(palette.blurb)).font(OdeteFont.ui(10.5)).foregroundStyle(theme.fgMuted).lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                theme.fg.opacity(theme.dark ? 0.05 : 0.04),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                on ? theme.accent : theme.fg.opacity(0.06),
                lineWidth: on ? 2 : 0.8
            ))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
