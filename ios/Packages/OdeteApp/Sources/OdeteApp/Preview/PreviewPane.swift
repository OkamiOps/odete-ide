import OdeteCore
import OdetePreview
import OdeteUI
import SwiftUI

/// Preview do app do usuário: barra de URL, viewport, reload, Safari e console.
struct PreviewPane: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var urlText = ""

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
                HeaderButton("chevron.left", label: "Voltar") { pv.back() }.disabled(!pv.canGoBack)
                HeaderButton(pv.loading ? "xmark" : "arrow.clockwise", label: "Recarregar") { pv.reload() }
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
                    ForEach(Viewport.allCases) { v in
                        Button { pv.viewport = v } label: { Label(v.label, systemImage: v.symbol) }
                    }
                } label: {
                    Image(systemName: pv.viewport.symbol).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.fgMuted).frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
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
                HeaderButton("safari", label: "Abrir no Safari") {
                    if let u = pv.url, u.scheme?.hasPrefix("http") == true {
                        openURL(u)
                    }
                }
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
            }
        }
        .onChange(of: ws.preview.url) { _, new in urlText = new?.absoluteString ?? "" }
    }

    @ViewBuilder var content: some View {
        let pv = ws.preview
        if pv.url == nil {
            VStack(spacing: 12) {
                Image(systemName: "play.rectangle").font(.system(size: 34)).foregroundStyle(theme.fgSubtle)
                Text("Nada rodando ainda").font(OdeteFont.ui(14, weight: .medium)).foregroundStyle(theme.fg)
                Text("Rode `npm run dev` no terminal, ou abra um index.html estático.")
                    .font(OdeteFont.ui(12)).foregroundStyle(theme.fgMuted).multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button { ws.run.run("npm run dev"); ws.showTerminal() } label: { Label(
                        "npm run dev",
                        systemImage: "play.fill"
                    ) }
                    .buttonStyle(.glassProminent)
                    if pv.hasIndex {
                        Button { pv.go(pv.staticURL()) } label: { Label(
                            "index.html estático",
                            systemImage: "doc.richtext"
                        ) }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                let w = pv.viewport.width.map { min($0, geo.size.width) } ?? geo.size.width
                HStack {
                    if w < geo.size.width {
                        Spacer(minLength: 0)
                    }
                    PreviewView(model: pv)
                        .frame(width: w)
                        .clipShape(RoundedRectangle(cornerRadius: w < geo.size.width ? 12 : 0, style: .continuous))
                        .overlay {
                            if w < geo.size
                                .width
                            {
                                RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.borderStrong)
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
                HeaderButton("trash", label: "Limpar console") { pv.clearConsole() }
                HeaderButton("xmark", label: "Fechar console") { pv.consoleOpen = false }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
            ScrollViewReader { proxy in
                ScrollPane {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if pv.console.isEmpty {
                            Text("console.log do seu app aparece aqui.").font(OdeteFont.mono(11))
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
                                        Text("\((f as NSString).lastPathComponent):\(l.line ?? 0)")
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
                .onChange(of: pv.console.count) {
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
