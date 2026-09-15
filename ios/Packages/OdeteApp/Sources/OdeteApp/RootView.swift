import OdeteCore
import OdeteFiles
import OdeteUI
import SwiftUI

/// Raiz do app: carrega o estado persistido, aplica o tema e decide entre hub e workspace.
public struct RootView: View {
    @State private var chrome: ChromeState
    @State private var app = AppModel()
    /// Só para reagir: `OdeteFont` calcula o tamanho na hora, e sem alguém observando
    /// isto a tela não se refaz quando a pessoa muda o tamanho de texto do iPad.
    @Environment(\.dynamicTypeSize) private var tamanhoDoSistema
    /// O servidor de dev não sobrevive ao app sair de cena; ver `BackgroundServers`.
    @Environment(\.scenePhase) private var fase
    private let store: StateStore

    public init() {
        let store = StateStore()
        self.store = store
        var snap = store.load()
        // Instalação nova com iCloud à mão: os projetos nascem no iCloud Drive. Dentro do
        // container do app eles não sobrevivem a uma desinstalação — some tudo, incluindo
        // o histórico git e as conversas do agente. Só vale para instalação nova: mudar o
        // lugar de quem já tem projeto é decisão da pessoa, nos Ajustes.
        if !snap.welcomeDone, !snap.projectsInCloud, AppModel.cloudRoot() != nil {
            snap.projectsInCloud = true
            try? store.saveNow(snap)
        }
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
        // Duas `.sheet` no mesmo nível competem; esta fica um degrau abaixo da de boas-vindas.
        .sheet(isPresented: Binding(get: { chrome.settingsOpen }, set: { chrome.settingsOpen = $0 })) {
            SettingsSheet()
                .environment(chrome).environment(app).environment(app.accounts).environment(app.aiAccounts)
                .odeteTheme(Theme(chrome.palette))
        }
        .onChange(of: fase) { _, nova in
            guard let ws = app.workspace else { return }
            switch nova {
            case .background:
                ws.run.aoSairDeCena()
                ws.aoSairDeCena()
            case .active: ws.run.aoVoltarParaCena()
            default: break
            }
        }
        .id(tamanhoDoSistema)
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
