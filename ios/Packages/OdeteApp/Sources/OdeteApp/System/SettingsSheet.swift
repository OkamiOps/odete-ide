import OdeteCore
import OdeteUI
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, editor, layout, git, ai, system, about
    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .appearance: "Aparência"
        case .editor: "Editor"
        case .layout: "Layout"
        case .git: "Git e GitHub"
        case .ai: "Contas de IA"
        case .system: "Sistema"
        case .about: "Sobre"
        }
    }

    var symbol: String {
        switch self {
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
                    .navigationTitle("Ajustes")
                    .navigationDestination(for: SettingsSection.self) { s in
                        SettingsContent(section: s).navigationTitle(s.label)
                    }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
                }
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ajustes").font(OdeteFont.ui(20, weight: .semibold)).foregroundStyle(theme.fg)
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
                            Button("OK") { dismiss() }.buttonStyle(.glassProminent).controlSize(.small)
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
    var section: SettingsSection

    var body: some View {
        ScrollPane {
            VStack(alignment: .leading, spacing: 16) {
                switch section {
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

    // MARK: aparência

    var appearance: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Tema")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(ThemePalette.all) { p in
                    ThemeCard(palette: p, on: p.id == chrome.snapshot.theme) {
                        withAnimation(.snappy(duration: 0.2)) { chrome.snapshot.theme = p.id }
                    }
                }
            }
        }
    }

    // MARK: editor

    var editor: some View {
        @Bindable var chrome = chrome
        return Group {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Texto")
                CardList {
                    CardRow("Tamanho da fonte", symbol: "textformat.size", color: .blue, first: true) {
                        // O rótulo do Stepper fica escondido; o valor vai ao lado, como nos
                        // Ajustes do sistema.
                        Text("\(Int(chrome.snapshot.editor.fontSize)) pt")
                            .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                        Stepper("Tamanho da fonte", value: $chrome.snapshot.editor.fontSize, in: 10 ... 22, step: 1)
                            .labelsHidden()
                            .fixedSize()
                    }
                    CardRow("Altura da linha", symbol: "arrow.up.and.down.text.horizontal", color: .blue) {
                        Picker("", selection: $chrome.snapshot.editor.lineHeight) {
                            Text("Compacta").tag(1.1)
                            Text("Normal").tag(1.25)
                            Text("Arejada").tag(1.45)
                        }
                        .labelsHidden()
                    }
                    CardRow("Quebrar linhas", symbol: "text.append", color: .blue) {
                        Toggle("", isOn: $chrome.snapshot.editor.wrap).labelsHidden()
                    }
                    CardRow("Indentação", symbol: "increase.indent", color: .blue) {
                        Picker("", selection: $chrome.snapshot.editor.tabWidth) {
                            Text("2 espaços").tag(2)
                            Text("4 espaços").tag(4)
                            Text("8 espaços").tag(8)
                        }
                        .labelsHidden()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Exibição")
                CardList {
                    CardRow("Números de linha", symbol: "list.number", color: .indigo, first: true) {
                        Toggle("", isOn: $chrome.snapshot.editor.lineNumbers).labelsHidden()
                    }
                    CardRow("Minimapa", symbol: "map", color: .indigo) {
                        Picker("", selection: $chrome.snapshot.editor.minimap) {
                            Text("Desligado").tag(MinimapSize.off)
                            Text("Pequeno").tag(MinimapSize.s)
                            Text("Médio").tag(MinimapSize.m)
                            Text("Grande").tag(MinimapSize.l)
                        }
                        .labelsHidden()
                    }
                    CardRow(
                        "Destacar linha atual",
                        symbol: "text.line.first.and.arrowtriangle.forward",
                        color: .indigo
                    ) {
                        Toggle("", isOn: $chrome.snapshot.editor.highlightLine).labelsHidden()
                    }
                    CardRow("Guias de indentação", symbol: "rectangle.split.3x1", color: .indigo) {
                        Toggle("", isOn: $chrome.snapshot.editor.indentGuides).labelsHidden()
                    }
                    CardRow("Mostrar espaços e tabs", symbol: "space", color: .indigo) {
                        Toggle("", isOn: $chrome.snapshot.editor.showWhitespace).labelsHidden()
                    }
                    CardRow("Mostrar quebras de linha", symbol: "return", color: .indigo) {
                        Toggle("", isOn: $chrome.snapshot.editor.showLineBreaks).labelsHidden()
                    }
                    CardRow("Guia de página", symbol: "ruler", color: .indigo) {
                        Picker("", selection: $chrome.snapshot.editor.pageGuide) {
                            Text("Nenhuma").tag(0)
                            Text("80 colunas").tag(80)
                            Text("100 colunas").tag(100)
                            Text("120 colunas").tag(120)
                        }
                        .labelsHidden()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Edição")
                CardList {
                    CardRow("Fechar pares automaticamente", symbol: "parentheses", color: .teal, first: true) {
                        Toggle("", isOn: $chrome.snapshot.editor.autoClosePairs).labelsHidden()
                    }
                    CardRow("Salvar automaticamente", symbol: "square.and.arrow.down", color: .teal) {
                        Toggle("", isOn: $chrome.snapshot.editor.autoSave).labelsHidden()
                    }
                }
                CardNote(
                    "O salvamento automático espera 1 s depois de você parar de digitar. Sem ele, ⌘S ou o botão Salvar."
                )
            }
        }
    }

    // MARK: layout

    var layout: some View {
        @Bindable var chrome = chrome
        return Group {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Painéis")
                CardList {
                    CardRow("Sidebar", symbol: "sidebar.left", color: .orange, first: true) {
                        Toggle("", isOn: $chrome.snapshot.sideOpen).labelsHidden()
                    }
                    CardRow("Agente", symbol: "sparkles", color: .orange) {
                        Toggle("", isOn: $chrome.snapshot.agentVisible).labelsHidden()
                    }
                    CardRow("Terminal", symbol: "terminal", color: .orange) {
                        Toggle("", isOn: $chrome.snapshot.termVisible).labelsHidden()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                CardList {
                    Button { chrome.resetLayout() } label: {
                        CardRow(
                            "Restaurar layout padrão",
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
                CardNote("Volta as larguras da sidebar e do agente e a altura do terminal.")
            }
        }
    }

    // MARK: sistema

    /// Diz onde os projetos moram e o que isso significa. Desinstalar o app apaga o
    /// container inteiro: sem iCloud, vai junto o código, o histórico git e as conversas.
    var nota: String {
        if chrome.snapshot.projectsInCloud {
            return "Os projetos ficam no iCloud Drive: sincronizam entre aparelhos, "
                + "funcionam offline e sobrevivem a desinstalar o app."
        }
        if app.cloudAvailable {
            return "Os projetos estão dentro do app. Desinstalar apaga tudo — código, histórico do git "
                + "e conversas. Ligue o iCloud Drive, ou copie a pasta Odete pelo app Arquivos de vez em quando."
        }
        return "iCloud Drive indisponível neste aparelho; os projetos ficam dentro do app e desinstalar "
            + "apaga tudo. Entre com o Apple ID, ou copie a pasta Odete pelo app Arquivos de vez em quando."
    }

    @ViewBuilder
    var system: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Projetos")
            CardList {
                CardRow("Projetos no iCloud Drive", symbol: "icloud", color: .cyan, first: true) {
                    Toggle("", isOn: Binding(
                        get: { chrome.snapshot.projectsInCloud },
                        set: { chrome.snapshot.projectsInCloud = app.setCloud($0) }
                    ))
                    .labelsHidden()
                    .disabled(!app.cloudAvailable && !chrome.snapshot.projectsInCloud)
                }
            }
            CardNote(nota)
        }
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Atalhos e arquivos")
            CardList {
                CardRow(
                    "Atalhos",
                    symbol: "app.badge",
                    color: .purple,
                    detail: "Abrir projeto, Rodar comando, Perguntar à Odete, Novo projeto",
                    first: true
                )
                CardRow(
                    "Arquivos",
                    symbol: "folder",
                    color: .purple,
                    detail: "Odete → Projects, aberto para outros apps"
                )
            }
        }
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
                        Text("IDE no colo · versão \(versao) (\(build))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
            CardNote(
                "Tudo roda no iPad: JavaScriptCore com camada Node, esbuild, libgit2, Runestone e um agente que edita com patches. Sem servidores da Odete."
            )
        }
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Créditos")
            CardList {
                CardRow("IBM Plex", symbol: "textformat", color: .gray, detail: "OFL", first: true)
                CardRow("Runestone e tree-sitter", symbol: "curlybraces", color: .gray, detail: "MIT")
                CardRow(
                    "libgit2",
                    symbol: "arrow.triangle.branch",
                    color: .gray,
                    detail: "GPLv2 com exceção de linking"
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
                Text(palette.blurb).font(OdeteFont.ui(10.5)).foregroundStyle(theme.fgMuted).lineLimit(1)
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
