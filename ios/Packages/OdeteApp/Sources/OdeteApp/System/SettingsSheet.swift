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
    }
}

struct SettingsContent: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    var section: SettingsSection

    var body: some View {
        @Bindable var chrome = chrome
        Form {
            switch section {
            case .appearance:
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                        ForEach(ThemePalette.all) { p in ThemeCard(palette: p, on: p.id == chrome.snapshot.theme) {
                            withAnimation(.snappy(duration: 0.2)) { chrome.snapshot.theme = p.id }
                        } }
                    }
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                } header: { Text("Tema") }
            case .editor:
                Section("Texto") {
                    Stepper(value: $chrome.snapshot.editor.fontSize, in: 10 ... 22, step: 1) {
                        row("Tamanho da fonte", "\(Int(chrome.snapshot.editor.fontSize)) pt")
                    }
                    Picker("Altura da linha", selection: $chrome.snapshot.editor.lineHeight) {
                        Text("Compacta").tag(1.1); Text("Normal").tag(1.25); Text("Arejada").tag(1.45)
                    }
                    Toggle("Quebrar linhas", isOn: $chrome.snapshot.editor.wrap)
                    Picker("Indentação", selection: $chrome.snapshot.editor.tabWidth) {
                        Text("2 espaços").tag(2); Text("4 espaços").tag(4); Text("8 espaços").tag(8)
                    }
                }
                Section("Exibição") {
                    Toggle("Números de linha", isOn: $chrome.snapshot.editor.lineNumbers)
                    Toggle("Destacar linha atual", isOn: $chrome.snapshot.editor.highlightLine)
                    Toggle("Guias de indentação", isOn: $chrome.snapshot.editor.indentGuides)
                    Toggle("Mostrar espaços e tabs", isOn: $chrome.snapshot.editor.showWhitespace)
                    Toggle("Mostrar quebras de linha", isOn: $chrome.snapshot.editor.showLineBreaks)
                    Picker("Guia de página", selection: $chrome.snapshot.editor.pageGuide) {
                        Text("Nenhuma").tag(0); Text("80 colunas").tag(80); Text("100 colunas")
                            .tag(100); Text("120 colunas").tag(120)
                    }
                }
                Section("Edição") {
                    Toggle("Fechar pares automaticamente", isOn: $chrome.snapshot.editor.autoClosePairs)
                    Toggle("Salvar automaticamente", isOn: $chrome.snapshot.editor.autoSave)
                    Text(
                        "O salvamento automático espera 1 s depois de parar de digitar. Sem ele, ⌘S ou o botão Salvar."
                    )
                    .font(OdeteFont.ui(11.5)).foregroundStyle(theme.fgMuted)
                }
            case .layout:
                Section("Painéis") {
                    Toggle("Sidebar", isOn: $chrome.snapshot.sideOpen)
                    Toggle("Agente", isOn: $chrome.snapshot.agentVisible)
                    Toggle("Terminal", isOn: $chrome.snapshot.termVisible)
                }
                Section {
                    Button("Restaurar layout padrão") { chrome.resetLayout() }
                    Text("Volta as larguras da sidebar, do agente e a altura do terminal.")
                        .font(OdeteFont.ui(11.5)).foregroundStyle(theme.fgMuted)
                }
            case .git:
                Section { AccountsSettings() }
            case .ai:
                Section { AIAccountsSettings() }
            case .system:
                Section("Projetos") {
                    Toggle("Projetos no iCloud Drive", isOn: Binding(
                        get: { chrome.snapshot.projectsInCloud },
                        set: { chrome.snapshot.projectsInCloud = app.setCloud($0) }
                    ))
                    .disabled(!app.cloudAvailable && !chrome.snapshot.projectsInCloud)
                    Text(app.cloudAvailable
                        ? "Move a pasta Projects para o iCloud Drive; continua funcionando offline."
                        :
                        "iCloud Drive indisponível neste dispositivo (entre com o Apple ID ou habilite o iCloud Drive).")
                        .font(OdeteFont.ui(11.5)).foregroundStyle(theme.fgMuted)
                }
                Section("Atalhos") {
                    Text("No app Atalhos: Abrir projeto, Rodar comando, Perguntar à Odete e Novo projeto.")
                        .font(OdeteFont.ui(12.5)).foregroundStyle(theme.fg)
                    Text("Os projetos locais ficam em Arquivos → Odete → Projects e podem ser abertos por outros apps.")
                        .font(OdeteFont.ui(11.5)).foregroundStyle(theme.fgMuted)
                }
            case .about:
                Section {
                    HStack(spacing: 14) {
                        BrandIcon(size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Odete").font(OdeteFont.ui(18, weight: .semibold)).foregroundStyle(theme.fg)
                            Text(
                                "IDE no colo · versão \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))"
                            )
                            .font(OdeteFont.ui(12)).foregroundStyle(theme.fgMuted)
                        }
                    }
                    .padding(.vertical, 6)
                    Text(
                        "Tudo roda no iPad: JavaScriptCore com camada Node, esbuild, libgit2, Runestone e um agente que edita com patches. Sem servidores da Odete."
                    )
                    .font(OdeteFont.ui(12.5)).foregroundStyle(theme.fg)
                }
                Section("Créditos") {
                    Text(
                        "IBM Plex (OFL) · Runestone e tree-sitter (MIT) · libgit2 (GPLv2 com exceção de linking) · esbuild (MIT)"
                    )
                    .font(OdeteFont.ui(11.5)).foregroundStyle(theme.fgMuted)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .font(OdeteFont.ui(13.5))
        .foregroundStyle(theme.fg)
        .tint(theme.accent)
    }

    func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer()
            Text(value).font(OdeteFont.mono(12)).foregroundStyle(theme.fgMuted).contentTransition(.numericText())
        }
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
