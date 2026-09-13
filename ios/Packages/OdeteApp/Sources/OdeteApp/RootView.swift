import OdeteCore
import OdeteUI
import SwiftUI

/// Raiz do app: carrega o estado persistido, aplica o tema e decide entre hub e workspace.
public struct RootView: View {
    @State private var chrome: ChromeState
    @State private var app = AppModel()
    private let store: StateStore

    public init() {
        let store = StateStore()
        self.store = store
        _chrome = State(initialValue: ChromeState(snapshot: store.load()))
    }

    public var body: some View {
        Group {
            if let ws = app.workspace {
                WorkspaceView()
                    .environment(ws)
                    .id(ws.project.id)
            } else {
                HubView()
            }
        }
        .environment(chrome)
        .environment(app)
        .odeteTheme(Theme(chrome.palette))
        .onAppear {
            chrome.onChange = { [store] snap in store.scheduleSave(snap) }
        }
    }
}
