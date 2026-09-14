import OdeteCore
import OdeteFiles
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
        let snap = store.load()
        _chrome = State(initialValue: ChromeState(snapshot: snap))
        _app =
            State(initialValue: AppModel(store: ProjectStore(root: AppModel.projectsRoot(cloud: snap.projectsInCloud))))
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
        .environment(app.accounts)
        .environment(app.aiAccounts)
        .odeteTheme(Theme(chrome.palette))
        .sheet(isPresented: Binding(
            get: { !chrome.snapshot.welcomeDone },
            set: {
                if !$0 {
                    chrome.snapshot.welcomeDone = true
                }
            }
        )) {
            OnboardingView().environment(chrome).odeteTheme(Theme(chrome.palette))
                .presentationSizing(.page)
        }
        .onOpenURL { url in app.importURL(url, chrome: chrome) }
        .onAppear {
            chrome.onChange = { [store] snap in store.scheduleSave(snap) }
            IntentBridge.shared.bind(app: app, chrome: chrome)
            if app.workspace == nil, let id = chrome.snapshot.lastProjectId,
               let p = app.projects.first(where: { $0.id == id })
            {
                app.open(p, chrome: chrome)
            }
        }
    }
}
