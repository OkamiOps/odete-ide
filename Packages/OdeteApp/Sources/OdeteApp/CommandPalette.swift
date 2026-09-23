import OdeteCore
import OdeteEditor
import OdeteI18n
import OdeteUI
import SwiftUI

struct PaletteItem: Identifiable, Hashable {
    enum Kind { case file, command, symbol, line }
    var id: String
    var kind: Kind
    var title: String
    var detail: String
    var symbol: String
    var shortcut: String?
}

/// Um arquivo do projeto pronto para o filtro, com nome e caminho já em minúsculas.
///
/// O filtro baixava a caixa de cada caminho dentro do laço — e a ordenação baixava de
/// novo dentro do comparador, duas vezes por comparação. Num projeto de alguns milhares
/// de arquivos isso era refeito a cada tecla, três vezes por desenho. Aqui é uma vez
/// por abertura da paleta.
struct ArquivoNaPaleta {
    let item: PaletteItem
    let caminho: String
    let nome: String

    init(_ caminho: String) {
        let nome = caminho.split(separator: "/").last.map(String.init) ?? caminho
        item = PaletteItem(id: caminho, kind: .file, title: nome, detail: caminho, symbol: "doc", shortcut: nil)
        self.caminho = caminho.lowercased()
        self.nome = nome.lowercased()
    }
}

/// O filtro da paleta, fora da view: roda uma vez por mudança da consulta, não a cada
/// desenho.
enum FiltroDaPaleta {
    /// Subsequência: as letras da consulta aparecem em ordem no texto. Os dois já vêm em
    /// minúsculas.
    static func contem(_ q: String, em s: String) -> Bool {
        var it = s.makeIterator()
        for ch in q {
            var achou = false
            while let c = it.next() {
                if c == ch {
                    achou = true
                    break
                }
            }
            if !achou {
                return false
            }
        }
        return true
    }

    static func pontos(_ q: String, nome: String, caminho: String) -> Int {
        if nome == q {
            return 100
        }
        if nome.hasPrefix(q) {
            return 80
        }
        if nome.contains(q) {
            return 60
        }
        if caminho.contains(q) {
            return 40
        }
        return 10
    }

    /// Arquivos que casam com a consulta, os mais prováveis primeiro. Consulta vazia
    /// mostra as abas abertas na frente e o resto em ordem de caminho.
    static func arquivos(_ consulta: String, _ indice: [ArquivoNaPaleta], abertas: [String], limite: Int = 40)
        -> [PaletteItem]
    {
        let q = consulta.lowercased()
        if q.isEmpty {
            let ordemDasAbas = Dictionary(abertas.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let naFrente = indice.filter { ordemDasAbas[$0.item.id] != nil }
                .sorted { ordemDasAbas[$0.item.id]! < ordemDasAbas[$1.item.id]! }
            let resto = indice.lazy.filter { ordemDasAbas[$0.item.id] == nil }.prefix(max(limite - naFrente.count, 0))
            return (naFrente + resto).prefix(limite).map(\.item)
        }
        return indice.lazy
            .filter { contem(q, em: $0.caminho) }
            .map { (a: $0, p: pontos(q, nome: $0.nome, caminho: $0.caminho)) }
            .sorted { x, y in
                if x.p != y.p {
                    return x.p > y.p
                }
                if x.a.caminho.count != y.a.caminho.count {
                    return x.a.caminho.count < y.a.caminho.count
                }
                return x.a.caminho < y.a.caminho
            }
            .prefix(limite)
            .map(\.a.item)
    }

    /// Comandos e símbolos: listas curtas, filtradas pelo título.
    static func filtrar(_ consulta: String, _ itens: [PaletteItem], limite: Int) -> [PaletteItem] {
        let q = consulta.lowercased()
        guard !q.isEmpty else { return Array(itens.prefix(limite)) }
        return Array(itens.lazy.filter { contem(q, em: $0.title.lowercased()) }.prefix(limite))
    }

    /// `:12` ou `:12:5` — ir para a linha do arquivo aberto, como o ⌃G do VS Code.
    ///
    /// A linha além do fim já aparece presa ao que o arquivo tem, para a pessoa ver onde
    /// vai cair antes de apertar Enter.
    static func linha(_ consulta: String, arquivo: String?, totalDeLinhas: Int) -> [PaletteItem] {
        guard let arquivo else {
            return [PaletteItem(
                id: ":",
                kind: .line,
                title: tr("Nenhum arquivo aberto"),
                detail: "",
                symbol: "number",
                shortcut: nil
            )]
        }
        let nome = arquivo.split(separator: "/").last.map(String.init) ?? arquivo
        guard let alvo = AlvoDeLinha(consulta) else {
            return [PaletteItem(
                id: ":",
                kind: .line,
                title: tr("Digite uma linha, ou linha:coluna"),
                detail: "\(nome) · " + tr("de 1 a %1$@", "\(totalDeLinhas)"),
                symbol: "number",
                shortcut: "⌘L"
            )]
        }
        let linha = alvo.linhaPresa(total: totalDeLinhas)
        let titulo = alvo.coluna.map { tr("Ir para a linha %1$@, coluna %2$@", "\(linha)", "\($0)") }
            ?? tr("Ir para a linha %1$@", "\(linha)")
        return [PaletteItem(
            id: alvo.coluna.map { ":\(linha):\($0)" } ?? ":\(linha)",
            kind: .line,
            title: titulo,
            detail: nome,
            symbol: "arrow.right.to.line",
            shortcut: nil
        )]
    }
}

/// Paleta ⌘P: arquivos do projeto e comandos, com filtro por subsequência.
struct CommandPalette: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var selection = 0
    @FocusState private var focused: Bool
    /// O resultado da consulta atual. Guardado: antes era uma propriedade calculada, e o
    /// desenho a lia três vezes — lista, altura e item selecionado.
    @State private var items: [PaletteItem] = []
    /// Os arquivos do projeto já em minúsculas, montado ao abrir.
    @State private var indice: [ArquivoNaPaleta] = []

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
                id: ">goto",
                kind: .command,
                title: tr("Ir para a linha…"),
                detail: "",
                symbol: "arrow.right.to.line",
                shortcut: "⌘L"
            ),
            PaletteItem(
                id: ">editor.alternarComentario",
                kind: .command,
                title: tr("Comentar linhas"),
                detail: "",
                symbol: "text.bubble",
                shortcut: "⌘/"
            ),
            PaletteItem(
                id: ">editor.duplicarLinhas",
                kind: .command,
                title: tr("Duplicar linhas"),
                detail: "",
                symbol: "plus.square.on.square",
                shortcut: "⇧⌥↓"
            ),
            PaletteItem(
                id: ">editor.apagarLinhas",
                kind: .command,
                title: tr("Apagar linhas"),
                detail: "",
                symbol: "delete.left",
                shortcut: "⇧⌘K"
            ),
            PaletteItem(
                id: ">editor.mostrarProblema",
                kind: .command,
                title: tr("Mostrar problema no cursor"),
                detail: "",
                symbol: "exclamationmark.bubble",
                shortcut: "⌘'"
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
                title: tr("Modo: %1$@", $0.label),
                detail: "",
                symbol: "rectangle.split.2x1",
                shortcut: nil
            )
        } + ThemePalette.all.map {
            PaletteItem(
                id: ">theme.\($0.id.rawValue)",
                kind: .command,
                title: tr("Tema: %1$@", $0.label),
                detail: tr($0.blurb),
                symbol: "paintpalette",
                shortcut: nil
            )
        } + ComandosDoHistorico.itens
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

    /// Refaz a lista para a consulta atual. Só a lista do prefixo digitado é montada.
    func recalcular() {
        let q = ws.paletteQuery
        let resto = q.dropFirst().trimmingCharacters(in: .whitespaces)
        if q.hasPrefix(":") {
            let total = ws.active.map { ws.text(for: $0).utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 } } ?? 0
            items = FiltroDaPaleta.linha(resto, arquivo: ws.active, totalDeLinhas: total)
        } else if q.hasPrefix("#") {
            items = FiltroDaPaleta.filtrar(resto, simbolosDoProjeto, limite: 60)
        } else if q.hasPrefix("@") {
            items = FiltroDaPaleta.filtrar(resto, symbols, limite: 60)
        } else if q.hasPrefix(">") {
            items = FiltroDaPaleta.filtrar(resto, commands, limite: 40)
        } else {
            items = FiltroDaPaleta.arquivos(q, indice, abertas: ws.tabs.map(\.path))
        }
        if selection >= items.count {
            selection = 0
        }
    }

    /// Monta o índice dos arquivos, em ordem de caminho, uma vez por abertura.
    func indexar() {
        indice = ws.filePaths.sorted().map(ArquivoNaPaleta.init)
    }

    var icone: String {
        let q = ws.paletteQuery
        if q.hasPrefix(">") {
            return "chevron.right"
        }
        if q.hasPrefix("@") {
            return "at"
        }
        if q.hasPrefix(":") {
            return "arrow.right.to.line"
        }
        return "magnifyingglass"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icone)
                    .foregroundStyle(theme.fgSubtle)
                TextField(
                    tr("arquivo, > comando, @ símbolo, : linha"),
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
        .onAppear {
            focused = true
            selection = 0
            indexar()
            recalcular()
        }
        .onChange(of: ws.paletteQuery) { recalcular() }
        .onChange(of: ws.filePaths) {
            indexar()
            recalcular()
        }
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
        // "Ir para a linha…" troca o prefixo e a paleta fica aberta esperando o número;
        // a dica do `:` sem número também não tem para onde ir.
        if item.id == ">goto" {
            ws.paletteQuery = ":"
            selection = 0
            return
        }
        if item.kind == .line, item.id == ":" {
            return
        }
        close()
        switch item.kind {
        case .file: ws.openFile(item.id)
        case .line:
            irParaLinha(item.id)
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
                ComandosDoHistorico.executar(item.id, ws: ws)
                if item.id.hasPrefix(">editor."),
                   let acao = AcaoDoEditor(rawValue: String(item.id.dropFirst(8)))
                {
                    // Depois de a paleta fechar: o campo dela ainda é o foco agora.
                    let documento = ws.documentoAtivo
                    Task { @MainActor in
                        ComandosDoEditor.executar(acao, documento: documento, mesmoComOutroFoco: true)
                    }
                }
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

    /// `:12:5` escolhido: leva o cursor até lá no editor que está na tela. Se o centro
    /// mostra Diff ou Preview, volta ao código antes; sem editor montado ainda, abre pela
    /// linha, que é o que `open(_:line:)` sabe fazer.
    func irParaLinha(_ id: String) {
        guard let path = ws.active, let alvo = AlvoDeLinha(id) else { return }
        if chrome.snapshot.center == .diff || chrome.snapshot.center == .preview {
            chrome.snapshot.center = .code
        }
        let documento = ws.documentoAtivo
        Task { @MainActor in
            if !ComandosDoEditor.irPara(alvo, documento: documento) {
                ws.open(path, line: alvo.linha)
            }
        }
    }
}
