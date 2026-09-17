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
    /// A janela tem controles do sistema por cima do canto? Vem da geometria, e é
    /// reavaliado a cada mudança de tamanho, que é quando pode mudar.
    @State private var emJanela = false
    private let store: StateStore

    public init() {
        // Todo campo de texto do app ganha a barra com o botão de recolher o teclado.
        // Uma vez, aqui, em vez de um botão por tela — ver `Teclado`.
        Teclado.instalaBarra()
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

    /// O claro/escuro do iPad, para quando o tema segue o sistema.
    @Environment(\.colorScheme) private var esquema

    public var body: some View {
        // `VStack` e não `safeAreaInset`: o `TabView` do layout estreito desenhava a
        // própria barra por baixo da faixa, e aqui a divisão é dura para qualquer layout.
        VStack(spacing: 0) {
            if emJanela {
                BarraDaJanela(titulo: app.workspace?.project.name ?? "Odete")
                    .odeteTheme(Theme(chrome.palette, seguirSistema: chrome.snapshot.themeAuto))
            }
            Group {
                if let ws = app.workspace {
                    WorkspaceView()
                        .environment(ws)
                        .id(ws.project.id)
                } else {
                    HubView()
                }
            }
        }
        .environment(\.emJanela, emJanela)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in emJanela = Janela.temControles }
        .task { emJanela = Janela.temControles }
        // Duas `.sheet` no mesmo nível competem; esta fica um degrau abaixo da de boas-vindas.
        .sheet(isPresented: Binding(get: { chrome.settingsOpen }, set: { chrome.settingsOpen = $0 })) {
            SettingsSheet()
                .environment(chrome).environment(app).environment(app.accounts).environment(app.aiAccounts)
                .odeteTheme(Theme(chrome.palette, seguirSistema: chrome.snapshot.themeAuto))
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
        // Quem manda no claro/escuro é o iPad, e quem lê é aqui: com `themeAuto` ligado
        // o app não força esquema nenhum, então este valor é mesmo o do sistema.
        .onChange(of: esquema, initial: true) { chrome.sistemaEscuro = esquema == .dark }
        .environment(chrome)
        .environment(app)
        .environment(app.accounts)
        .environment(app.aiAccounts)
        .odeteTheme(Theme(chrome.palette, seguirSistema: chrome.snapshot.themeAuto))
        .sheet(isPresented: Binding(
            get: { !chrome.snapshot.welcomeDone },
            set: {
                if !$0 {
                    chrome.snapshot.welcomeDone = true
                }
            }
        )) {
            OnboardingView().environment(chrome).odeteTheme(Theme(chrome.palette, seguirSistema: chrome.snapshot.themeAuto))
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
