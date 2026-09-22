import OdeteCore
import OdeteFiles
import OdeteI18n
import OdeteUI
import SwiftUI
import UniformTypeIdentifiers

/// Hub de projetos: grade de cartões, criar, renomear, duplicar, apagar, abrir.
struct HubView: View {
    @Environment(AppModel.self) private var app
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var creating = false
    @State private var cloning = false
    @State private var importing = false
    @State private var renaming: Project?
    @State private var deleting: Project?
    @State private var newName = ""
    @State private var cartoes = CartoesDoHub()

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            RadialGradient(
                colors: [theme.accent.opacity(theme.dark ? 0.16 : 0.10), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            ScrollPane {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if app.projects.isEmpty {
                        WelcomeView { creating = true }
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 14)],
                            spacing: 14
                        ) {
                            ForEach(app.projects) { p in
                                ProjectCard(project: p, dados: cartoes.dados[p.id])
                                    .onAppear { cartoes.carregar(p, app: app) }
                                    .onTapGesture { app.open(p, chrome: chrome) }
                                    .contextMenu {
                                        Button(tr("Abrir"), systemImage: "arrow.up.forward.square") { app.open(
                                            p,
                                            chrome: chrome
                                        ) }
                                        if !p.external {
                                            Button(tr("Renomear"), systemImage: "pencil") {
                                                newName = p.name; renaming = p
                                            }
                                            Button(tr("Duplicar"), systemImage: "plus.square.on.square") {
                                                app.duplicate(p)
                                            }
                                        }
                                        // O zip sai quando o destino é escolhido, fora do ator
                                        // principal — ver `AppModel.compartilhavel`.
                                        ShareLink(
                                            item: app.compartilhavel(p),
                                            preview: SharePreview("\(p.name).zip")
                                        ) {
                                            Label(tr("Compartilhar (.zip)"), systemImage: "square.and.arrow.up")
                                        }
                                        Divider()
                                        if p.external {
                                            Button(
                                                tr("Remover do hub"),
                                                systemImage: "minus.circle",
                                                role: .destructive
                                            ) {
                                                app.delete(p)
                                            }
                                        } else {
                                            Button(tr("Apagar"), systemImage: "trash", role: .destructive) {
                                                deleting = p
                                            }
                                        }
                                    }
                            }
                            // Fecha a grade em vez de deixar a fila pela metade, e é o
                            // segundo caminho para criar — o botão do cabeçalho fica no
                            // canto oposto da tela.
                            CartaoNovo { creating = true }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
        }
        // No hub nenhum projeto está aberto: o acesso às pastas externas que o workspace
        // abriu volta a ser fechado aqui, em vez de ficar aberto até o app sair.
        .onAppear { app.external.liberarTodos(exceto: app.workspace?.project.id) }
        .sheet(isPresented: $creating) { NewProjectSheet() }
        .sheet(isPresented: $cloning) { CloneSheet() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .zip]) { result in
            if case let .success(url) = result {
                app.importURL(url, chrome: chrome)
            }
        }
        .alert(tr("Renomear projeto"), isPresented: Binding(get: { renaming != nil }, set: {
            if !$0 {
                renaming = nil
            }
        })) {
            TextField(tr("Nome"), text: $newName)
            Button(tr("Renomear")) {
                if let p = renaming {
                    app.rename(p, to: newName)
                }; renaming = nil
            }
            Button(tr("Cancelar"), role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            tr("Apagar \"%1$@\"?", "\(deleting?.name ?? "")"),
            isPresented: Binding(get: { deleting != nil }, set: {
                if !$0 {
                    deleting = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button(tr("Apagar projeto"), role: .destructive) {
                if let p = deleting {
                    app.delete(p)
                }; deleting = nil
            }
            Button(tr("Cancelar"), role: .cancel) { deleting = nil }
        } message: {
            Text(tr("Os arquivos saem deste iPad. Não dá para desfazer."))
        }
        .alert(tr("Erro"), isPresented: Binding(get: { app.error != nil }, set: {
            if !$0 {
                app.error = nil
            }
        })) {
            Button(tr("OK")) { app.error = nil }
        } message: { Text(app.error ?? "") }
    }

    var header: some View {
        HStack(alignment: .center, spacing: 14) {
            BrandIcon(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Wordmark(height: 20)
                Text(sizeClass == .compact ? tr("IDE no colo.") : tr("IDE no colo. Seus projetos, neste iPad."))
                    .font(OdeteFont.ui(12))
                    .foregroundStyle(theme.fgMuted)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                ForEach(ThemePalette.all) { p in
                    Button(p.label) { chrome.snapshot.theme = p.id }
                }
            } label: {
                Label(tr("Tema"), systemImage: "paintpalette")
                    .labelStyle(sizeClass == .compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            }
            .buttonStyle(.glass)
            Button { importing = true } label: {
                Label(tr("Abrir pasta"), systemImage: "folder")
                    .labelStyle(sizeClass == .compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            }
            .buttonStyle(.glass)
            Button { cloning = true } label: {
                Label(tr("Clonar"), systemImage: "arrow.down.circle")
                    .labelStyle(sizeClass == .compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            }
            .buttonStyle(.glass)
            Button { creating = true } label: {
                Label(tr("Novo projeto"), systemImage: "plus")
                    .labelStyle(sizeClass == .compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}

struct WelcomeView: View {
    @Environment(\.theme) private var theme
    var onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("Bem-vindo à Odete"))
                .font(OdeteFont.ui(26, weight: .semibold))
                .foregroundStyle(theme.fg)
            Text(
                tr(
                    "Uma IDE que roda inteira no iPad: arquivos, git, terminal, preview e um agente que edita o projeto. Sem Mac, sem servidor."
                )
            )
            .font(OdeteFont.ui(14))
            .foregroundStyle(theme.fgMuted)
            .frame(maxWidth: 520, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                step(1, tr("Crie um projeto: em branco, Vite + React, Astro ou Swift Playground."))
                step(2, tr("Edite na árvore e no editor. Salva sozinho."))
                step(3, tr("Os projetos ficam em Arquivos → Odete, abertos para o Playgrounds e o Working Copy."))
            }
            Button(action: onCreate) {
                Label(tr("Criar o primeiro projeto"), systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(Metrics.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: Metrics.rFloat, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.rFloat, style: .continuous).stroke(
            theme.separator,
            lineWidth: 0.5
        ))
        .shadow(color: .black.opacity(theme.dark ? 0.25 : 0.08), radius: 16, y: 6)
    }

    func step(_ n: Int, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(OdeteFont.mono(11, weight: .semibold))
                .foregroundStyle(theme.accentFg)
                .frame(width: 20, height: 20)
                .background(theme.accent, in: Circle())
            Text(s).font(OdeteFont.ui(13)).foregroundStyle(theme.fg)
        }
    }
}

/// O último cartão da grade: criar um projeto.
struct CartaoNovo: View {
    @Environment(\.theme) private var theme
    var acao: () -> Void

    var body: some View {
        Button(action: acao) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 40, height: 40)
                    .background(theme.accent.opacity(0.14), in: RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    ))
                Text(tr("Novo projeto")).font(OdeteFont.ui(14, weight: .medium)).foregroundStyle(theme.fgMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)
            .background(theme.surface.opacity(0.4), in: RoundedRectangle(
                cornerRadius: Metrics.rCard,
                style: .continuous
            ))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.rCard, style: .continuous)
                    .strokeBorder(theme.separator, style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.rCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
    }
}

/// O que o cartão do hub mostra e que vem do disco: a pilha do projeto e a primeira linha
/// do README.
struct DadosDoCartao: Sendable, Equatable {
    var stack: Stack
    var blurb: String?

    /// Lê da pasta do projeto. Percorre a árvore inteira, então nunca no ator principal.
    static func ler(_ raiz: URL) -> DadosDoCartao {
        let tree = try? FileTreeBuilder.build(at: raiz)
        let pkg = try? Data(contentsOf: raiz.appending(path: "package.json"))
        let stack = Stack.detect(paths: tree?.allFiles().map(\.path) ?? [], packageJSON: pkg)
        return DadosDoCartao(stack: stack, blurb: descricao(raiz))
    }

    /// Primeira linha de texto do README, como descrição.
    static func descricao(_ raiz: URL) -> String? {
        guard let s = try? String(contentsOf: raiz.appending(path: "README.md"), encoding: .utf8) else { return nil }
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("|") || t.hasPrefix("`") {
                continue
            }
            return String(t.prefix(90))
        }
        return nil
    }
}

/// Os dados dos cartões do hub, lidos fora do ator principal e guardados.
///
/// O cartão lia o README e percorria a árvore inteira do projeto — para descobrir a pilha —
/// dentro do próprio corpo, no ator principal, e o corpo de cada cartão roda de novo a
/// cada vez que a grade se refaz. Com vinte projetos, abrir o hub era ler vinte árvores
/// antes do primeiro quadro.
@MainActor
@Observable
final class CartoesDoHub {
    private(set) var dados: [UUID: DadosDoCartao] = [:]
    @ObservationIgnored private var pedidos: Set<UUID> = []

    func carregar(_ p: Project, app: AppModel) {
        guard !pedidos.contains(p.id) else { return }
        pedidos.insert(p.id)
        let id = p.id
        let local = p.external ? nil : app.store.url(for: p)
        // Pasta de fora é lida com o acesso aberto só durante a leitura.
        let externo = p.external ? app.external : nil
        Task.detached(priority: .utility) {
            let d: DadosDoCartao? = if let local {
                DadosDoCartao.ler(local)
            } else {
                externo?.comAcesso(id) { DadosDoCartao.ler($0) } ?? nil
            }
            guard let d else { return }
            await self.guardar(d, para: id)
        }
    }

    private func guardar(_ d: DadosDoCartao, para id: UUID) {
        dados[id] = d
    }
}

struct ProjectCard: View {
    @Environment(\.theme) private var theme
    var project: Project
    /// Pilha e descrição; `nil` enquanto a leitura não chegou — ver `CartoesDoHub`.
    var dados: DadosDoCartao?

    var body: some View {
        let stack = dados?.stack
        let cor = stack.map(stackColor) ?? theme.fgSubtle
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: stack.map(symbol) ?? "folder")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(cor)
                    .frame(width: 40, height: 40)
                    .background(
                        cor.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                Spacer()
                if project.external {
                    Pill(tr("externo"), on: false)
                }
                if let stack {
                    Pill(stack.label, on: true, color: stackColor(stack))
                }
            }
            .padding(.bottom, 2)
            Text(project.name)
                .font(OdeteFont.ui(16, weight: .semibold))
                .foregroundStyle(theme.fg)
                .lineLimit(1)
            if let blurb = dados?.blurb {
                Text(blurb).font(OdeteFont.ui(12)).foregroundStyle(theme.fgMuted).lineLimit(2).fixedSize(
                    horizontal: false,
                    vertical: true
                )
            }
            // Empurra a data para o rodapé: sem isto, um projeto sem descrição ficava
            // com o cartão mais baixo que o vizinho e a grade saía dentada.
            Spacer(minLength: 6)
            Text(when)
                .font(OdeteFont.ui(11))
                .foregroundStyle(theme.fgSubtle)
        }
        .padding(Metrics.s4)
        .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: Metrics.rCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.rCard, style: .continuous).stroke(
            theme.separator,
            lineWidth: 0.5
        ))
        .shadow(color: .black.opacity(theme.dark ? 0.25 : 0.08), radius: 12, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.rCard, style: .continuous))
        .hoverEffect(.lift)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    var when: String {
        let d = project.lastOpenedAt ?? project.createdAt
        let rel = d.noIdioma(.relative(presentation: .named))
        return project.lastOpenedAt == nil ? tr("criado %1$@", rel) : tr("aberto %1$@", rel)
    }

    func stackColor(_ s: Stack) -> Color {
        switch s.kind {
        case .swift: Color(hex: "#f05138")
        case .api: Color(hex: "#e0234e")
        case .ssr: Color(hex: "#bc52ee")
        case .spa: Color(hex: "#ffc820")
        case .html: Color(hex: "#7c9cff")
        }
    }

    func symbol(_ s: Stack) -> String {
        switch s.kind {
        case .swift: "swift"
        case .api: "server.rack"
        case .ssr: "globe"
        case .spa: "bolt"
        case .html: "doc.richtext"
        }
    }
}

struct NewProjectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template: Template = .blank
    @State private var pasta: URL?
    @State private var escolhendoPasta = false
    @FocusState private var focused: Bool

    /// Onde o projeto nasce quando a pessoa não escolhe nada.
    var padrao: String {
        chrome.snapshot.projectsInCloud ? tr("iCloud Drive") : tr("Dentro do app")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("Nome")) {
                    TextField("meu-app", text: $name)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(create)
                }
                // Onde o projeto vai morar. Antes não havia escolha: tudo nascia na raiz
                // do app, e quem trabalha num SSD externo ou troca de máquina ficava sem
                // saída depois.
                Section(tr("Onde")) {
                    Button {
                        pasta = nil
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: chrome.snapshot.projectsInCloud ? "icloud" : "iphone")
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tr("Pasta da Odete")).foregroundStyle(.primary)
                                Text(padrao).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if pasta == nil {
                                Image(systemName: "checkmark").foregroundStyle(theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        escolhendoPasta = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.badge.plus").frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tr("Outra pasta…")).foregroundStyle(.primary)
                                Text(pasta?.lastPathComponent
                                    ?? tr("Arquivos, iCloud, um SSD externo"))
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if pasta != nil {
                                Image(systemName: "checkmark").foregroundStyle(theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                // Chave própria: "Modelo" também é o modelo de IA no compositor, e em inglês
                // um é "Template" e o outro é "Model".
                Section(tr("Modelo do projeto")) {
                    ForEach(Template.allCases) { t in
                        Button {
                            template = t
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: t.symbol).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.label).foregroundStyle(.primary)
                                    Text(tr(t.blurb)).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if template == t {
                                    Image(systemName: "checkmark").foregroundStyle(theme.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .fileImporter(isPresented: $escolhendoPasta, allowedContentTypes: [.folder]) { r in
                if case let .success(u) = r {
                    pasta = u
                }
            }
            .navigationTitle(tr("Novo projeto"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Cancelar")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Criar"), action: create).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        // Com a escolha de local são três seções: no detent médio o modelo ficava fora
        // da tela, e a pessoa criava tudo em branco sem ver que havia opção.
        .presentationDetents([.large])
    }

    func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let criado = pasta.map { app.create(name: n, template: template, em: $0) }
            ?? app.create(name: n, template: template)
        guard let p = criado else { return }
        dismiss()
        app.open(p, chrome: chrome)
    }
}

/// Apaga o tipo do estilo de rótulo para escolher em runtime.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init(_ style: some LabelStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
