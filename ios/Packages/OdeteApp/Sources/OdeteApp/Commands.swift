import OdeteCore
import SwiftUI

/// Ações do workspace expostas à barra de menus do iPadOS via `FocusedValue`.
@MainActor
struct WorkspaceActions {
    let ws: WorkspaceModel
    let chrome: ChromeState
    let app: AppModel
}

struct WorkspaceActionsKey: FocusedValueKey {
    typealias Value = WorkspaceActions
}

extension FocusedValues {
    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsKey.self] }
        set { self[WorkspaceActionsKey.self] = newValue }
    }
}

/// Menus Arquivo, Editar, Ver, Ir, Terminal. O app target instala com `.commands { OdeteCommands() }`.
public struct OdeteCommands: Commands {
    @FocusedValue(\.workspaceActions) private var a

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Novo arquivo") { a?.ws.createFile(near: a?.ws.selected) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(a == nil)
            Button("Salvar") { a?.ws.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(a == nil)
            Button("Salvar todos") { a?.ws.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(a == nil)
            Divider()
            Button("Fechar aba") {
                if let p = a?.ws.active {
                    a?.ws.closeTab(p)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(a?.ws.active == nil)
            Button("Voltar aos projetos") { a?.app.closeWorkspace() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(a == nil)
        }
        CommandMenu("Ver") {
            Button("Sidebar") { a?.chrome.toggleSide() }.keyboardShortcut("b", modifiers: .command)
            Button("Agente") { a?.chrome.toggleAgent() }.keyboardShortcut("i", modifiers: .command)
            Button("Terminal") { a?.chrome.toggleTerm() }.keyboardShortcut("j", modifiers: .command)
            Divider()
            ForEach(CenterMode.allCases, id: \.self) { m in
                Button("Modo: \(m.label)") { a?.chrome.snapshot.center = m }
            }
            Divider()
            Button("Restaurar layout") { a?.chrome.resetLayout() }
        }
        CommandMenu("Ir") {
            Button("Paleta de comandos") { a?.ws.paletteQuery = ">"; a?.ws.paletteOpen = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Ir para arquivo") { a?.ws.paletteQuery = ""; a?.ws.paletteOpen = true }
                .keyboardShortcut("p", modifiers: .command)
            Button("Buscar no projeto") { a?.chrome.snapshot.side = .search; a?.chrome.snapshot.sideOpen = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            ForEach(SidePanel.allCases, id: \.self) { p in
                Button(p.label) { a?.chrome.select(side: p) }
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Ajustes…") { a?.chrome.snapshot.side = .settings; a?.chrome.snapshot.sideOpen = true }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}
