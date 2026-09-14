import OdeteCore
import OdetePreview
import OdeteSwift
import OdeteUI
import SwiftUI

/// Preview de projetos Swift: interpreta o subconjunto de SwiftUI e renderiza nativo.
struct SwiftPreviewPane: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @State private var program: Program?
    @State private var instance: ViewInstance?
    @State private var rootName: String?
    @State private var package: PlaygroundPackage?
    @State private var viewport: Viewport = .fill
    @State private var generation = 0
    @State private var showFiles = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(theme.bg)
        .onAppear { rebuild(keepState: false) }
        .onChange(of: ws.reloadTick) { rebuild(keepState: true) }
    }

    var header: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(program?.viewNames ?? [], id: \.self) { n in
                    Button { rootName = n; rebuild(keepState: false) } label: { Label(
                        n,
                        systemImage: n == rootName ? "checkmark" : "swift"
                    ) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "swift").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent)
                    Text(rootName ?? "sem View").font(OdeteFont.mono(11.5)).foregroundStyle(theme.fg).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.fgSubtle)
                }
                .padding(.horizontal, 10).frame(height: 30).background(theme.bgSubtle, in: Capsule())
            }
            .buttonStyle(.plain)
            if let p = package {
                Text(p.displayName).font(OdeteFont.ui(11)).foregroundStyle(theme.fgSubtle).lineLimit(1)
            }
            Spacer()
            HeaderButton("arrow.counterclockwise", label: "Zerar estado") { rebuild(keepState: false) }
            Menu {
                ForEach(Viewport.allCases) { v in
                    Button { viewport = v } label: { Label(v.label, systemImage: v.symbol) }
                }
            } label: {
                Image(systemName: viewport.symbol).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.fgMuted).frame(
                        width: 32,
                        height: 32
                    )
            }
            .buttonStyle(.plain)
            if let p = package, p.isPackage {
                PlaygroundButton(package: p.root)
            } else {
                Button { showFiles = true } label: { Label("Criar pacote", systemImage: "shippingbox") }
                    .buttonStyle(.glass).font(OdeteFont.ui(12))
            }
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(theme.bgElevated)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
        .alert("Pacote do Playgrounds", isPresented: $showFiles) { Button("OK") {} } message: {
            Text(
                "Crie um projeto com o template \"Swift Playground\" para ter um .swiftpm que o Swift Playgrounds abre e compila. Este projeto tem só arquivos .swift soltos, que o preview mostra mas não compila."
            )
        }
    }

    @ViewBuilder var content: some View {
        if let inst = instance {
            GeometryReader { geo in
                let w = viewport.width.map { min($0, geo.size.width) } ?? geo.size.width
                HStack {
                    if w < geo.size.width {
                        Spacer(minLength: 0)
                    }
                    SwiftRootView(instance: inst)
                        .id(generation)
                        .frame(width: w, height: geo.size.height)
                        .background(Color(UIColor.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: w < geo.size.width ? 12 : 0, style: .continuous))
                        .overlay {
                            if w < geo.size
                                .width
                            {
                                RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.borderStrong)
                            }
                        }
                        .environment(\.colorScheme, .light)
                    if w < geo.size.width {
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .background(w < geo.size.width ? theme.bgSubtle : theme.bg)
            }
            .overlay(alignment: .bottom) {
                if !ws.swiftDiagnostics.isEmpty {
                    diagBanner
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "swift").font(.system(size: 34)).foregroundStyle(theme.fgSubtle)
                Text(program == nil ? "Nenhum arquivo Swift" : "Nenhuma View encontrada").font(OdeteFont.ui(
                    14,
                    weight: .medium
                )).foregroundStyle(theme.fg)
                Text(
                    "Crie uma `struct X: View` com `var body: some View`. O preview mostra o subconjunto de SwiftUI na hora; o Playgrounds compila tudo."
                )
                .font(OdeteFont.ui(12)).foregroundStyle(theme.fgMuted).multilineTextAlignment(.center)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var diagBanner: some View {
        let d = ws.swiftDiagnostics
        let errors = d.filter { $0.kind == .error }
        return HStack(spacing: 8) {
            Image(systemName: errors.isEmpty ? "exclamationmark.triangle" : "xmark.octagon")
                .foregroundStyle(errors.isEmpty ? theme.accent : theme.danger)
            Text((errors.first ?? d.first).map { "\($0.file):\($0.line) \($0.message)" } ?? "").font(OdeteFont.mono(11))
                .foregroundStyle(theme.fg).lineLimit(2)
            Spacer()
            if d.count > 1 {
                Text("+\(d.count - 1)").font(OdeteFont.mono(10)).foregroundStyle(theme.fgSubtle)
            }
        }
        .padding(10)
        .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.border))
        .padding(10)
    }

    func rebuild(keepState: Bool) {
        let pkg = PlaygroundPackage.find(in: ws.root)
        package = pkg
        guard let pkg else { program = nil; instance = nil; ws.swiftDiagnostics = []; return }
        let files = pkg.load(projectRoot: ws.root)
        let p = Program(files: files)
        program = p
        let name = (rootName.flatMap { p.structs[$0]?.isView == true ? $0 : nil }) ?? p.rootName
        rootName = name
        var diags = p.diagnostics
        if let name, let inst = p.instance(of: name) {
            if keepState, let old = instance, old.decl.name == name {
                for (k, v) in old
                    .state
                {
                    if inst.decl.vars.first(where: { $0.name == k })?.attr == .state,
                       case .binding = v {} else if inst.state[k] != nil
                    {
                        inst.state[k] = v
                    }
                }
            }
            _ = inst.evalBody()
            diags += inst.diagnostics
            instance = inst
            generation += 1
        } else {
            instance = nil
        }
        ws.swiftDiagnostics = diags
    }
}

/// Botão "Abrir no Playgrounds": folha do sistema ancorada no próprio botão.
struct PlaygroundButton: UIViewRepresentable {
    let package: URL
    func makeUIView(context: Context) -> UIButton {
        var cfg = UIButton.Configuration.prominentGlass()
        cfg.title = "Playgrounds"
        cfg.image = UIImage(systemName: "play.fill")
        cfg.imagePadding = 4
        cfg.buttonSize = .small
        let b = UIButton(configuration: cfg)
        b.addAction(UIAction { [package] _ in
            if !PlaygroundLauncher.open(package, from: b, rect: b.bounds) {
                PlaygroundLauncher.showInFiles(package)
            }
        }, for: .touchUpInside)
        return b
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
