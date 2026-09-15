import OdeteCore
import OdeteI18n
import OdeteUI
import SwiftUI

/// Barra de status do workspace: branch, problemas, posição do cursor, indentação, codificação, linguagem.
struct StatusBar: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    /// Quanto detalhe cabe. Não é medida: é o `ViewThatFits` escolhendo a maior versão
    /// que couber, porque um limiar fixo de largura mantinha tudo e deixava cada rótulo
    /// virar reticências — "maste…", "sem pr…", "Ln 1, Co…".
    enum Nivel { case completo, medio, minimo

        var roomy: Bool {
            self == .completo
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            conteudo(.completo)
            conteudo(.medio)
            conteudo(.minimo)
        }
        .padding(.horizontal, Metrics.s2)
        .frame(height: 26)
        .font(OdeteFont.mono(11))
        .lineLimit(1)
    }

    @ViewBuilder
    func conteudo(_ nivel: Nivel) -> some View {
        @Bindable var chrome = chrome
        let errors = ws.problemCounts
        let roomy = nivel.roomy
        HStack(spacing: 2) {
            if ws.git.isRepo {
                item(symbol: "arrow.triangle.branch", text: branchText, tint: theme.accent) {
                    chrome.snapshot.side = .git
                    chrome.snapshot.sideOpen = true
                }
                .help(tr("Git · abrir painel"))
            }
            item(
                symbol: errors.errors > 0 ? "xmark.octagon" : errors
                    .warnings > 0 ? "exclamationmark.triangle" : "checkmark.circle",
                text: errors.errors == 0 && errors
                    .warnings == 0 ? (roomy ? tr("sem problemas") : nil) : "\(errors.errors) ⊗ \(errors.warnings) △",
                tint: errors.errors > 0 ? theme.danger : errors.warnings > 0 ? theme.accent : theme.ok
            ) {
                chrome.snapshot.side = .problems
                chrome.snapshot.sideOpen = true
            }
            .help(tr("Problemas"))
            if ws.agent.running {
                item(symbol: "sparkles", text: tr("agente trabalhando"), tint: theme.accent) {
                    chrome.snapshot.agentVisible = true
                }
                .symbolEffect(.pulse)
            }
            if !ws.run.servers.isEmpty {
                item(
                    symbol: "bolt.horizontal.circle",
                    text: ws.run.servers.map { ":\($0.port)" }.joined(separator: " "),
                    tint: theme.ok
                ) {
                    chrome.snapshot.center = .preview
                }
                .help(tr("Servidores no ar · abrir preview"))
            }
            Spacer(minLength: Metrics.s2)
            if let path = ws.active, ws.naoEhTexto.contains(path) {
                // Imagem, PDF, banco: linha do cursor, indentação e codificação descrevem
                // um editor que não está na tela. Um PNG anunciava "Ln 1, Col 1 · UTF-8 ·
                // LF · Texto". Sobra o que é do arquivo mesmo.
                if roomy, let m = medida(path) {
                    label(text: m)
                }
                HStack(spacing: 5) {
                    FileGlyph(path: path, size: 10)
                    Text(extensao(path)).foregroundStyle(theme.fgMuted)
                }
                .padding(.horizontal, 8).frame(height: 22)
            } else if let path = ws.active {
                let (line, col) = cursor(in: path)
                item(text: tr("Ln %1$@, Col %2$@", "\(line)", "\(col)")) { ws.paletteOpen = true; ws.paletteQuery = "@"
                }
                .help(tr("Ir para símbolo"))
                if nivel != .minimo {
                    Menu {
                        ForEach([2, 4, 8], id: \.self) { w in
                            Button { chrome.snapshot.editor.tabWidth = w } label: {
                                Label(
                                    tr("%1$@ espaços", "\(w)"),
                                    systemImage: w == chrome.snapshot.editor.tabWidth ? "checkmark" : ""
                                )
                            }
                        }
                        Divider()
                        Toggle(tr("Mostrar espaços"), isOn: $chrome.snapshot.editor.showWhitespace)
                        Toggle(tr("Guias de indentação"), isOn: $chrome.snapshot.editor.indentGuides)
                    } label: {
                        label(text: roomy ? tr("Espaços: %1$@", "\(chrome.snapshot.editor.tabWidth)")
                            : "⇥\(chrome.snapshot.editor.tabWidth)")
                    }
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                }
                if roomy {
                    item(text: "UTF-8") {}
                    item(text: eol(in: path)) {}
                }
                Button {
                    ws.paletteOpen = true
                    ws.paletteQuery = "@"
                } label: {
                    HStack(spacing: 5) {
                        FileGlyph(path: path, size: 10)
                        Text(Language.detect(path: path).label).foregroundStyle(theme.fgMuted)
                    }
                    .padding(.horizontal, 8).frame(height: 22).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
            }
            item(symbol: "gearshape", text: nil) { chrome.settingsOpen = true }
                .help(tr("Ajustes"))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    var branchText: String {
        var s = ws.git.current?.name ?? ws.git.headName ?? tr("sem branch")
        if !ws.git.isClean {
            s += "*"
        }
        if let ab = ws.git.aheadBehind, ab.ahead > 0 || ab.behind > 0 {
            s += "  \(ab.ahead)↑ \(ab.behind)↓"
        }
        return s
    }

    func cursor(in path: String) -> (Int, Int) {
        let ns = ws.text(for: path) as NSString
        let off = min(max(ws.cursorOffset, 0), ns.length)
        var line = 1, last = 0
        var i = 0
        while i < off {
            if ns.character(at: i) == 10 {
                line += 1
                last = i + 1
            }
            i += 1
        }
        return (line, off - last + 1)
    }

    /// "PNG", "PDF", "SQLITE" — o que o visualizador está mostrando.
    func extensao(_ path: String) -> String {
        let e = (path as NSString).pathExtension
        return e.isEmpty ? tr("binário") : e.uppercased()
    }

    func medida(_ path: String) -> String? {
        guard let u = try? ws.ops.url(path),
              let n = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? Int
        else { return nil }
        return Tamanho.arquivo(n)
    }

    func eol(in path: String) -> String {
        ws.text(for: path).contains("\r\n") ? "CRLF" : "LF"
    }

    func label(symbol: String? = nil, text: String?, tint: Color? = nil) -> some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint ?? theme.fgMuted)
            }
            if let text {
                Text(text).foregroundStyle(theme.fgMuted).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .contentShape(Capsule())
    }

    func item(symbol: String? = nil, text: String?, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { label(symbol: symbol, text: text, tint: tint) }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
    }
}
