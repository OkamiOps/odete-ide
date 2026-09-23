import Foundation
import Observation
import OdeteI18n

public enum SidePanel: String, Codable, CaseIterable, Sendable {
    /// Sem "esboço": a lista de símbolos do arquivo já mora na paleta de comandos, em @,
    /// e como painel ela passava a maior parte do tempo vazia. Ajustes saiu daqui porque
    /// abre numa folha, nunca foi um painel de coluna.
    case files, search, git, problems

    /// Valor desconhecido vira arquivos, em vez de derrubar a decodificação: o estado
    /// salvo de quem já usou o app guarda painéis que não existem mais, e um erro aqui
    /// levava junto o tema, as abas e a lista de projetos.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SidePanel(rawValue: raw) ?? .files
    }

    public var label: String {
        switch self {
        case .files: tr("Arquivos")
        case .search: tr("Busca")
        case .git: tr("Git")
        case .problems: tr("Problemas")
        }
    }

    public var symbol: String {
        switch self {
        case .files: "doc.on.doc"
        case .search: "magnifyingglass"
        case .git: "arrow.triangle.branch"
        case .problems: "exclamationmark.circle"
        }
    }
}

public enum CenterMode: String, Codable, CaseIterable, Sendable {
    case code, diff, dual, split, preview
    public var label: String {
        switch self {
        case .code: tr("Código")
        case .diff: tr("Diff")
        case .dual: tr("Dois")
        case .split: tr("Split")
        case .preview: tr("Preview")
        }
    }
}

public enum PhoneTab: String, Codable, CaseIterable, Sendable {
    case files, edit, agent, term, preview, settings
    public var label: String {
        switch self {
        case .files: tr("Arquivos")
        case .edit: tr("Editar")
        case .agent: tr("Agente")
        case .term: tr("Terminal")
        case .preview: tr("Preview")
        case .settings: tr("Ajustes")
        }
    }

    public var symbol: String {
        switch self {
        case .files: "doc.on.doc"
        case .edit: "chevron.left.forwardslash.chevron.right"
        case .agent: "sparkles"
        case .term: "terminal"
        case .preview: "play.rectangle"
        case .settings: "gearshape"
        }
    }
}

public enum MinimapSize: String, Codable, CaseIterable, Sendable { case off, s, m, l }

/// De que lado da tela um painel mora.
public enum LadoDoPainel: String, Codable, CaseIterable, Sendable {
    case esquerda, direita
    public var label: String {
        switch self {
        case .esquerda: tr("À esquerda")
        case .direita: tr("À direita")
        }
    }
}

/// Onde o terminal abre.
public enum LugarDoTerminal: String, Codable, CaseIterable, Sendable {
    case editor, lateral
    public var label: String {
        switch self {
        case .editor: tr("Abaixo do editor")
        case .lateral: tr("Abaixo dos arquivos")
        }
    }
}

/// Fonte do editor. Todas existem no iPad sem baixar nada: a primeira vem no app, as
/// outras vêm do sistema.
public enum EditorFont: String, Codable, CaseIterable, Sendable {
    case plex, sistema, menlo, courier

    public var label: String {
        switch self {
        case .plex: "IBM Plex Mono"
        case .sistema: tr("Do sistema")
        case .menlo: "Menlo"
        case .courier: "Courier New"
        }
    }

    /// Nome para o `UIFont`. `nil` cai na monoespaçada do sistema.
    public var postScript: String? {
        switch self {
        case .plex: "IBMPlexMono"
        case .sistema: nil
        case .menlo: "Menlo-Regular"
        case .courier: "CourierNewPSMT"
        }
    }
}

/// Preferências do editor.
public struct EditorPrefs: Codable, Hashable, Sendable {
    public var fontSize: Double = 13
    public var autoSave = true
    public var wrap = false
    public var minimap: MinimapSize = .off
    public var lineNumbers = true
    public var indentGuides = true
    public var tabWidth = 2
    /// Altura de linha relativa (1.0 = compacta).
    public var lineHeight: Double = 1.25
    public var showWhitespace = false
    public var showLineBreaks = false
    /// Coluna da guia de página (0 = sem guia).
    public var pageGuide = 0
    public var highlightLine = true
    public var autoClosePairs = true
    /// Fonte do texto do código.
    public var fontFamily: EditorFont = .plex
    /// Espaço extra entre letras, em pontos. Negativo aperta.
    public var kern: Double = 0
    /// Deixa rolar depois da última linha. Sem isto, a linha em que se está trabalhando
    /// vive colada na borda de baixo quando o arquivo termina ali.
    public var scrollPastEnd = true
    /// Ao salvar: tira espaço no fim das linhas; garante uma quebra no fim do arquivo.
    public var trimOnSave = false
    public var finalNewline = false
    public init() {}

    enum CodingKeys: String, CodingKey {
        case fontSize, autoSave, wrap, minimap, lineNumbers, indentGuides, tabWidth, lineHeight, showWhitespace,
             showLineBreaks, pageGuide, highlightLine, autoClosePairs,
             fontFamily, kern, scrollPastEnd, trimOnSave, finalNewline
    }

    /// Campo a campo: um valor que esta versão não conhece (um tamanho de minimapa
    /// novo, uma fonte que saiu) vira o padrão daquele campo e não derruba os outros.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditorPrefs()
        fontSize = c.ler(.fontSize, d.fontSize)
        autoSave = c.ler(.autoSave, d.autoSave)
        wrap = c.ler(.wrap, d.wrap)
        minimap = c.ler(.minimap, d.minimap)
        lineNumbers = c.ler(.lineNumbers, d.lineNumbers)
        indentGuides = c.ler(.indentGuides, d.indentGuides)
        tabWidth = c.ler(.tabWidth, d.tabWidth)
        lineHeight = c.ler(.lineHeight, d.lineHeight)
        showWhitespace = c.ler(.showWhitespace, d.showWhitespace)
        showLineBreaks = c.ler(.showLineBreaks, d.showLineBreaks)
        pageGuide = c.ler(.pageGuide, d.pageGuide)
        highlightLine = c.ler(.highlightLine, d.highlightLine)
        autoClosePairs = c.ler(.autoClosePairs, d.autoClosePairs)
        fontFamily = c.ler(.fontFamily, d.fontFamily)
        kern = c.ler(.kern, d.kern)
        scrollPastEnd = c.ler(.scrollPastEnd, d.scrollPastEnd)
        trimOnSave = c.ler(.trimOnSave, d.trimOnSave)
        finalNewline = c.ler(.finalNewline, d.finalNewline)
    }
}

/// Escolhas do agente por projeto.
public struct AgentPrefs: Codable, Hashable, Sendable {
    public var accountId: UUID?
    public var model = ""
    public var effort = ""
    public var mode = "build"
    public var permit = "auto"
    public var threadId: String?
    public init() {}

    enum CodingKeys: String, CodingKey { case accountId, model, effort, mode, permit, threadId }

    /// Tolerante como o resto do estado: preferência gravada antes de um campo existir
    /// continua valendo, com o padrão no campo que falta.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AgentPrefs()
        accountId = c.ler(.accountId, d.accountId)
        model = c.ler(.model, d.model)
        effort = c.ler(.effort, d.effort)
        mode = c.ler(.mode, d.mode)
        permit = c.ler(.permit, d.permit)
        threadId = c.ler(.threadId, d.threadId)
    }
}

/// Estado persistido de layout e preferências, espelhando `useChrome` da web.
public struct ChromeSnapshot: Codable, Hashable, Sendable {
    public var welcomeDone = false
    /// Projetos guardados no iCloud Drive (container ubíquo) em vez de Documents.
    public var projectsInCloud = false
    public var theme: ThemeId = .odete
    /// Segue o claro/escuro do iPad, trocando entre os dois temas abaixo.
    public var themeAuto = false
    public var themeLight: ThemeId = .latte
    public var themeDark: ThemeId = .odete
    /// Barras que podem sumir para sobrar tela.
    public var showTabBar = true
    public var showStatusBar = true
    /// Multiplicador do texto da interface. O do código é separado, em `editor.fontSize`.
    public var uiScale: Double = 1
    /// Cores do código por cima do tema, por nome de token: keyword, string, comment,
    /// number, function, type. Vazio é o tema como ele veio.
    public var syntaxOverrides: [String: String] = [:]
    /// Onde cada painel mora. Trocar de lado é preferência de mão, não de gosto: quem
    /// segura o iPad de um jeito quer a árvore do outro.
    public var sideSide: LadoDoPainel = .esquerda
    public var agentSide: LadoDoPainel = .direita
    public var termPlace: LugarDoTerminal = .editor
    /// Terminal: tamanho e fonte próprios, porque ninguém lê log no mesmo corpo em que
    /// escreve código.
    public var termFontSize: Double = 12
    public var termFont: EditorFont = .plex
    public var side: SidePanel = .files
    public var sideOpen = true
    public var center: CenterMode = .code
    public var agentVisible = true
    public var termVisible = false
    public var sideWidth: Double = 330
    public var agentWidth: Double = 360
    public var termHeight: Double = 220
    public var phoneTab: PhoneTab = .files
    public var editor = EditorPrefs()
    /// Mostrar node_modules, .git, dist e companhia na árvore.
    public var mostrarOcultos = false
    /// Já explicamos uma vez que o Safari em tela cheia suspende o servidor.
    public var avisoSafariVisto = false
    public var lastProjectId: UUID?
    /// Abas abertas por projeto.
    public var tabsByProject: [UUID: [EditorTab]] = [:]
    public var activeTabByProject: [UUID: String] = [:]
    public var expandedByProject: [UUID: [String]] = [:]
    public var agentByProject: [UUID: AgentPrefs] = [:]
    /// Esforço escolhido por "provedor:modelo".
    public var agentEffortByModel: [String: String] = [:]
    public init() {}

    /// Campo a campo, sem deixar um derrubar os outros.
    ///
    /// Campos novos podem faltar no state.json antigo, e campos velhos podem trazer um
    /// valor que esta versão não conhece — um tema que saiu, um modo que mudou de nome.
    /// Antes, um enum estrito aqui fazia a decodificação inteira falhar, e o app voltava
    /// com tudo zerado: abas, ajustes, o fim do onboarding — e, sem saber que já tinha
    /// passado por ele, ligava o iCloud como numa instalação nova. Agora cada campo que
    /// não dá para ler vale o seu padrão, e só ele; nos dicionários por projeto, cada
    /// entrada vale por si.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChromeSnapshot()
        welcomeDone = c.ler(.welcomeDone, d.welcomeDone)
        projectsInCloud = c.ler(.projectsInCloud, d.projectsInCloud)
        theme = c.ler(.theme, d.theme)
        themeAuto = c.ler(.themeAuto, d.themeAuto)
        themeLight = c.ler(.themeLight, d.themeLight)
        themeDark = c.ler(.themeDark, d.themeDark)
        showTabBar = c.ler(.showTabBar, d.showTabBar)
        showStatusBar = c.ler(.showStatusBar, d.showStatusBar)
        uiScale = c.ler(.uiScale, d.uiScale)
        syntaxOverrides = c.ler(.syntaxOverrides, d.syntaxOverrides)
        sideSide = c.ler(.sideSide, d.sideSide)
        agentSide = c.ler(.agentSide, d.agentSide)
        termPlace = c.ler(.termPlace, d.termPlace)
        termFontSize = c.ler(.termFontSize, d.termFontSize)
        termFont = c.ler(.termFont, d.termFont)
        side = c.ler(.side, d.side)
        sideOpen = c.ler(.sideOpen, d.sideOpen)
        center = c.ler(.center, d.center)
        agentVisible = c.ler(.agentVisible, d.agentVisible)
        termVisible = c.ler(.termVisible, d.termVisible)
        sideWidth = c.ler(.sideWidth, d.sideWidth)
        agentWidth = c.ler(.agentWidth, d.agentWidth)
        termHeight = c.ler(.termHeight, d.termHeight)
        phoneTab = c.ler(.phoneTab, d.phoneTab)
        editor = c.ler(.editor, d.editor)
        mostrarOcultos = c.ler(.mostrarOcultos, d.mostrarOcultos)
        avisoSafariVisto = c.ler(.avisoSafariVisto, d.avisoSafariVisto)
        lastProjectId = c.ler(.lastProjectId, d.lastProjectId)
        tabsByProject = c.lerPorProjeto(.tabsByProject, ListaTolerante<EditorTab>.self).mapValues(\.itens)
        activeTabByProject = c.lerPorProjeto(.activeTabByProject, String.self)
        expandedByProject = c.lerPorProjeto(.expandedByProject, ListaTolerante<String>.self).mapValues(\.itens)
        agentByProject = c.lerPorProjeto(.agentByProject, AgentPrefs.self)
        agentEffortByModel = c.ler(.agentEffortByModel, d.agentEffortByModel)
    }
}

// MARK: - leitura tolerante

extension KeyedDecodingContainer {
    /// Lê um campo do estado salvo. Ausente, de outro tipo ou com um valor que esta
    /// versão não conhece: vale `padrao` — para este campo, e só para ele.
    func ler<T: Decodable>(_ chave: Key, _ padrao: T) -> T {
        (try? decodeIfPresent(T.self, forKey: chave)) ?? padrao
    }

    /// Dicionário por projeto, entrada a entrada.
    ///
    /// Com chave `UUID` o JSON guarda o dicionário como lista `[id, valor, id, valor…]`.
    /// Lido de uma vez, uma entrada estragada levava as de todos os projetos; aqui cada
    /// par que não dá para ler fica de fora sozinho.
    func lerPorProjeto<V: Decodable>(_ chave: Key, _: V.Type) -> [UUID: V] {
        guard var lista = try? nestedUnkeyedContainer(forKey: chave) else { return [:] }
        var out: [UUID: V] = [:]
        while !lista.isAtEnd {
            guard let k = try? lista.decode(Talvez<UUID>.self), !lista.isAtEnd,
                  let v = try? lista.decode(Talvez<V>.self) else { break }
            if let id = k.valor, let valor = v.valor {
                out[id] = valor
            }
        }
        return out
    }
}

/// Decodifica sem lançar: o valor, ou nada. Numa lista, um item que falha ao decodificar
/// deixa o cursor parado nele; embrulhado aqui, ele sempre anda.
struct Talvez<T: Decodable>: Decodable {
    let valor: T?

    init(from decoder: Decoder) throws {
        valor = try? T(from: decoder)
    }
}

/// Uma lista em que o item estragado sai sozinho, sem levar os outros.
struct ListaTolerante<T: Decodable>: Decodable {
    let itens: [T]

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            guard let t = try? c.decode(Talvez<T>.self) else { break }
            if let v = t.valor {
                out.append(v)
            }
        }
        itens = out
    }
}

@MainActor
@Observable
public final class ChromeState {
    public var snapshot: ChromeSnapshot {
        didSet { onChange?(snapshot) }
    }

    /// Chamado a cada mudança; `StateStore` liga aqui o salvamento debounced.
    public var onChange: (@MainActor (ChromeSnapshot) -> Void)?
    /// Folha de Ajustes aberta (não persiste).
    public var settingsOpen = false

    public init(snapshot: ChromeSnapshot = ChromeSnapshot()) {
        self.snapshot = snapshot
    }

    /// O iPad está no escuro? Alimentado pela view raiz; só vale quando `themeAuto`.
    public var sistemaEscuro = true

    // MARK: arrasto dos divisores

    /// Um divisor sendo arrastado agora, e onde ele está.
    ///
    /// Todas as preferências moram num `snapshot` só, e toda view que lê qualquer uma
    /// delas lê o `snapshot` inteiro — a raiz, o workspace, o editor (que reaplica os
    /// ajustes), a barra de status, cada linha do terminal. Escrever a largura no
    /// `snapshot` a cada quadro do arrasto redesenhava tudo isso sessenta vezes por
    /// segundo, e ainda agendava um salvamento do estado a cada quadro. Durante o arrasto
    /// a medida mora aqui, que só o layout lê; ao soltar, vai para o `snapshot` uma vez.
    public private(set) var arrasto: Arrasto?

    public enum Divisor: Sendable, Hashable {
        case lado, agente, terminal
    }

    public struct Arrasto: Sendable, Hashable {
        public var divisor: Divisor
        public var valor: Double
    }

    /// A medida do divisor: a do arrasto em curso, ou a guardada.
    public func medida(_ d: Divisor) -> Double {
        if let a = arrasto, a.divisor == d {
            return a.valor
        }
        return switch d {
        case .lado: snapshot.sideWidth
        case .agente: snapshot.agentWidth
        case .terminal: snapshot.termHeight
        }
    }

    /// Um quadro do arrasto: muda só a medida ao vivo.
    public func arrastar(_ d: Divisor, para valor: Double) {
        arrasto = Arrasto(divisor: d, valor: valor)
    }

    /// Soltou: a medida vai para as preferências (e para o disco) uma vez só.
    public func soltarArrasto() {
        guard let a = arrasto else { return }
        arrasto = nil
        switch a.divisor {
        case .lado: snapshot.sideWidth = a.valor
        case .agente: snapshot.agentWidth = a.valor
        case .terminal: snapshot.termHeight = a.valor
        }
    }

    public var palette: ThemePalette {
        var p = snapshot.themeAuto
            ? ThemePalette.by(sistemaEscuro ? snapshot.themeDark : snapshot.themeLight)
            : ThemePalette.by(snapshot.theme)
        p.syntax = p.syntax.com(snapshot.syntaxOverrides)
        return p
    }

    public func toggleSide() {
        snapshot.sideOpen.toggle()
    }

    public func toggleAgent() {
        snapshot.agentVisible.toggle()
    }

    public func toggleTerm() {
        snapshot.termVisible.toggle()
    }

    public func select(side: SidePanel) {
        if snapshot.side == side, snapshot.sideOpen {
            snapshot.sideOpen = false
        } else {
            snapshot.side = side
            snapshot.sideOpen = true
        }
    }

    public func resetLayout() {
        snapshot.sideWidth = 260
        snapshot.agentWidth = 360
        snapshot.termHeight = 220
        snapshot.sideOpen = true
        snapshot.agentVisible = true
    }

    public func tabs(for project: UUID) -> [EditorTab] {
        snapshot.tabsByProject[project] ?? []
    }

    public func setTabs(_ tabs: [EditorTab], for project: UUID) {
        snapshot.tabsByProject[project] = tabs
    }

    public func activeTab(for project: UUID) -> String? {
        snapshot.activeTabByProject[project]
    }

    public func setActiveTab(_ path: String?, for project: UUID) {
        snapshot.activeTabByProject[project] = path
    }
}
