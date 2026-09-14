import OdeteAgent
import OdeteUI
import SwiftUI

/// A conversa: agrupa ferramentas seguidas e rola para o fim.
struct ChatList: View {
    @Environment(\.theme) private var theme
    let agent: AgentModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if agent.items.isEmpty {
                        starters
                    }
                    ForEach(grouped(agent.items)) { g in
                        switch g {
                        case let .single(item): ChatRow(agent: agent, item: item).id(item.id)
                        case let .tools(id, list): ToolGroup(items: list).id(id)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .onChange(of: agent.items.count) { withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(
                "end",
                anchor: .bottom
            ) } }
            .onChange(of: agent.items.last) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    var starters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Wordmark(height: 22).opacity(0.6)
            Text("Peça em português. O agente lê o projeto, roda no terminal e edita com patches que você aceita.")
                .font(OdeteFont.ui(12)).foregroundStyle(theme.fgMuted)
            ForEach(
                ["Explica a estrutura deste projeto", "Roda npm run dev e me diz se subiu",
                 "Cria um componente de header em src/",
                 "/review no arquivo aberto"],
                id: \.self
            ) { s in
                Button { agent.draft = s } label: {
                    Text(s).font(OdeteFont.ui(12)).foregroundStyle(theme.fg).padding(.horizontal, 10).frame(height: 32)
                        .background(theme.bgSubtle, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    enum Group: Identifiable {
        case single(ChatItem), tools(String, [ChatItem])
        var id: String {
            switch self { case let .single(i): i.id; case let .tools(id, _): id }
        }
    }

    func grouped(_ items: [ChatItem]) -> [Group] {
        var out: [Group] = []
        for it in items {
            let isTool: Bool = switch it {
            case .tool: true; case let .permit(_, _, _, s): s != .pending; default: false
            }
            if isTool, case let .tools(id, list)? = out.last {
                out[out.count - 1] = .tools(id, list + [it])
            } else if isTool {
                out.append(.tools("g-" + it.id, [it]))
            } else {
                out.append(.single(it))
            }
        }
        return out
    }
}

struct ChatRow: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    let agent: AgentModel
    let item: ChatItem
    @State private var open = false

    var body: some View {
        switch item {
        case let .user(_, text, images):
            VStack(alignment: .trailing, spacing: 6) {
                if let images, !images.isEmpty {
                    HStack(spacing: 6) { ForEach(images.indices, id: \.self) { i in thumb(images[i]) } }
                }
                Text(text).font(OdeteFont.ui(13)).foregroundStyle(theme.fg).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(theme.bgSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case let .assistant(_, text):
            MarkdownText(text: text).frame(maxWidth: .infinity, alignment: .leading)
        case let .think(_, text, live):
            DisclosureGroup(isExpanded: $open) {
                Text(text).font(OdeteFont.ui(11.5)).foregroundStyle(theme.fgMuted).textSelection(.enabled).padding(
                    .top,
                    4
                )
            } label: {
                HStack(spacing: 6) {
                    if live {
                        ProgressView().controlSize(.mini)
                    }
                    Text(live ? "pensando…" : "pensou").font(OdeteFont.ui(11.5)).foregroundStyle(theme.fgSubtle)
                }
            }
            .tint(theme.fgSubtle)
        case let .permit(id, name, detail, status):
            PermitCard(name: name, detail: detail, status: status) { agent.approve(id, $0) }
        case let .tool(_, name, detail):
            ToolGroup(items: [.tool(id: item.id, name: name, detail: detail)])
        case let .error(_, text):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(text == "parado" ? theme.fgSubtle : theme.danger)
                Text(text).font(OdeteFont.ui(12)).foregroundStyle(text == "parado" ? theme.fgMuted : theme.danger)
                    .textSelection(.enabled)
                if text.contains("Ajustes") {
                    Spacer()
                }
            }
        case let .patch(_, patchId, path):
            if let p = agent.patches.get(patchId) {
                PatchCard(agent: agent, patch: p)
            } else {
                Text("patch \(path)").font(OdeteFont.mono(11)).foregroundStyle(theme.fgSubtle)
            }
        }
    }

    @ViewBuilder
    func thumb(_ img: AgentImage) -> some View {
        if let d = Data(base64Encoded: img.data), let ui = UIImage(data: d) {
            Image(uiImage: ui).resizable().scaledToFill().frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Linha de ferramentas agrupadas, expansível.
struct ToolGroup: View {
    @Environment(\.theme) private var theme
    let items: [ChatItem]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 10))
                    Text(summary).font(OdeteFont.mono(11)).lineLimit(open ? nil : 1)
                    Spacer()
                    if items.count > 1 {
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(
                            size: 9,
                            weight: .bold
                        ))
                    }
                }
                .foregroundStyle(theme.fgSubtle)
            }
            .buttonStyle(.plain)
            if open, items.count > 1 {
                ForEach(items) { it in
                    Text("· " + line(it)).font(OdeteFont.mono(11)).foregroundStyle(theme.fgMuted).lineLimit(1)
                }
            }
        }
    }

    func line(_ it: ChatItem) -> String {
        switch it {
        case let .tool(_, n, d): "\(n) \(d)"
        case let .permit(_, n, d, s): "\(n) \(d)\(s == .no ? " (recusado)" : "")"
        default: ""
        }
    }

    var summary: String {
        items.count == 1 ? line(items[0]) : "\(items.count) ferramentas: " + items
            .map { line($0).split(separator: " ").first.map(String.init) ?? "" }.joined(separator: ", ")
    }
}

struct PermitCard: View {
    @Environment(\.theme) private var theme
    let name: String
    let detail: String
    let status: ChatItem.PermitStatus
    let answer: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status == .pending ? "hand.raised" : status == .ok ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(status == .no ? theme.danger : theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(OdeteFont.mono(11.5, weight: .medium)).foregroundStyle(theme.fg)
                Text(detail).font(OdeteFont.mono(11)).foregroundStyle(theme.fgMuted).lineLimit(3)
            }
            Spacer()
            if status == .pending {
                Button("Recusar") { answer(false) }.buttonStyle(.glass).font(OdeteFont.ui(12))
                Button("Aprovar") { answer(true) }.buttonStyle(.glassProminent).font(OdeteFont.ui(12))
            }
        }
        .padding(10)
        .background(theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(status == .pending ? theme.accent : theme.border))
    }
}

/// Patch com diff por hunk e ações.
struct PatchCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    let agent: AgentModel
    let patch: Patch
    @State private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { ws.openFile(patch.path) } label: {
                    HStack(spacing: 6) {
                        FileGlyph(path: patch.path, size: 12)
                        Text(patch.path).font(OdeteFont.mono(11.5, weight: .medium)).foregroundStyle(theme.fg)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                Text("+\(patch.additions)").font(OdeteFont.mono(10)).foregroundStyle(theme.ok)
                Text("−\(patch.deletions)").font(OdeteFont.mono(10)).foregroundStyle(theme.danger)
                Spacer()
                statusView
            }
            if open, patch.status == .pending {
                ForEach(patch.hunks) { h in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("@@ \(h.beforeStart) → \(h.afterStart)").font(OdeteFont.mono(10))
                                .foregroundStyle(theme.fgSubtle)
                            Spacer()
                            if patch.hunks
                                .count >
                                1
                            {
                                Button("Aceitar hunk") { agent.acceptHunk(patch, h.id) }.font(OdeteFont.ui(11))
                                    .buttonStyle(.plain).foregroundStyle(theme.accent)
                            }
                        }
                        .padding(.vertical, 3)
                        ForEach(Array(h.lines.enumerated()), id: \.offset) { _, l in diffLine(l) }
                    }
                }
            }
        }
        .padding(10)
        .background(theme.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.border))
    }

    @ViewBuilder var statusView: some View {
        switch patch.status {
        case .pending:
            Button { agent.reject(patch) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .buttonStyle(.glass).accessibilityLabel("Rejeitar")
            Button { agent.accept(patch) } label: {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
            }.buttonStyle(.glassProminent)
                .accessibilityLabel("Aceitar")
        case .accepted:
            Text("aceito").font(OdeteFont.ui(11)).foregroundStyle(theme.ok)
            Button("desfazer") { agent.undoPatch(patch) }.font(OdeteFont.ui(11)).buttonStyle(.plain)
                .foregroundStyle(theme.fgSubtle)
        case .rejected: Text("rejeitado").font(OdeteFont.ui(11)).foregroundStyle(theme.fgSubtle)
        case .undone: Text("desfeito").font(OdeteFont.ui(11)).foregroundStyle(theme.fgSubtle)
        }
    }

    func diffLine(_ l: Hunk.Line) -> some View {
        let (sign, text, color, bg): (String, String, Color, Color) = switch l {
        case let .context(s): (" ", s, theme.fgMuted, .clear)
        case let .removed(s): ("-", s, theme.danger, theme.danger.opacity(0.10))
        case let .added(s): ("+", s, theme.ok, theme.ok.opacity(0.10))
        }
        return Text(sign + " " + text).font(OdeteFont.mono(10.5)).foregroundStyle(color).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).background(bg)
    }
}

/// Markdown simples: títulos, listas, blocos de código e inline.
struct MarkdownText: View {
    @Environment(\.theme) private var theme
    let text: String

    enum Block: Identifiable { case code(Int, String, String), para(Int, String), heading(Int, String)
        var id: Int {
            switch self { case let .code(i, _, _), let .para(i, _), let .heading(i, _): i }
        }
    }

    var blocks: [Block] {
        var out: [Block] = []
        var i = 0
        var inCode = false, lang = "", code: [String] = [], para: [String] = []
        func flush() {
            if !para.isEmpty {
                out.append(.para(i, para.joined(separator: "\n"))); i += 1; para = []
            }
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("```") {
                if inCode {
                    out.append(.code(i, lang, code.joined(separator: "\n"))); i += 1; code = []; inCode = false
                } else {
                    flush(); inCode = true; lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if inCode {
                code.append(line); continue
            }
            if line.hasPrefix("#") {
                flush(); out.append(.heading(
                    i,
                    line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                )); i += 1; continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush(); continue
            }
            para.append(line)
        }
        if inCode {
            out.append(.code(i, lang, code.joined(separator: "\n"))); i += 1
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { b in
                switch b {
                case let .heading(_, t): Text(t).font(OdeteFont.ui(13, weight: .semibold)).foregroundStyle(theme.fg)
                    .padding(
                        .top,
                        4
                    )
                case let .para(_, t): Text(inline(t)).font(OdeteFont.ui(13)).foregroundStyle(theme.fg)
                    .textSelection(.enabled).fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                case let .code(_, lang, c):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(lang.isEmpty ? "código" : lang).font(OdeteFont.mono(10))
                                .foregroundStyle(theme.fgSubtle)
                            Spacer()
                            Button { UIPasteboard.general.string = c } label: {
                                Image(systemName: "doc.on.doc").font(.system(size: 11))
                            }.buttonStyle(.plain)
                                .foregroundStyle(theme.fgSubtle)
                        }
                        .padding(.horizontal, 10).frame(height: 24)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(c).font(OdeteFont.mono(11.5)).foregroundStyle(theme.fg).textSelection(.enabled)
                                .padding(
                                    .horizontal,
                                    10
                                ).padding(.bottom, 8)
                        }
                    }
                    .background(theme.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(theme.border))
                }
            }
        }
    }

    func inline(_ t: String) -> AttributedString {
        (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ??
            AttributedString(t)
    }
}
