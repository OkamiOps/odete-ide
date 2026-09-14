import Foundation
import Observation

public enum SidePanel: String, Codable, CaseIterable, Sendable {
    case files, outline, search, git, problems, settings
    public var label: String {
        switch self {
        case .files: "Arquivos"
        case .outline: "Esboço"
        case .search: "Busca"
        case .git: "Git"
        case .problems: "Problemas"
        case .settings: "Ajustes"
        }
    }

    public var symbol: String {
        switch self {
        case .files: "doc.on.doc"
        case .outline: "list.bullet.indent"
        case .search: "magnifyingglass"
        case .git: "arrow.triangle.branch"
        case .problems: "exclamationmark.circle"
        case .settings: "gearshape"
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
    public init() {}
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
    public var theme: ThemeId = .odete
    public var side: SidePanel = .files
    public var sideOpen = true
    public var center: CenterMode = .code
    public var agentVisible = true
    public var termVisible = false
    public var sideWidth: Double = 260
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
