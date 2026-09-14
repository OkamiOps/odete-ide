import Foundation
import Observation

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
        case .files: "Arquivos"
        case .search: "Busca"
        case .git: "Git"
        case .problems: "Problemas"
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
        case .code: "Código"
        case .diff: "Diff"
        case .dual: "Dois"
        case .split: "Split"
        case .preview: "Preview"
        }
    }
}

public enum PhoneTab: String, Codable, CaseIterable, Sendable {
    case files, edit, agent, term, preview, settings
    public var label: String {
        switch self {
        case .files: "Arquivos"
        case .edit: "Editar"
        case .agent: "Agente"
        case .term: "Terminal"
        case .preview: "Preview"
        case .settings: "Ajustes"
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
    public init() {}

    enum CodingKeys: String, CodingKey {
        case fontSize, autoSave, wrap, minimap, lineNumbers, indentGuides, tabWidth, lineHeight, showWhitespace,
             showLineBreaks, pageGuide, highlightLine, autoClosePairs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditorPrefs()
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        autoSave = try c.decodeIfPresent(Bool.self, forKey: .autoSave) ?? d.autoSave
        wrap = try c.decodeIfPresent(Bool.self, forKey: .wrap) ?? d.wrap
        minimap = try c.decodeIfPresent(MinimapSize.self, forKey: .minimap) ?? d.minimap
        lineNumbers = try c.decodeIfPresent(Bool.self, forKey: .lineNumbers) ?? d.lineNumbers
        indentGuides = try c.decodeIfPresent(Bool.self, forKey: .indentGuides) ?? d.indentGuides
        tabWidth = try c.decodeIfPresent(Int.self, forKey: .tabWidth) ?? d.tabWidth
        lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? d.lineHeight
        showWhitespace = try c.decodeIfPresent(Bool.self, forKey: .showWhitespace) ?? d.showWhitespace
        showLineBreaks = try c.decodeIfPresent(Bool.self, forKey: .showLineBreaks) ?? d.showLineBreaks
        pageGuide = try c.decodeIfPresent(Int.self, forKey: .pageGuide) ?? d.pageGuide
        highlightLine = try c.decodeIfPresent(Bool.self, forKey: .highlightLine) ?? d.highlightLine
        autoClosePairs = try c.decodeIfPresent(Bool.self, forKey: .autoClosePairs) ?? d.autoClosePairs
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
}

/// Estado persistido de layout e preferências, espelhando `useChrome` da web.
public struct ChromeSnapshot: Codable, Hashable, Sendable {
    public var welcomeDone = false
    /// Projetos guardados no iCloud Drive (container ubíquo) em vez de Documents.
    public var projectsInCloud = false
    public var theme: ThemeId = .odete
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
    public var lastProjectId: UUID?
    /// Abas abertas por projeto.
    public var tabsByProject: [UUID: [EditorTab]] = [:]
    public var activeTabByProject: [UUID: String] = [:]
    public var expandedByProject: [UUID: [String]] = [:]
    public var agentByProject: [UUID: AgentPrefs] = [:]
    /// Esforço escolhido por "provedor:modelo".
    public var agentEffortByModel: [String: String] = [:]
    public init() {}

    /// Campos novos podem faltar no state.json antigo: cada um cai no padrão.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChromeSnapshot()
        welcomeDone = try c.decodeIfPresent(Bool.self, forKey: .welcomeDone) ?? d.welcomeDone
        projectsInCloud = try c.decodeIfPresent(Bool.self, forKey: .projectsInCloud) ?? d.projectsInCloud
        theme = try c.decodeIfPresent(ThemeId.self, forKey: .theme) ?? d.theme
        side = try c.decodeIfPresent(SidePanel.self, forKey: .side) ?? d.side
        sideOpen = try c.decodeIfPresent(Bool.self, forKey: .sideOpen) ?? d.sideOpen
        center = try c.decodeIfPresent(CenterMode.self, forKey: .center) ?? d.center
        agentVisible = try c.decodeIfPresent(Bool.self, forKey: .agentVisible) ?? d.agentVisible
        termVisible = try c.decodeIfPresent(Bool.self, forKey: .termVisible) ?? d.termVisible
        sideWidth = try c.decodeIfPresent(Double.self, forKey: .sideWidth) ?? d.sideWidth
        agentWidth = try c.decodeIfPresent(Double.self, forKey: .agentWidth) ?? d.agentWidth
        termHeight = try c.decodeIfPresent(Double.self, forKey: .termHeight) ?? d.termHeight
        phoneTab = try c.decodeIfPresent(PhoneTab.self, forKey: .phoneTab) ?? d.phoneTab
        editor = try c.decodeIfPresent(EditorPrefs.self, forKey: .editor) ?? d.editor
        lastProjectId = try c.decodeIfPresent(UUID.self, forKey: .lastProjectId)
        tabsByProject = try c.decodeIfPresent([UUID: [EditorTab]].self, forKey: .tabsByProject) ?? [:]
        activeTabByProject = try c.decodeIfPresent([UUID: String].self, forKey: .activeTabByProject) ?? [:]
        expandedByProject = try c.decodeIfPresent([UUID: [String]].self, forKey: .expandedByProject) ?? [:]
        agentByProject = try c.decodeIfPresent([UUID: AgentPrefs].self, forKey: .agentByProject) ?? [:]
        agentEffortByModel = try c.decodeIfPresent([String: String].self, forKey: .agentEffortByModel) ?? [:]
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

    public var palette: ThemePalette {
        ThemePalette.by(snapshot.theme)
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
