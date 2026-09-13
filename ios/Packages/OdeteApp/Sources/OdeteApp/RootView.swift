import OdeteCore
import OdeteUI
import SwiftUI

/// Raiz do app: carrega o estado persistido, aplica o tema e mostra o workspace.
public struct RootView: View {
    @State private var chrome: ChromeState
    private let store: StateStore

    public init() {
        let store = StateStore()
        self.store = store
        let state = ChromeState(snapshot: store.load())
        _chrome = State(initialValue: state)
    }

    public var body: some View {
        WorkspaceView()
            .environment(chrome)
            .odeteTheme(Theme(chrome.palette))
            .onAppear {
                chrome.onChange = { [store] snap in store.scheduleSave(snap) }
            }
    }
}
