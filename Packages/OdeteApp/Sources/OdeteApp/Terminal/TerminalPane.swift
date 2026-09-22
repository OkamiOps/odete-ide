import OdeteCore
import OdeteI18n
import OdeteShell
import OdeteUI
import SwiftUI
import UIKit

/// Terminal: abas, saída, prompt, jobs e barra de atalhos.
struct TerminalPane: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Manda o último comando com a saída dele para o compositor do agente.
    ///
    /// Uma linha isolada raramente basta: o que se quer mostrar é "rodei isto e deu
    /// nisto". O bloco vai do último comando digitado até o fim da saída.
    func enviarUltimoBloco(_ s: TerminalSession) {
        guard let i = s.lines.lastIndex(where: { $0.kind == .input }) else { return }
        ws.agent.anexarTrecho(origem: "terminal", texto: s.lines[i...].map(\.text).joined(separator: "\n"))
        chrome.snapshot.agentVisible = true
    }

    /// Ícone por convenção de nome, para a lista não ser seis vezes o mesmo desenho.
    func simbolo(_ nome: String) -> String {
        switch nome {
        case "dev", "start", "serve": "play.fill"
        case "build": "hammer"
        case "test", "tests": "checkmark.circle"
        case "lint", "format", "fmt": "text.badge.checkmark"
        default: "terminal"
        }
    }

    var body: some View {
        let run = ws.run
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollPane(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(run.sessions) { s in
                            TermTab(
                                session: s,
                                active: s.id == run.active?.id,
                                onSelect: { run.activeSession = s.id },
                                onClose: { run.close(s) }
                            )
                        }
                        HeaderButton("plus", label: tr("Nova aba")) { run.newSession() }
                    }
                    .padding(.leading, 6)
                }
                Spacer(minLength: 8)
                if !run.jobs.isEmpty {
                    Menu {
                        ForEach(run.jobs) { j in
                            Button(role: .destructive) { j.kill(); run.pruneServers() } label: {
                                Label(
                                    tr("Parar [%1$@] %2$@", "\(j.id)", "\(j.command)") +
                                        (j.ports.isEmpty ? "" : " · :\(j.ports[0])"),
                                    systemImage: "stop.circle"
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(theme.ok).frame(width: 7, height: 7)
                            Text(tr("%1$@ job%2$@", "\(run.jobs.count)", "\(run.jobs.count == 1 ? "" : "s")"))
                                .font(OdeteFont.mono(11))
                        }
                        .foregroundStyle(theme.fgMuted)
                        .padding(.horizontal, 8).frame(height: 26)
                        .background(theme.bgSubtle, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                // `temEntrada` é um contador que a sessão mantém; varrer a rolagem aqui
                // custava até 5000 linhas a cada lote de saída.
                if let s = run.active, s.temEntrada {
                    HeaderButton("sparkles", label: tr("Enviar último comando para a Odete")) {
                        enviarUltimoBloco(s)
                    }
                }
                if let s = run.active, s.running != nil {
                    HeaderButton("stop.fill", label: tr("Interromper (Ctrl+C)")) { s.cancel() }
                }
                if !ws.scripts.isEmpty {
                    Menu {
                        ForEach(ws.scripts, id: \.nome) { s in
                            Button {
                                run.run("npm run \(s.nome)")
                            } label: {
                                Label(s.nome, systemImage: simbolo(s.nome))
                            }
                        }
                    } label: {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.fgMuted)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .menuIndicator(.hidden)
                    .accessibilityLabel(tr("Scripts do projeto"))
                    .help(tr("Scripts do package.json"))
                }
                HeaderButton("trash", label: tr("Limpar")) { run.active?.clear() }
                if sizeClass != .compact {
                    HeaderButton("xmark", label: tr("Fechar terminal")) { chrome.toggleTerm() }
                }
            }
            .padding(.horizontal, 6)
            .frame(height: Metrics.tab)
            .background(theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 0.5) }
            if let s = run.active {
                TerminalView(session: s)
                    .id(s.id)
            }
        }
        .background(theme.bg)
    }
}

struct TermTab: View {
    @Environment(\.theme) private var theme
    let session: TerminalSession
    let active: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: session.running == nil ? "terminal" : "circle.fill")
                .font(.system(size: session.running == nil ? 11 : 7))
                .foregroundStyle(session.running == nil ? theme.fgSubtle : theme.accent)
            Text(session.title).font(OdeteFont.mono(11)).lineLimit(1)
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(theme.fgSubtle)
                .accessibilityLabel(tr("Fechar aba"))
        }
        .foregroundStyle(active ? theme.fg : theme.fgMuted)
        .padding(.horizontal, 10)
        .frame(height: Metrics.tab - 8)
        .background(active ? theme.glassTint : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

/// Saída e prompt de uma sessão.
struct TerminalView: View {
    @Environment(\.theme) private var theme
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Bindable var session: TerminalSession
    @FocusState private var focused: Bool

    /// O terminal tem tamanho e fonte próprios: ler log e escrever código não pedem o
    /// mesmo corpo, e quem deixa o terminal numa faixa estreita quer letra menor ali.
    ///
    /// Calculada uma vez por corpo e passada às linhas: era pedida por linha visível, e
    /// cada pedido montava um `UIFont` só para saber se a fonte existia.
    var fonteDoTerminal: Font {
        let tamanho = chrome.snapshot.termFontSize
        guard let nome = chrome.snapshot.termFont.postScript, OdeteFont.existe(nome)
        else { return .system(size: tamanho, design: .monospaced) }
        return .custom(nome, fixedSize: tamanho)
    }

    /// Manda uma linha do terminal para o compositor do agente.
    func enviar(linha: TermLine) {
        ws.agent.anexarTrecho(origem: "terminal", texto: linha.text)
        chrome.snapshot.agentVisible = true
    }

    var body: some View {
        let fonte = fonteDoTerminal
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollPane {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(session.lines) { line in
                            Text(line.text)
                                .font(fonte)
                                .foregroundStyle(color(line.kind))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                                .contextMenu {
                                    Button(tr("Enviar para a Odete"), systemImage: "sparkles") {
                                        enviar(linha: line)
                                    }
                                    Button(tr("Copiar linha"), systemImage: "doc.on.doc") {
                                        UIPasteboard.general.string = line.text
                                    }
                                }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                // A versão, não a contagem: no teto de linhas a contagem para de mudar e a
                // rolagem parava de acompanhar a saída.
                .onChange(of: session.versao) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onTapGesture { focused = true }
            }
            HStack(spacing: 8) {
                Text(session.prompt).font(fonte).foregroundStyle(theme.accent).lineLimit(1).fixedSize()
                TextField(tr("comando"), text: $session.input)
                    .font(fonte)
                    .foregroundStyle(theme.fg)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                    .submitLabel(.return)
                    .focused($focused)
                    .onSubmit { session.submit(); focused = true }
                    .onKeyPress(.upArrow) { session.historyUp(); return .handled }
                    .onKeyPress(.downArrow) { session.historyDown(); return .handled }
                    .onKeyPress(.tab) { session.tab(); return .handled }
                    .onKeyPress(characters: CharacterSet(charactersIn: "cC"), phases: .down) { press in
                        if press.modifiers.contains(.control) {
                            session.cancel(); return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(characters: CharacterSet(charactersIn: "lL"), phases: .down) { press in
                        if press.modifiers.contains(.control) {
                            session.clear(); return .handled
                        }
                        return .ignored
                    }
                if session.running != nil {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, Metrics.s3).frame(height: 42)
            .background(theme.bg)
            .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 0.5) }
        }
        .onAppear { focused = true }
    }

    func color(_ k: TermLine.Kind) -> Color {
        switch k {
        case .input: theme.fg
        case .out: theme.fgMuted
        case .err: theme.danger
        case .ok: theme.ok
        case .system: theme.fgSubtle
        }
    }
}
