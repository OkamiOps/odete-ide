import OdeteAgent
import OdeteCore
import OdeteUI
import PhotosUI
import SwiftUI

/// Caixa de texto do agente: anexos, @arquivos, /skills, modo, permissão, enviar/parar.
struct Composer: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @Bindable var agent: AgentModel
    @FocusState private var focused: Bool
    @State private var photo: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 6) {
            if let menu = menuState {
                MentionMenu(
                    kind: menu.kind,
                    query: menu.query,
                    files: ws.tree.allFiles().map(\.path),
                    skills: Skills.all(host: agent.host)
                ) { pick($0, menu) }
            }
            if !agent.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(agent.attachments.indices, id: \.self) { i in
                            ZStack(alignment: .topTrailing) {
                                if let d = Data(base64Encoded: agent.attachments[i].data), let ui = UIImage(data: d) {
                                    Image(uiImage: ui).resizable().scaledToFill().frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Button { agent.attachments.remove(at: i) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(
                                        .white,
                                        .black.opacity(0.6)
                                    )
                                }.buttonStyle(.plain).offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    PhotosPicker(selection: $photo, matching: .images) { Label("Foto", systemImage: "photo") }
                    Button { agent.attachPreview() } label: {
                        Label("Print do preview", systemImage: "camera.viewfinder")
                    }.disabled(ws.preview.url == nil)
                    Button { agent.draft += (agent.draft.isEmpty ? "" : " ") + "@" } label: { Label(
                        "Arquivo (@)",
                        systemImage: "at"
                    ) }
                    Button { agent.draft += (agent.draft.isEmpty ? "" : " ") + "/" } label: { Label(
                        "Skill (/)",
                        systemImage: "slash.circle"
                    ) }
                } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.fgMuted)
                        .frame(
                            width: 32,
                            height: 32
                        )
                }
                .buttonStyle(.plain)
                TextField(
                    agent.running ? "redirecionar o agente…" : "Peça algo à Odete…",
                    text: $agent.draft,
                    axis: .vertical
                )
                .font(OdeteFont.ui(13))
                .foregroundStyle(theme.fg)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 6)
                .focused($focused)
                .onSubmit { send() }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) || press.modifiers.contains(.shift) == false && !press
                        .modifiers.contains(.option)
                    {
                        send(); return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.escape) {
                    if agent.running {
                        agent.stop(); return .handled
                    }; return .ignored
                }
                .padding(.vertical, 8)
                if agent.running, agent.draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button { agent.stop() } label: { Image(systemName: "stop.fill").font(.system(
                        size: 13,
                        weight: .bold
                    )).frame(width: 32, height: 32) }
                        .buttonStyle(.glassProminent).tint(theme.danger).accessibilityLabel("Parar")
                } else {
                    Button { send() } label: {
                        Image(systemName: agent.running ? "arrow.triangle.turn.up.right.circle.fill" : "arrow.up")
                            .font(.system(
                                size: 14,
                                weight: .bold
                            )).frame(width: 32, height: 32)
                    }
                    .buttonStyle(.glassProminent).disabled(agent.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(agent.running ? "Redirecionar" : "Enviar")
                }
            }
            .padding(.horizontal, 8)
            .background(theme.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(focused ? theme.accent.opacity(0.6) : theme.border))
            .padding(.horizontal, 10)
            HStack(spacing: 6) {
                Picker("Modo", selection: Binding(get: { agent.mode }, set: { agent.setMode($0) })) {
                    ForEach(AgentMode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 200)
                Spacer()
                Menu {
                    ForEach(PermitMode.allCases) { p in Button { agent.setPermit(p) } label: { Label(
                        "\(p.label) · \(p.hint)",
                        systemImage: p.symbol
                    ) } }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: agent.permit.symbol).font(.system(size: 11)); Text(agent.permit.label)
                            .font(OdeteFont.ui(11))
                    }
                    .foregroundStyle(theme.fgMuted).padding(.horizontal, 8).frame(height: 26).background(
                        theme.bgSubtle,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
        }
        .padding(.top, Metrics.s2)
        .onChange(of: agent.focusRequest) { focused = true }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let d = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: d)
                {
                    agent.attach(img)
                }; photo = nil
            }
        }
    }

    func send() {
        agent.send(); focused = true
    }

    struct MenuState { let kind: MentionMenu.Kind; let query: String; let range: Range<String.Index> }

    /// Último `@x` ou `/x` sendo digitado no fim do texto.
    var menuState: MenuState? {
        let t = agent.draft
        guard let m = t.range(of: #"(?:^|\s)([@/])([\w./-]*)$"#, options: .regularExpression) else { return nil }
        var token = String(t[m])
        if token.first == " " || token.first == "\n" {
            token.removeFirst()
        }
        let kind: MentionMenu.Kind = token.hasPrefix("@") ? .file : .skill
        let start = t.index(m.upperBound, offsetBy: -token.count)
        return MenuState(kind: kind, query: String(token.dropFirst()), range: start ..< m.upperBound)
    }

    func pick(_ value: String, _ m: MenuState) {
        agent.draft.replaceSubrange(m.range, with: (m.kind == .file ? "@" : "/") + value + " ")
    }
}

struct MentionMenu: View {
    enum Kind { case file, skill }
    @Environment(\.theme) private var theme
    let kind: Kind
    let query: String
    let files: [String]
    let skills: [Skill]
    let pick: (String) -> Void

    var options: [(String, String)] {
        let q = query.lowercased()
        switch kind {
        case .file: return files.filter { q.isEmpty || $0.lowercased().contains(q) }.sorted { (
                $0.lowercased().hasPrefix(q) ? 0 : 1,
                $0.count
            ) < ($1.lowercased().hasPrefix(q) ? 0 : 1, $1.count) }.prefix(8).map { ($0, "") }
        case .skill: return skills.filter { q.isEmpty || $0.id.contains(q) }.prefix(8).map { ($0.id, $0.description) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(options, id: \.0) { o in
                Button { pick(o.0) } label: {
                    HStack(spacing: 8) {
                        if kind == .file {
                            FileGlyph(path: o.0, size: 12)
                        } else {
                            Image(systemName: "slash.circle").font(.system(size: 11)).foregroundStyle(theme.accent)
                        }
                        Text((kind == .file ? "" : "/") + o.0).font(OdeteFont.mono(11.5)).foregroundStyle(theme.fg)
                            .lineLimit(1)
                        if !o.1
                            .isEmpty
                        {
                            Text(o.1).font(OdeteFont.ui(11)).foregroundStyle(theme.fgSubtle).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if options
                .isEmpty
            {
                Text(kind == .file ? "nenhum arquivo" : "nenhuma skill").font(OdeteFont.ui(11))
                    .foregroundStyle(theme.fgSubtle).padding(10)
            }
        }
        .background(theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.border))
        .padding(.horizontal, 10)
    }
}
