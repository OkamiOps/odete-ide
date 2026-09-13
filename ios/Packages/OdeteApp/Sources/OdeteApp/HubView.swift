import OdeteCore
import OdeteFiles
import OdeteUI
import SwiftUI

/// Hub de projetos: grade de cartões, criar, renomear, duplicar, apagar, abrir.
struct HubView: View {
    @Environment(AppModel.self) private var app
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var creating = false
    @State private var renaming: Project?
    @State private var deleting: Project?
    @State private var newName = ""

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            ScrollView {
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
                                ProjectCard(project: p, root: app.store.url(for: p))
                                    .onTapGesture { app.open(p, chrome: chrome) }
                                    .contextMenu {
                                        Button("Abrir", systemImage: "arrow.up.forward.square") { app.open(
                                            p,
                                            chrome: chrome
                                        ) }
                                        Button("Renomear", systemImage: "pencil") { newName = p.name; renaming = p }
                                        Button("Duplicar", systemImage: "plus.square.on.square") { app.duplicate(p) }
                                        Divider()
                                        Button("Apagar", systemImage: "trash", role: .destructive) { deleting = p }
                                    }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $creating) { NewProjectSheet() }
        .alert("Renomear projeto", isPresented: Binding(get: { renaming != nil }, set: {
            if !$0 {
                renaming = nil
            }
        })) {
            TextField("Nome", text: $newName)
            Button("Renomear") {
                if let p = renaming {
                    app.rename(p, to: newName)
                }; renaming = nil
            }
            Button("Cancelar", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Apagar \"\(deleting?.name ?? "")\"?",
            isPresented: Binding(get: { deleting != nil }, set: {
                if !$0 {
                    deleting = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button("Apagar projeto", role: .destructive) {
                if let p = deleting {
                    app.delete(p)
                }; deleting = nil
            }
            Button("Cancelar", role: .cancel) { deleting = nil }
        } message: {
            Text("Os arquivos saem deste iPad. Não dá para desfazer.")
        }
        .alert("Erro", isPresented: Binding(get: { app.error != nil }, set: {
            if !$0 {
                app.error = nil
            }
        })) {
            Button("OK") { app.error = nil }
        } message: { Text(app.error ?? "") }
    }

    var header: some View {
        HStack(alignment: .center, spacing: 14) {
            BrandIcon(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Wordmark(height: 20)
                Text(sizeClass == .compact ? "IDE no colo." : "IDE no colo. Seus projetos, neste iPad.")
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
                Label("Tema", systemImage: "paintpalette")
                    .labelStyle(sizeClass == .compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            }
            .buttonStyle(.glass)
            Button { creating = true } label: {
                Label("Novo projeto", systemImage: "plus")
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
            Text("Bem-vindo à Odete")
                .font(OdeteFont.ui(26, weight: .semibold))
                .foregroundStyle(theme.fg)
            Text(
                "Uma IDE que roda inteira no iPad: arquivos, git, terminal, preview e um agente que edita o projeto. Sem Mac, sem servidor."
            )
            .font(OdeteFont.ui(14))
            .foregroundStyle(theme.fgMuted)
            .frame(maxWidth: 520, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Crie um projeto: em branco, Vite + React, Astro ou Swift Playground.")
                step(2, "Edite na árvore e no editor. Salva sozinho.")
                step(3, "Os projetos ficam em Arquivos → Odete, abertos para o Playgrounds e o Working Copy.")
            }
            Button(action: onCreate) {
                Label("Criar o primeiro projeto", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(theme.border))
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

struct ProjectCard: View {
    @Environment(\.theme) private var theme
    var project: Project
    var root: URL

    var body: some View {
        let stack = stackOf()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol(stack))
                    .font(.system(size: 18))
                    .foregroundStyle(theme.accent)
                    .frame(width: 34, height: 34)
                    .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Spacer()
                Text(stack.label)
                    .font(OdeteFont.mono(10))
                    .foregroundStyle(theme.fgMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.bgSubtle, in: Capsule())
            }
            Text(project.name)
                .font(OdeteFont.ui(15, weight: .semibold))
                .foregroundStyle(theme.fg)
                .lineLimit(1)
            Text(when)
                .font(OdeteFont.ui(11))
                .foregroundStyle(theme.fgSubtle)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(theme.border))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .hoverEffect(.lift)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    var when: String {
        let d = project.lastOpenedAt ?? project.createdAt
        return (project.lastOpenedAt == nil ? "criado " : "aberto ") + d.formatted(.relative(presentation: .named))
    }

    func stackOf() -> Stack {
        let tree = try? FileTreeBuilder.build(at: root)
        let pkg = try? Data(contentsOf: root.appending(path: "package.json"))
        return Stack.detect(paths: tree?.allFiles().map(\.path) ?? [], packageJSON: pkg)
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
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") {
                    TextField("meu-app", text: $name)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(create)
                }
                Section("Modelo") {
                    ForEach(Template.allCases) { t in
                        Button {
                            template = t
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: t.symbol).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.label).foregroundStyle(.primary)
                                    Text(t.blurb).font(.footnote).foregroundStyle(.secondary)
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
            .navigationTitle("Novo projeto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Criar", action: create).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let p = app.create(name: n, template: template) else { return }
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
