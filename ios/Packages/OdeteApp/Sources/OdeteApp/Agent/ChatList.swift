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

    static let sugestoes: [(String, String)] = [
        ("text.magnifyingglass", "Explica a estrutura deste projeto"),
        ("play.circle", "Roda npm run dev e me diz se subiu"),
        ("plus.square.on.square", "Cria um componente de header em src/"),
        ("checkmark.seal", "/review no arquivo aberto"),
    ]

    var starters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Wordmark(height: 22).opacity(0.6)
            Text("Peça em português. O agente lê o projeto, roda no terminal e edita com patches que você aceita.")
                .font(.subheadline).foregroundStyle(theme.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            CardList {
                ForEach(Array(Self.sugestoes.enumerated()), id: \.offset) { i, s in
                    Button { agent.draft = s.1 } label: {
                        CardRow(s.1, symbol: s.0, color: theme.accent, first: i == 0, lines: 2) {
                            Image(systemName: "arrow.up.left").font(.caption2.bold())
                                .foregroundStyle(theme.fgSubtle)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 8)
    }

    enum Group: Identifiable {
        case single(ChatItem), tools(String, [ChatItem])
        var id: String {
            switch self {
            case let .single(i): i.id
            case let .tools(id, _): id
            }
        }
    }

    func grouped(_ items: [ChatItem]) -> [Group] {
        var out: [Group] = []
        for it in items {
            let isTool: Bool = switch it {
            case .tool: true
            case let .permit(_, _, _, s): s != .pending
            default: false
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
                Text(text).font(OdeteFont.ui(13.5)).foregroundStyle(theme.fg).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(theme.glassTint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(
                        theme.accent.opacity(0.2),
                        lineWidth: 0.5
                    ))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case let .assistant(_, text):
            MarkdownText(text: text).frame(maxWidth: .infinity, alignment: .leading)
        case let .think(_, text, live):
            // Nasce recolhido: o raciocínio é contexto, não a resposta.
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        if live {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "brain").font(.system(size: 11))
                        }
                        Text(live ? "pensando…" : "pensou").font(.caption)
                        if !live {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(open ? 90 : 0))
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(theme.fgSubtle)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(live)
                if open, !live {
                    HStack(alignment: .top, spacing: 10) {
                        Capsule().fill(theme.separator).frame(width: 2)
                        Text(text).font(.caption).foregroundStyle(theme.fgMuted).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
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

/// Ferramentas usadas no turno. Nasce recolhida numa linha só; expandindo, mostra cada
/// chamada com o nome e o alvo.
struct ToolGroup: View {
    @Environment(\.theme) private var theme
    let items: [ChatItem]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 10))
                    Text(summary).font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .foregroundStyle(theme.fgSubtle)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                        HStack(alignment: .top, spacing: 7) {
                            Text(name(it)).font(OdeteFont.mono(10.5, weight: .medium))
                                .foregroundStyle(theme.accent)
                            Text(detail(it)).font(OdeteFont.mono(10.5)).foregroundStyle(theme.fgMuted)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(alignment: .top) {
                            if i > 0 {
                                Rectangle().fill(theme.separator).frame(height: 0.5)
                            }
                        }
                    }
                }
            }
        }
        .background(theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func name(_ it: ChatItem) -> String {
        switch it {
        case let .tool(_, n, _): n
        case let .permit(_, n, _, _): n
        default: ""
        }
    }

    func detail(_ it: ChatItem) -> String {
        switch it {
        case let .tool(_, _, d): d
        case let .permit(_, _, d, s): d + (s == .no ? " (recusado)" : "")
        default: ""
        }
    }

    var summary: String {
        if items.count == 1 {
            return name(items[0]) + " " + detail(items[0])
        }
        let nomes = Set(items.map { name($0) }).sorted().prefix(3).joined(separator: ", ")
        return "\(items.count) ferramentas · \(nomes)"
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
/// Markdown do agente. Além de parágrafo e bloco de código, entende título, lista com
/// marcador, lista numerada, citação e régua. Texto corrido cansa de ler; a lista não.
struct MarkdownText: View {
    @Environment(\.theme) private var theme
    let text: String

    enum Block: Identifiable {
        case code(Int, String, String)
        case para(Int, String)
        case heading(Int, Int, String)
        case list(Int, Bool, [String])
        case quote(Int, String)
        case rule(Int)

        var id: Int {
            switch self {
            case let .code(i, _, _), let .para(i, _), let .heading(i, _, _),
                 let .list(i, _, _), let .quote(i, _), let .rule(i): i
            }
        }
    }

    var blocks: [Block] {
        var out: [Block] = []
        var i = 0
        var inCode = false
        var lang = ""
        var code: [String] = []
        var para: [String] = []
        var list: [String] = []
        var ordered = false
        var quote: [String] = []

        func flushPara() {
            if !para.isEmpty {
                out.append(.para(i, para.joined(separator: "\n"))); i += 1; para = []
            }
        }
        func flushList() {
            if !list.isEmpty {
                out.append(.list(i, ordered, list)); i += 1; list = []
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                out.append(.quote(i, quote.joined(separator: " "))); i += 1; quote = []
            }
        }
        func flushAll() {
            flushPara(); flushList(); flushQuote()
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    out.append(.code(i, lang, code.joined(separator: "\n"))); i += 1; code = []; inCode = false
                } else {
                    flushAll(); inCode = true
                    lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if inCode {
                code.append(line); continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll(); out.append(.rule(i)); i += 1; continue
            }
            if trimmed.hasPrefix("#") {
                flushAll()
                let level = trimmed.prefix { $0 == "#" }.count
                out.append(.heading(i, level, trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                i += 1
                continue
            }
            if trimmed.hasPrefix("> ") {
                flushPara(); flushList()
                quote.append(String(trimmed.dropFirst(2)))
                continue
            }
            if let item = bullet(trimmed) {
                flushPara(); flushQuote()
                if !ordered, !list.isEmpty, item.ordered {
                    flushList()
                }
                if ordered, !list.isEmpty, !item.ordered {
                    flushList()
                }
                ordered = item.ordered
                list.append(item.text)
                continue
            }
            if trimmed.isEmpty {
                flushAll(); continue
            }
            flushList(); flushQuote()
            para.append(line)
        }
        if inCode {
            out.append(.code(i, lang, code.joined(separator: "\n"))); i += 1
        }
        flushAll()
        return out
    }

    /// Reconhece "- item", "* item" e "1. item".
    func bullet(_ line: String) -> (text: String, ordered: Bool)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return (String(line.dropFirst(2)), false)
        }
        guard let dot = line.firstIndex(of: "."), line[line.startIndex ..< dot].allSatisfy(\.isNumber),
              line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " "
        else { return nil }
        return (String(line[line.index(dot, offsetBy: 2)...]), true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { b in
                switch b {
                case let .heading(_, level, t):
                    Text(t)
                        .font(level <= 1 ? .headline : .subheadline.weight(.semibold))
                        .foregroundStyle(theme.fg)
                        .padding(.top, 2)
                case let .para(_, t):
                    Text(inline(t))
                        .font(.subheadline)
                        .lineSpacing(3)
                        .foregroundStyle(theme.fg)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case let .list(_, ordered, items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { n, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(ordered ? "\(n + 1)." : "•")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(theme.accent)
                                    .frame(minWidth: ordered ? 18 : 10, alignment: .leading)
                                Text(inline(item))
                                    .font(.subheadline)
                                    .lineSpacing(3)
                                    .foregroundStyle(theme.fg)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case let .quote(_, t):
                    HStack(alignment: .top, spacing: 10) {
                        Capsule().fill(theme.accent.opacity(0.5)).frame(width: 3)
                        Text(inline(t)).font(.subheadline).foregroundStyle(theme.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .rule:
                    Rectangle().fill(theme.separator).frame(height: 0.5)
                case let .code(_, lang, c):
                    codeBlock(lang: lang, code: c)
                }
            }
        }
    }

    func codeBlock(lang: String, code c: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "código" : lang).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Copiar", systemImage: "doc.on.doc") { UIPasteboard.general.string = c }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(theme.fgMuted)
            }
            .padding(.leading, 12).padding(.trailing, 6).frame(height: 30)
            Rectangle().fill(theme.separator).frame(height: 0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(c).font(OdeteFont.mono(11.5)).foregroundStyle(theme.fg).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .background(theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func inline(_ t: String) -> AttributedString {
        (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ??
            AttributedString(t)
    }
}
