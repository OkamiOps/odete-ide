import OdeteCore
import OdeteI18n
import OdeteUI
import SwiftUI

struct PaletteItem: Identifiable, Hashable {
    enum Kind { case file, command, symbol }
    var id: String
    var kind: Kind
    var title: String
    var detail: String
    var symbol: String
    var shortcut: String?
}

/// Paleta ⌘P: arquivos do projeto e comandos, com filtro por subsequência.
struct CommandPalette: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var selection = 0
    @FocusState private var focused: Bool

    var commands: [PaletteItem] {
        [
            PaletteItem(
                id: ">save",
                kind: .command,
                title: tr("Salvar arquivo"),
                detail: "",
                symbol: "square.and.arrow.down",
                shortcut: "⌘S"
            ),
            PaletteItem(
                id: ">saveall",
                kind: .command,
                title: tr("Salvar todos"),
                detail: "",
                symbol: "square.and.arrow.down.on.square",
                shortcut: nil
            ),
            PaletteItem(
                id: ">new",
                kind: .command,
                title: tr("Novo arquivo"),
                detail: "",
                symbol: "doc.badge.plus",
                shortcut: nil
            ),
            PaletteItem(
                id: ">side",
                kind: .command,
                title: tr("Alternar sidebar"),
                detail: "",
                symbol: "sidebar.left",
                shortcut: "⌘B"
            ),
            PaletteItem(
                id: ">term",
                kind: .command,
                title: tr("Alternar terminal"),
                detail: "",
                symbol: "terminal",
                shortcut: "⌘J"
            ),
            PaletteItem(
                id: ">agent",
                kind: .command,
                title: tr("Alternar agente"),
                detail: "",
                symbol: "sparkles",
                shortcut: "⌘I"
            ),
            PaletteItem(
                id: ">search",
                kind: .command,
                title: tr("Buscar no projeto"),
                detail: "",
                symbol: "magnifyingglass",
                shortcut: "⇧⌘F"
            ),
            PaletteItem(
                id: ">settings",
                kind: .command,
                title: tr("Ajustes"),
                detail: "",
                symbol: "gearshape",
                shortcut: "⌘,"
            ),
            PaletteItem(
                id: ">closetab",
                kind: .command,
                title: tr("Fechar aba"),
                detail: "",
                symbol: "xmark",
                shortcut: "⌘W"
            ),
            PaletteItem(
                id: ">hub",
                kind: .command,
                title: tr("Voltar aos projetos"),
                detail: "",
                symbol: "square.grid.2x2",
                shortcut: nil
            ),
        ] + CenterMode.allCases.map {
            PaletteItem(
                id: ">mode.\($0.rawValue)",
                kind: .command,
                title: "Modo: \($0.label)",
                detail: "",
                symbol: "rectangle.split.2x1",
                shortcut: nil
            )
        } + ThemePalette.all.map {
            PaletteItem(
                id: ">theme.\($0.id.rawValue)",
                kind: .command,
                title: "Tema: \($0.label)",
                detail: tr($0.blurb),
                symbol: "paintpalette",
                shortcut: nil
            )
        }
    }

    var files: [PaletteItem] {
        ws.filePaths.map { caminho in
            PaletteItem(
                id: caminho,
                kind: .file,
                title: caminho.split(separator: "/").last.map(String.init) ?? caminho,
                detail: caminho,
                symbol: "doc",
                shortcut: nil
            )
        }
    }

    var symbols: [PaletteItem] {
        guard let path = ws.active else { return [] }
        return (ws.outlines[path] ?? []).map {
            PaletteItem(
                id: "@\($0.line)",
                kind: .symbol,
                title: $0.name,
                detail: tr("%1$@ · linha %2$@", "\($0.kind.rawValue)", "\($0.line)"),
                symbol: $0.kind.symbol,
                shortcut: nil
            )
        }
    }

    /// Símbolos do projeto inteiro. O `#` é o que o VS Code usa, e separar do `@` mantém
    /// a lista do arquivo aberto curta.
    var simbolosDoProjeto: [PaletteItem] {
        ws.simbolos.map {
            PaletteItem(
                id: "#\($0.path):\($0.line)",
                kind: .symbol,
                title: $0.name,
                detail: "\($0.kind.rawValue) · \($0.path):\($0.line)",
                symbol: $0.kind.symbol,
                shortcut: nil
            )
        }
    }

    var items: [PaletteItem] {
        let q = ws.paletteQuery
        if q.hasPrefix("#") {
            let rest = q.dropFirst().trimmingCharacters(in: .whitespaces)
            return simbolosDoProjeto.filter { rest.isEmpty || fuzzy(rest, $0.title) }.prefix(60).map(\.self)
        }
        if q.hasPrefix("@") {
            let rest = q.dropFirst().trimmingCharacters(in: .whitespaces)
            return symbols.filter { rest.isEmpty || fuzzy(rest, $0.title) }.prefix(60).map(\.self)
        }
        if q.hasPrefix(">") {
            let rest = q.dropFirst().trimmingCharacters(in: .whitespaces)
            return commands.filter { rest.isEmpty || fuzzy(rest, $0.title) }.prefix(40).map(\.self)
        }
        if q.isEmpty {
            let recent = ws.tabs.map(\.path)
            return files.sorted { a, b in
                let ia = recent.firstIndex(of: a.id) ?? .max, ib = recent.firstIndex(of: b.id) ?? .max
                return ia != ib ? ia < ib : a.detail < b.detail
            }.prefix(40).map(\.self)
        }
        return files.filter { fuzzy(q, $0.detail) }
            .sorted { score(q, $0) > score(q, $1) }
            .prefix(40).map(\.self)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: ws.paletteQuery.hasPrefix(">") ? "chevron.right" : ws.paletteQuery
                    .hasPrefix("@") ? "at" : "magnifyingglass")
                    .foregroundStyle(theme.fgSubtle)
                TextField(
                    tr("arquivo, > comando, @ símbolo"),
                    text: Binding(get: { ws.paletteQuery }, set: { ws.paletteQuery = $0; selection = 0 })
                )
                .focused($focused)
                .textFieldStyle(.plain)
                .font(OdeteFont.ui(15))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { activate(selected) }
                .onKeyPress(.downArrow) { selection = min(selection + 1, items.count - 1); return .handled }
                .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                Text(tr("esc")).font(OdeteFont.mono(10)).foregroundStyle(theme.fgSubtle)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(theme.bgSubtle, in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
            ScrollViewReader { proxy in
                ScrollPane {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                            Button { activate(it) } label: {
                                HStack(spacing: 10) {
                                    if it.kind == .file {
                                        FileGlyph(path: it.id, size: 14)
                                    } else {
                                        Image(systemName: it.symbol).font(.system(size: 13))
                                            .foregroundStyle(theme.fgMuted).frame(width: 18)
                                    }
                                    Text(it.title).font(OdeteFont.ui(13, weight: .medium)).foregroundStyle(theme.fg)
                                    Text(it.detail).font(OdeteFont.mono(11)).foregroundStyle(theme.fgSubtle)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if let s = it
                                        .shortcut
                                    {
                                        Text(s).font(OdeteFont.mono(10)).foregroundStyle(theme.fgSubtle)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .frame(height: Metrics.row)
                                .background(i == selection ? theme.bgSubtle : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(it.id)
                        }
                        if items.isEmpty {
                            Text(tr("nada")).font(OdeteFont.ui(12)).foregroundStyle(theme.fgSubtle).padding(16)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: selection) {
                    _, _ in if let s = selected {
                        proxy.scrollTo(s.id)
                    }
                }
            }
            .frame(height: min(420, CGFloat(max(items.count, 1)) * Metrics.row + 12))
        }
        .frame(width: 620)
        .background(theme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.border))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        .onAppear { focused = true; selection = 0 }
    }

    var selected: PaletteItem? {
        items.indices.contains(selection) ? items[selection] : items.first
    }

    func close() {
        ws.paletteOpen = false
        ws.paletteQuery = ""
    }

    func activate(_ item: PaletteItem?) {
        guard let item else { return }
        close()
        switch item.kind {
        case .file: ws.openFile(item.id)
        case .symbol:
            // "#caminho:linha" é símbolo do projeto; "@linha" é do arquivo aberto.
            if item.id.hasPrefix("#") {
                let corpo = item.id.dropFirst()
                if let corte = corpo.lastIndex(of: ":"), let line = Int(corpo[corpo.index(after: corte)...]) {
                    ws.open(String(corpo[..<corte]), line: line)
                }
            } else if let path = ws.active, let line = Int(item.id.dropFirst()) {
                ws.open(path, line: line)
            }
        case .command:
            switch item.id {
            case ">save": ws.save()
            case ">saveall": ws.saveAll()
            case ">new": ws.createFile(near: ws.selected)
            case ">side": chrome.toggleSide()
            case ">term": chrome.toggleTerm()
            case ">agent": chrome.toggleAgent()
            case ">search": chrome.snapshot.side = .search; chrome.snapshot.sideOpen = true
            case ">settings": chrome.settingsOpen = true
            case ">closetab": if let a = ws.active {
                    ws.closeTab(a)
                }
            case ">hub": app.closeWorkspace()
            default:
                if item.id.hasPrefix(">mode."),
                   let m = CenterMode(rawValue: String(item.id.dropFirst(6)))
                {
                    chrome.snapshot.center = m
                }
                if item.id.hasPrefix(">theme."),
                   let t = ThemeId(rawValue: String(item.id.dropFirst(7)))
                {
                    chrome.snapshot.theme = t
                }
            }
        }
    }

    func fuzzy(_ q: String, _ s: String) -> Bool {
        var it = s.lowercased().makeIterator()
        for ch in q.lowercased() {
            var found = false
            while let c = it.next() {
                if c == ch {
                    found = true; break
                }
            }
            if !found {
                return false
            }
        }
        return true
    }

    func score(_ q: String, _ it: PaletteItem) -> Int {
        let name = it.title.lowercased(), ql = q.lowercased()
        if name == ql {
            return 100
        }
        if name.hasPrefix(ql) {
            return 80
        }
        if name.contains(ql) {
            return 60
        }
        if it.detail.lowercased().contains(ql) {
            return 40
        }
        return 10
    }
}
