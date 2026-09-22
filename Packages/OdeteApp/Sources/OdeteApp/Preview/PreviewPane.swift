import OdeteCore
import OdeteI18n
import OdetePreview
import OdeteUI
import SwiftUI

/// Preview do app do usuário: barra de URL, viewport, reload, Safari e console.
struct PreviewPane: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var urlText = ""
    @State private var avisoSafari: URL?

    var body: some View {
        if ws.stack.kind == .swift {
            SwiftPreviewPane()
        } else {
            web
        }
    }

    var web: some View {
        @Bindable var pv = ws.preview
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                HeaderButton("chevron.left", label: tr("Voltar")) { pv.back() }.disabled(!pv.canGoBack)
                HeaderButton(pv.loading ? "xmark" : "arrow.clockwise", label: tr("Recarregar")) { pv.reload() }
                TextField("odete://static/index.html", text: $urlText)
                    .font(OdeteFont.mono(11))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { navigate(urlText) }
                    .padding(.horizontal, 12).frame(height: 32)
                    .glassEffect(.regular, in: Capsule())
                Menu {
                    Picker(tr("Viewport"), selection: Binding(get: { pv.viewport }, set: { pv.viewport = $0 })) {
                        ForEach(Viewport.allCases) { v in
                            Label(v.medida.map { "\(v.label) · \($0)" } ?? v.label, systemImage: v.symbol).tag(v)
                        }
                    }
                } label: {
                    Image(systemName: pv.viewport.symbol).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(pv.viewport == .fill ? theme.fgMuted : theme.accent)
                        .frame(width: 32, height: 32)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .accessibilityLabel("Viewport: \(pv.viewport.label)")
                HeaderButton("terminal", label: pv.errorCount > 0 ? "Console (\(pv.errorCount) erros)" : "Console") {
                    pv.consoleOpen.toggle()
                }
                .overlay(alignment: .topTrailing) {
                    if pv.errorCount > 0 {
                        Text("\(pv.errorCount)").font(OdeteFont.mono(9)).foregroundStyle(theme.accentFg)
                            .padding(.horizontal, 4).frame(height: 14)
                            .background(theme.danger, in: Capsule()).offset(x: 2, y: 2)
                    }
                }
                HeaderButton("safari", label: tr("Abrir no Safari")) { abrirNoSafari() }
            }
            .padding(.horizontal, Metrics.s2)
            .frame(height: 48)
            .background(theme.surface)
            content
            if pv.consoleOpen {
                PreviewConsole()
            }
        }
        .background(theme.bg)
        .onAppear { pickInitialURL() }
        .onChange(of: ws.run.previewURL) { _, new in
            if let new {
                ws.preview.go(new)
            } else {
                // Servidor parou. Sem isto o preview seguia mostrando a última página
                // renderizada, com a URL na barra, e dava a impressão de que o servidor
                // continuava no ar depois do kill.
                soltarServidorMorto()
            }
        }
        .onChange(of: ws.run.servers.count) { _, _ in soltarServidorMorto() }
        .onChange(of: ws.preview.url) { _, new in urlText = new?.absoluteString ?? "" }
        // Link para fora do projeto: o painel não navega para lá, o Safari abre.
        .onChange(of: ws.preview.pedidoExterno) { _, u in
            guard let u else { return }
            ws.preview.pedidoExterno = nil
            openURL(u)
        }
        .confirmationDialog(
            tr("O servidor só continua no ar com a Odete à vista"),
            isPresented: Binding(get: { avisoSafari != nil }, set: {
                if !$0 {
                    avisoSafari = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button(tr("Abrir assim mesmo")) {
                if let u = avisoSafari {
                    openURL(u)
                }
                avisoSafari = nil
            }
            Button(tr("Abrir e não avisar mais")) {
                chrome.snapshot.avisoSafariVisto = true
                if let u = avisoSafari {
                    openURL(u)
                }
                avisoSafari = nil
            }
            Button(tr("Cancelar"), role: .cancel) { avisoSafari = nil }
        } message: {
            Text(
                tr(
                    // swiftlint:disable:next line_length
                    "Em tela cheia o iPad suspende a Odete e a página para de responder em poucos segundos. Arraste o Safari para o lado (Split View) e o servidor continua servindo enquanto você testa."
                )
            )
        }
    }

    /// Abrir no Safari em tela cheia suspende a Odete, e com ela o servidor: medido, a
    /// página para de responder cerca de 18 segundos depois de sair. Lado a lado o
    /// servidor não é suspenso e continua servindo o tempo todo — vale dizer isso uma vez
    /// em vez de deixar a pessoa descobrir com a página morrendo na mão.
    func abrirNoSafari() {
        guard let u = ws.preview.url, u.scheme?.hasPrefix("http") == true else { return }
        if !ws.run.servers.isEmpty, !chrome.snapshot.avisoSafariVisto {
            avisoSafari = u
        } else {
            openURL(u)
        }
    }

    /// Volta para a tela de "nada rodando" quando a porta que o preview mostrava morreu.
    /// Página estática e arquivo local não são mexidos: ali não há servidor nenhum.
    func soltarServidorMorto() {
        guard let u = ws.preview.url, u.scheme?.hasPrefix("http") == true,
              let porta = u.port, u.host == "127.0.0.1" || u.host == "localhost" else { return }
        guard !ws.run.servers.contains(where: { $0.port == porta }) else { return }
        ws.preview.go(nil)
    }

    @ViewBuilder var content: some View {
        let pv = ws.preview
        if pv.url == nil {
            PreviewEmpty(
                onDev: { ws.run.run("npm run dev"); ws.showTerminal() },
                onStatic: pv.hasIndex ? { pv.go(pv.staticURL()) } : nil
            )
        } else {
            GeometryReader { geo in
                // Formatos com altura própria (16:9) são desenhados no tamanho real e
                // reduzidos para caber no painel, senão nunca daria para ver um desktop
                // inteiro numa coluna de iPad.
                if let largura = pv.viewport.width, let altura = pv.viewport.height {
                    let escala = min(1, min(geo.size.width / largura, geo.size.height / altura))
                    PreviewView(model: pv)
                        .frame(width: largura, height: altura)
                        .clipShape(RoundedRectangle(cornerRadius: 12 / escala, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12 / escala, style: .continuous)
                                .stroke(theme.borderStrong, lineWidth: 1 / escala)
                        }
                        .scaleEffect(escala)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .background(theme.bgSubtle)
                } else {
                    let w = pv.viewport.width.map { min($0, geo.size.width) } ?? geo.size.width
                    HStack {
                        if w < geo.size.width {
                            Spacer(minLength: 0)
                        }
                        PreviewView(model: pv)
                            .frame(width: w)
                            .clipShape(RoundedRectangle(
                                cornerRadius: w < geo.size.width ? 12 : 0,
                                style: .continuous
                            ))
                            .overlay {
                                if w < geo.size.width {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(theme.borderStrong)
                                }
                            }
                        if w < geo.size.width {
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .background(w < geo.size.width ? theme.bgSubtle : theme.bg)
                }
            }
        }
    }

    func navigate(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            return
        }
        if !t.contains("://") {
            t = t.hasPrefix("localhost") || t.hasPrefix("127.") ? "http://" + t : "https://" + t
        }
        if let u = URL(string: t) {
            ws.preview.go(u)
        }
    }

    func pickInitialURL() {
        let pv = ws.preview
        if pv.url == nil {
            if let u = ws.run.previewURL {
                pv.go(u)
            } else if pv.hasIndex,
                      ws.stack.kind == .html
            {
                pv.go(pv.staticURL())
            }
        }
        urlText = pv.url?.absoluteString ?? ""
    }
}

/// Console do preview: log/warn/error do app do usuário.
struct PreviewConsole: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme

    var body: some View {
        let pv = ws.preview
        VStack(spacing: 0) {
            HStack {
                Text("CONSOLE").font(OdeteFont.label).tracking(1).foregroundStyle(theme.fgSubtle)
                Spacer()
                HeaderButton("trash", label: tr("Limpar console")) { pv.clearConsole() }
                HeaderButton("xmark", label: tr("Fechar console")) { pv.consoleOpen = false }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
            ScrollViewReader { proxy in
                ScrollPane {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if pv.console.isEmpty {
                            Text(tr("console.log do seu app aparece aqui.")).font(OdeteFont.mono(11))
                                .foregroundStyle(theme.fgSubtle)
                        }
                        ForEach(pv.console) { l in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: symbol(l.level)).font(.system(size: 10))
                                    .foregroundStyle(color(l.level)).frame(width: 12).padding(
                                        .top,
                                        3
                                    )
                                Text(l.text).font(OdeteFont.mono(11)).foregroundStyle(color(l.level))
                                    .textSelection(.enabled)
                                Spacer()
                                if let f = l.file {
                                    Button { open(f, l.line) } label: {
                                        Text(tr("%1$@:%2$@", "\((f as NSString).lastPathComponent)", "\(l.line ?? 0)"))
                                            .font(OdeteFont.mono(10)).foregroundStyle(theme.fgSubtle)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .id(l.id)
                        }
                    }
                    .padding(10)
                }
                // A versão, e não a contagem: no teto de 1000 linhas a contagem para de
                // mudar e a rolagem até o fim parava junto.
                .onChange(of: pv.versaoDoConsole) {
                    if let last = pv.console.last {
                        proxy.scrollTo(
                            last.id,
                            anchor: .bottom
                        )
                    }
                }
            }
        }
        .frame(height: 160)
        .background(theme.bgElevated)
    }

    func open(_ file: String, _ line: Int?) {
        // arquivos do dev server chegam como /src/App.tsx ou /@odete/js/src/main.tsx
        var p = file.replacingOccurrences(of: "/@odete/js/", with: "").replacingOccurrences(
            of: "/@odete/css/",
            with: ""
        )
        if p.hasPrefix("/") {
            p.removeFirst()
        }
        if ws.ops.exists(p) {
            ws.open(p, line: line ?? 1)
        }
    }

    func symbol(_ l: ConsoleLine.Level) -> String {
        switch l {
        case .log: "chevron.right"; case .info: "info.circle"; case .warn: "exclamationmark.triangle"; case .error: "xmark.octagon"
        }
    }

    func color(_ l: ConsoleLine.Level) -> Color {
        switch l { case .log: theme.fgMuted; case .info: theme.fg; case .warn: theme.accent; case .error: theme.danger }
    }
}
