import OdeteCore
import OdeteShell
import OdeteUI
import SwiftUI

/// Terminal: abas, saída, prompt, jobs e barra de atalhos.
struct TerminalPane: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let run = ws.run
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(run.sessions) { s in
                            TermTab(
                                session: s,
                                active: s.id == run.active?.id,
                                onSelect: { run.activeSession = s.id },
                                onClose: { run.close(s) }
                            )
                        }
                        HeaderButton("plus", label: "Nova aba") { run.newSession() }
                    }
                    .padding(.leading, 6)
                }
                Spacer(minLength: 8)
                if !run.jobs.isEmpty {
                    Menu {
                        ForEach(run.jobs) { j in
                            Button(role: .destructive) { j.kill(); run.pruneServers() } label: {
                                Label(
                                    "Parar [\(j.id)] \(j.command)" + (j.ports.isEmpty ? "" : " · :\(j.ports[0])"),
                                    systemImage: "stop.circle"
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(theme.ok).frame(width: 7, height: 7)
                            Text("\(run.jobs.count) job\(run.jobs.count == 1 ? "" : "s")").font(OdeteFont.mono(11))
                        }
                        .foregroundStyle(theme.fgMuted)
                        .padding(.horizontal, 8).frame(height: 26)
                        .background(theme.bgSubtle, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if let s = run.active, s.running != nil {
                    HeaderButton("stop.fill", label: "Interromper (Ctrl+C)") { s.cancel() }
                }
                HeaderButton("trash", label: "Limpar") { run.active?.clear() }
                if sizeClass != .compact {
                    HeaderButton("xmark", label: "Fechar terminal") { chrome.toggleTerm() }
                }
            }
            .padding(.horizontal, 6)
            .frame(height: Metrics.tab)
            .background(theme.bgElevated)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
            if let s = run.active {
                TerminalView(session: s)
                    .id(s.id)
            }
        }
        .background(theme.bgElevated)
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
                .accessibilityLabel("Fechar aba")
        }
        .foregroundStyle(active ? theme.fg : theme.fgMuted)
        .padding(.horizontal, 10)
        .frame(height: Metrics.tab - 8)
        .background(active ? theme.bg : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

/// Saída e prompt de uma sessão.
struct TerminalView: View {
    @Environment(\.theme) private var theme
    @Bindable var session: TerminalSession
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(session.lines) { line in
                            Text(line.text)
                                .font(OdeteFont.mono(12))
                                .foregroundStyle(color(line.kind))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .onChange(of: session.lines.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onTapGesture { focused = true }
            }
            HStack(spacing: 8) {
                Text(session.prompt).font(OdeteFont.mono(12)).foregroundStyle(theme.accent).lineLimit(1).fixedSize()
                TextField("comando", text: $session.input)
                    .font(OdeteFont.mono(12))
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
            .padding(.horizontal, 12).frame(height: 40)
            .background(theme.bg)
            .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
            TermKeys(session: session)
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

/// Atalhos de toque: Tab, ↑, ↓, ^C, símbolos e os comandos mais comuns.
struct TermKeys: View {
    @Environment(\.theme) private var theme
    let session: TerminalSession
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("Tab") { session.tab() }
                key("↑") { session.historyUp() }
                key("↓") { session.historyDown() }
                key("^C") { session.cancel() }
                Divider().frame(height: 18)
                ForEach(["|", ">", "&&", "~/", "-", "."], id: \.self) { t in key(t) { session.input += t } }
                Divider().frame(height: 18)
                ForEach(["ls", "git status", "npm install", "npm run dev", "node "], id: \.self) { t in
                    key(t) {
                        session.input = t; if !t.hasSuffix(" ") {
                            session.submit()
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 36)
        .background(theme.bgElevated)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    func key(_ t: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(OdeteFont.mono(11)).foregroundStyle(theme.fg)
                .padding(.horizontal, 9).frame(height: 26)
                .background(theme.bgSubtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
